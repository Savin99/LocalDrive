import SwiftUI
import XCTest
@testable import LocalDrive

// Снимки страницы «Карточки» до того, как она встанет в переключатель
// страниц: светлая и тёмная тема, редактор, экран карточки, пустое состояние.
// ImageRenderer не рисует NavigationStack и ScrollView, поэтому экраны
// снимаются из настоящего окна (drawHierarchy), а сама карточка — ImageRenderer.
// PNG складываются в build/shots рядом с проектом. Тест ничего не сравнивает:
// он падает, только если снимок не получился
@MainActor
final class FactsScreenshotTests: XCTestCase {
    private var root: URL!
    private var windows: [UIWindow] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FactsShots-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        for window in windows { window.isHidden = true }
        windows = []
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private var shotsURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("build/shots", isDirectory: true)
    }

    static let kamila = FactCard(
        title: "Дом Камилы",
        symbol: "house.fill",
        color: "teal",
        items: [
            FactItem(kind: .code, label: "Домофон", value: "45К1234"),
            FactItem(kind: .number, label: "Подъезд", value: "2"),
            FactItem(kind: .number, label: "Этаж", value: "3"),
            FactItem(kind: .number, label: "Квартира", value: "47"),
            FactItem(kind: .address, label: "Адрес", value: "Москва, Тверская 5"),
        ],
        createdAt: Date(timeIntervalSince1970: 1_790_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_790_000_000)
    )

    static let dacha = FactCard(
        title: "Дача",
        symbol: "leaf.fill",
        color: "green",
        items: [
            FactItem(kind: .wifi, label: "Wi-Fi", value: "dacha-2024"),
            FactItem(kind: .text, label: "Ключи", value: "под крыльцом, слева"),
            FactItem(kind: .link, label: "Как доехать", value: "https://yandex.ru/maps/-/CHuR4Ky"),
            FactItem(kind: .phone, label: "Сторож", value: "+7 916 123-45-67"),
        ],
        createdAt: Date(timeIntervalSince1970: 1_780_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_780_000_000)
    )

    static let car = FactCard(
        title: "Машина",
        symbol: "car.fill",
        color: "orange",
        items: [
            FactItem(kind: .text, label: "Госномер", value: "А123ВС 777"),
            FactItem(kind: .text, label: "Парковка", value: "−2 этаж, место 114"),
            FactItem(kind: .date, label: "ОСАГО до", value: "14 марта 2027"),
        ],
        createdAt: Date(timeIntervalSince1970: 1_770_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_770_000_000)
    )

    private func makeStore(cards: [FactCard]) -> FactStore {
        let store = FactStore(rootURL: root.appendingPathComponent(UUID().uuidString))
        cards.forEach(store.add)
        return store
    }

    private var store: FactStore { makeStore(cards: [Self.kamila, Self.dacha, Self.car]) }

    func testPageLight() throws {
        try shoot(FactsView().environment(store), style: .light, name: "facts-page-light")
    }

    func testPageDark() throws {
        try shoot(FactsView().environment(store), style: .dark, name: "facts-page-dark")
    }

    func testEmptyPage() throws {
        try shoot(FactsView().environment(makeStore(cards: [])), style: .light, name: "facts-empty-light")
    }

    func testDetailLight() throws {
        let view = NavigationStack { FactDetailView(cardID: Self.kamila.id) }.environment(store)
        try shoot(view, style: .light, name: "facts-detail-light")
    }

    func testDetailDark() throws {
        let view = NavigationStack { FactDetailView(cardID: Self.kamila.id) }.environment(store)
        try shoot(view, style: .dark, name: "facts-detail-dark")
    }

    func testEditorLight() throws {
        try shoot(FactEditorView(card: Self.kamila) { _ in }.environment(store), style: .light, name: "facts-editor-light")
    }

    func testEditorDark() throws {
        try shoot(FactEditorView(card: Self.kamila) { _ in }.environment(store), style: .dark, name: "facts-editor-dark")
    }

    func testNewCardEditor() throws {
        try shoot(FactEditorView(card: nil) { _ in }.environment(makeStore(cards: [])), style: .light, name: "facts-editor-new-light")
    }

    /// Ответ чата «домофон Камилы»: подсвечено одно поле. Карточка без
    /// навигации, поэтому её рисует ImageRenderer
    func testHighlightedCard() throws {
        try FileManager.default.createDirectory(at: shotsURL, withIntermediateDirectories: true)
        let intercom = Self.kamila.items[0].id
        for scheme in [ColorScheme.light, .dark] {
            let card = FactCardView(card: Self.kamila, highlighted: [intercom])
                .padding(16)
                .frame(width: 402)
                .background(Theme.background)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: card)
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage, "ImageRenderer не нарисовал карточку")
            let name = "fact-card-highlight-\(scheme == .dark ? "dark" : "light").png"
            try XCTUnwrap(image.pngData()).write(to: shotsURL.appendingPathComponent(name))
        }
    }

    /// Окно поверх приложения-хозяина в размер экрана: так видны шапка,
    /// поиск и безопасные области, как на iPhone
    private func shoot<V: View>(_ view: V, style: UIUserInterfaceStyle, name: String) throws {
        try FileManager.default.createDirectory(at: shotsURL, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "Нет сцены приложения-хозяина"
        )
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = style
        window.rootViewController = UIHostingController(rootView: view.tint(Theme.ink))
        window.makeKeyAndVisible()
        // Окно живёт до конца теста: снятое с экрана посреди ожидания роняло
        // асинхронный тест ошибкой SwiftUI «InvalidTransition»
        windows.append(window)

        // Дать SwiftUI разложить экран и доиграть появление
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(data.count, 10_000, "Снимок \(name) пустой")
        try data.write(to: shotsURL.appendingPathComponent("\(name).png"))
    }
}
