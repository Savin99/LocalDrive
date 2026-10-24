import SwiftUI
import Observation

/// Ответ модели с интерфейсом в одном сообщении чата. Поток наполняет его по
/// частям: текст растёт, состояние приходит целиком, блоки — по одному, и
/// каждый показывается, только когда его JSON закрыт и проверен
@MainActor
@Observable
final class GenUIMessageModel: Identifiable {
    enum Phase: Equatable {
        case streaming
        case finished
        case failed(String)
    }

    let id = UUID()
    private(set) var mode: GenUIDocument.Mode = .text
    private(set) var text = ""
    private(set) var blocks: [GenUIBlock] = []
    private(set) var issues: [GenUIIssue] = []
    private(set) var phase: Phase = .streaming
    let state = GenUIState()
    let runner = GenUIActionRunner()

    @ObservationIgnored let registry: GenUIComponentRegistry
    @ObservationIgnored private var declared: [(name: String, value: GenUIScalar)] = []
    @ObservationIgnored private var computed: [(name: String, expression: GenUIExpression)] = []

    init(registry: GenUIComponentRegistry = .standard) {
        self.registry = registry
    }

    /// Готовый ответ — из истории или без потока
    convenience init(document: GenUIDocument, issues: [GenUIIssue] = [], registry: GenUIComponentRegistry = .standard) {
        self.init(registry: registry)
        finish(document, issues: issues)
    }

    /// Ответ строкой JSON: разбор и проверка
    convenience init(json data: Data, registry: GenUIComponentRegistry = .standard) {
        let validation = GenUIValidator.document(from: data, registry: registry)
        self.init(document: validation.document, issues: validation.issues, registry: registry)
    }

    // MARK: - Поток

    /// Текст, пока он приходит. Длиннее лимита не показывается
    func setPartialText(_ partial: String) {
        guard phase == .streaming else { return }
        text = String(partial.prefix(GenUILimits.maxTextLength))
    }

    /// Закрытый массив `state` из потока
    func setState(_ json: JSONValue) {
        let (state, found) = GenUIValidator.state(from: json)
        issues += found
        declared = state
        self.state.declare(state)
    }

    /// Закрытый массив `computed` из потока
    func setComputed(_ json: JSONValue) {
        let (list, found) = GenUIValidator.computed(from: json)
        issues += found
        computed = list
        state.setComputed(list)
    }

    /// Закрытый элемент `blocks`. false — блок не прошёл проверку
    @discardableResult
    func append(_ json: JSONValue) -> Bool {
        let used = Set(blocks.flatMap(\.flattened).map(\.id))
        let remaining = GenUILimits.maxBlocks - used.count
        let (block, found) = GenUIValidator.block(from: json, registry: registry, usedIDs: used, blockLimit: max(0, remaining))
        issues += found
        guard let block else { return false }
        return append(block)
    }

    @discardableResult
    func append(_ block: GenUIBlock) -> Bool {
        let used = Set(blocks.flatMap(\.flattened).map(\.id))
        guard block.flattened.allSatisfy({ !used.contains($0.id) }),
              used.count + block.flattened.count <= GenUILimits.maxBlocks else {
            issues.append(GenUIIssue(path: block.id, message: "повтор id или превышен лимит блоков"))
            return false
        }
        state.merge(binds: block.binds)
        withAnimation(Self.appearAnimation) {
            blocks.append(block)
            if mode == .text { mode = text.isEmpty ? .ui : .mixed }
        }
        return true
    }

    /// Поток закончился: окончательный проверенный ответ. Блоки берутся из
    /// него, а то, что человек уже успел подвигать, остаётся
    func finish(_ document: GenUIDocument, issues found: [GenUIIssue] = []) {
        issues += found
        mode = document.mode
        text = document.text
        declared = document.state
        computed = document.computed
        state.apply(document, keepingChanges: true)
        withAnimation(Self.appearAnimation) {
            blocks = document.blocks
        }
        phase = .finished
    }

    /// Ответ строкой JSON целиком — в конце потока
    func finish(json data: Data) {
        let validation = GenUIValidator.document(from: data, registry: registry)
        finish(validation.document, issues: validation.issues)
    }

    /// Поток оборвался: остаётся то, что успело прийти
    func fail(_ reason: String) {
        issues.append(GenUIIssue(path: "", message: reason))
        phase = .failed(reason)
    }

    // MARK: - После ответа

    /// Блок, перестроенный моделью по `regenerate`. Ищется на любой глубине;
    /// документ проверяется заново целиком, состояние сохраняется
    @discardableResult
    func replace(blockID: String, with json: JSONValue) -> Bool {
        var replaced = false
        func swap(_ raw: JSONValue) -> JSONValue {
            guard case .object(var object) = raw else { return raw }
            if object["id"]?.string == blockID {
                replaced = true
                var new = json.object ?? [:]
                new["id"] = .string(blockID)
                return .object(new)
            }
            for key in ["blocks"] {
                if let items = object[key]?.array { object[key] = .array(items.map(swap)) }
            }
            if let tabs = object["tabs"]?.array {
                object["tabs"] = .array(tabs.map { tab in
                    guard case .object(var tabObject) = tab, let items = tabObject["blocks"]?.array else { return tab }
                    tabObject["blocks"] = .array(items.map(swap))
                    return .object(tabObject)
                })
            }
            return .object(object)
        }
        var current = document.json
        if case .object(var object) = current, let items = object["blocks"]?.array {
            object["blocks"] = .array(items.map(swap))
            current = .object(object)
        }
        guard replaced else { return false }
        let validation = GenUIValidator.document(from: current, registry: registry)
        issues += validation.issues
        state.apply(validation.document, keepingChanges: true)
        withAnimation(Self.appearAnimation) {
            blocks = validation.document.blocks
            mode = validation.document.mode
        }
        return true
    }

    /// Повторная проверка сохранённого ответа: реестр мог измениться
    func revalidate() {
        let validation = GenUIValidator.document(from: document.json, registry: registry)
        issues = validation.issues
        blocks = validation.document.blocks
        mode = validation.document.mode
        state.apply(validation.document, keepingChanges: true)
    }

    /// Ответ как документ: для истории и для модели при перестройке блока
    var document: GenUIDocument {
        GenUIDocument(mode: mode, text: text, state: declared, computed: computed, blocks: blocks)
    }

    /// Показывать нечего: пусто и поток закончен
    var isEmpty: Bool {
        phase != .streaming && blocks.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static var appearAnimation: Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : .easeOut(duration: 0.22)
    }
}
