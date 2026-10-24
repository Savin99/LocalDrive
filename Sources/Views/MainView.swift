import SwiftUI
import UIKit

// Главный экран: три страницы — чат по документам, библиотека папок и
// «Карточки» с фактами, которых нет в документах (владелец 24.10.2026:
// «третий свайп, где карточками всё сохраняется»). Переключатель вверху,
// между страницами можно листать свайпом (решение владельца от 12.10.2026:
// нижние вкладки занимали много места). Сессия чата живёт в LocalDriveApp:
// переписка остаётся в памяти до перезапуска приложения. На диск она не пишется
struct MainView: View {
    @Environment(VaultStore.self) private var store
    @Environment(BackupManager.self) private var backup
    @Environment(SearchService.self) private var search
    @Environment(ChatModelStore.self) private var models
    @Environment(ChatSession.self) private var chat
    @Environment(HiddenFolders.self) private var hiddenFolders
    @Environment(FactStore.self) private var facts

    @State private var page = MainPage.chat
    /// Сдвиг страниц за пальцем во время свайпа
    @State private var dragOffset: CGFloat = 0
    /// Палец ведёт страницы: видны обе
    @State private var isDragging = false
    /// Страницы доезжают на место после свайпа или нажатия на переключатель
    @State private var isSettling = false
    /// Сколько экранов открыто поверх «Файлов». Внутри папки листание и
    /// переключатель выключены: там работает системный свайп «назад»
    @State private var filesDepth = 0
    /// Открыта карточка поверх «Карточек» — там свой свайп «назад»
    @State private var factsDepth = 0
    /// Высота нижней полосы чата — поля ввода с подсказками. Там
    /// горизонтальный свайп листает подсказки, а не страницы
    @State private var composerHeight: CGFloat = 0

    /// С «Файлов» к чату за пальцем — от левого края. Из любого другого места
    /// свайп листает по отпусканию (FilesStrokeGesture): штрих там может
    /// оказаться секретным знаком
    private static let edgeWidth: CGFloat = 24
    private static let space = "pager"
    private static let settle = Animation.spring(response: 0.35, dampingFraction: 0.86)
    /// Быстрый взмах листает, даже если палец прошёл меньше трети экрана
    private static let flingVelocity: CGFloat = 600

    private var showsSwitcher: Bool {
        !(page == .files && filesDepth > 0) && !(page == .cards && factsDepth > 0)
    }

    /// Страница за краем экрана, пока ничего не едет
    private func isOffscreen(_ target: MainPage) -> Bool {
        page != target && !isDragging && !isSettling
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            // Обе страницы живут всё время: переписка, поиск и прокрутка папок
            // переживают переключение
            HStack(spacing: 0) {
                ChatView(session: chat)
                    .frame(width: width)
                    .onPreferenceChange(ChatComposerHeightKey.self) { composerHeight = $0 }
                    .environment(\.isOffscreenPage, isOffscreen(.chat))
                HomeView()
                    .frame(width: width)
                    .onPreferenceChange(FilesNavigationDepthKey.self) { filesDepth = $0 }
                    .environment(\.isOffscreenPage, isOffscreen(.files))
                FactsView()
                    .frame(width: width)
                    .onPreferenceChange(FactsNavigationDepthKey.self) { factsDepth = $0 }
                    .environment(\.isOffscreenPage, isOffscreen(.cards))
            }
            .frame(width: width, alignment: .leading)
            .offset(x: -CGFloat(page.index) * width + dragOffset)
            .gesture(pagingGesture(width: width, height: proxy.size.height))
            .gesture(filesStroke)
            .overlay(alignment: .top) {
                ZStack {
                    // Внутри папки переключателя нет совсем: прозрачный
                    // оставался в дереве доступности (проверено UI-тестом)
                    if showsSwitcher {
                        PageSwitcher(progress: progress(width: width)) { select($0) }
                            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.18), value: showsSwitcher)
            }
            .coordinateSpace(.named(Self.space))
        }
        // Значки в шапках — цветом текста, как в ChatGPT. Зелёный остаётся
        // за переключателями: им цвет задан явно
        .tint(Theme.ink)
        // Поле ввода осталось бы в фокусе за краем экрана вместе с клавиатурой
        .onChange(of: page) { _, _ in
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        // Задачи на всё приложение живут здесь: копия и индекс не должны ждать,
        // пока откроют «Файлы»
        .task { await backup.refresh() }
        // Экран появляется после входа: тогда же индекс сверяется с файлами
        // и в фоне распознаёт новое
        .task { search.reconcile() }
        // Свободные вопросы понимает скачанная модель; без неё чат отвечает правилами
        .onAppear { chat.usePlanner { [models] in models.currentPlanner } }
        .onChange(of: store.revision) { _, _ in
            backup.scheduleAutomaticBackup()
            search.scheduleReconcile()
        }
        // «Карточки» лежат в Vault — их правка тоже повод обновить копию
        .onChange(of: facts.revision) { _, _ in backup.scheduleAutomaticBackup() }
        // Скрытые папки открыли паролем в настройках — показываем их
        .onChange(of: hiddenFolders.revealCount) { _, _ in select(.files) }
    }

    /// 0 — чат, 1 — «Файлы», 2 — «Карточки»; во время свайпа дробное:
    /// капсула идёт за пальцем
    private func progress(width: CGFloat) -> CGFloat {
        guard width > 0 else { return CGFloat(page.index) }
        return min(max(CGFloat(page.index) - dragOffset / width, 0), CGFloat(MainPage.allCases.count - 1))
    }

    private func select(_ target: MainPage) {
        guard target != page else { return }
        settle(on: target)
    }

    private func settle(on target: MainPage) {
        isDragging = false
        isSettling = true
        withAnimation(Self.settle, completionCriteria: .removed) {
            page = target
            dragOffset = 0
        } completion: {
            isSettling = false
        }
    }

    // MARK: - Свайп

    private func pagingGesture(width: CGFloat, height: CGFloat) -> PagerPan {
        PagerPan(space: Self.space) { start, dx in
            canPage(from: start, dx: dx, width: width, height: height)
        } onChange: { dx in
            isDragging = true
            dragOffset = resisted(dx, width: width)
        } onEnd: { dx, velocity in
            let forward = dx < -width * 0.3 || (dx < 0 && velocity < -Self.flingVelocity)
            let back = dx > width * 0.3 || (dx > 0 && velocity > Self.flingVelocity)
            let target: MainPage = switch page {
            case .chat: forward ? .files : .chat
            case .files: back ? .chat : (forward ? .cards : .files)
            case .cards: back ? .files : .cards
            }
            settle(on: target)
        } onCancel: {
            settle(on: page)
        }
    }

    /// Штрих по корню «Файлов»: знак открывает скрытые папки, прямой свайп
    /// вправо возвращает к чату, влево — открывает «Карточки»
    private var filesStroke: FilesStrokeGesture {
        FilesStrokeGesture(edgeWidth: Self.edgeWidth) {
            page == .files && filesDepth == 0 && !isDragging && !isSettling
        } onEnd: { stroke in
            if store.folders.contains(where: \.isSuperHidden) {
                var recognized = false
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    recognized = hiddenFolders.revealIfRecognized(stroke.points, in: stroke.screen)
                }
                if recognized { return }
            }
            if stroke.returnsToChat {
                settle(on: .chat)
            } else if stroke.opensCards {
                settle(on: .cards)
            }
        }
    }

    private func canPage(from start: CGPoint, dx: CGFloat, width: CGFloat, height: CGFloat) -> Bool {
        switch page {
        case .chat:
            dx < 0 && start.y < height - composerHeight
        case .files:
            // За пальцем — только от краёв: посередине рисуют секретный знак
            filesDepth == 0 && (dx > 0 ? start.x < Self.edgeWidth : start.x > width - Self.edgeWidth)
        case .cards:
            dx > 0 && factsDepth == 0
        }
    }

    /// За крайней страницей палец тянет с сопротивлением
    private func resisted(_ dx: CGFloat, width: CGFloat) -> CGFloat {
        switch page {
        case .chat: dx > 0 ? dx * 0.25 : max(dx, -width)
        case .files: min(max(dx, -width), width)
        case .cards: dx < 0 ? dx * 0.25 : min(dx, width)
        }
    }
}

/// Свайп между страницами — распознаватель UIKit, а не DragGesture. Он умеет
/// не начаться: при вертикальной прокрутке, над полем ввода, посередине
/// «Файлов», и тогда ничему не мешает. А начавшись, отменяет нажатие под
/// пальцем, как прокрутка. С DragGesture после свайпа от края открывалась
/// папка, на которой начался жест, — это ловил UI-тест
struct PagerPan: UIGestureRecognizerRepresentable {
    /// Пространство пейджера: в нём точка начала сверяется с правилами
    let space: String
    /// Можно ли листать касанием из этой точки в эту сторону
    let allows: (_ start: CGPoint, _ dx: CGFloat) -> Bool
    let onChange: (_ dx: CGFloat) -> Void
    let onEnd: (_ dx: CGFloat, _ velocity: CGFloat) -> Void
    let onCancel: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(converter: converter, space: space, allows: allows)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.allows = allows
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // Окно не едет вместе со страницами: в нём сдвиг пальца честный
        let dx = recognizer.translation(in: nil).x
        switch recognizer.state {
        case .began, .changed:
            onChange(dx)
        case .ended:
            onEnd(dx, recognizer.velocity(in: nil).x)
        case .cancelled, .failed:
            onCancel()
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let converter: CoordinateSpaceConverter
        private let space: String
        var allows: (_ start: CGPoint, _ dx: CGFloat) -> Bool
        /// Точка касания в окне. Перевод пана считается уже после порога
        /// в ~10 pt, и начало по нему вышло бы сдвинутым
        private var touchStart: CGPoint = .zero

        init(converter: CoordinateSpaceConverter, space: String, allows: @escaping (_ start: CGPoint, _ dx: CGFloat) -> Bool) {
            self.converter = converter
            self.space = space
            self.allows = allows
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touchStart = touch.location(in: nil)
            return true
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            let now = recognizer.location(in: nil)
            let moved = CGSize(width: now.x - touchStart.x, height: now.y - touchStart.y)
            // Только явно горизонтальный жест: вертикальный — это прокрутка
            guard abs(moved.width) > 2 * abs(moved.height) else { return false }
            return allows(converter.convert(globalPoint: touchStart, to: .named(space)), moved.width)
        }
    }
}

enum MainPage: CaseIterable, Hashable {
    case chat
    case files
    case cards

    var index: Int {
        switch self {
        case .chat: 0
        case .files: 1
        case .cards: 2
        }
    }

    var title: String {
        switch self {
        case .chat: "Чат"
        case .files: "Файлы"
        case .cards: "Карточки"
        }
    }

    var identifier: String {
        switch self {
        case .chat: "pageChat"
        case .files: "pageFiles"
        case .cards: "pageCards"
        }
    }
}

extension EnvironmentValues {
    /// Страница главного экрана стоит за краем. Её содержимое прячется от
    /// VoiceOver изнутри: модификатор снаружи NavigationStack до экранов
    /// внутри неё не доходит (проверено деревом доступности в UI-тесте)
    @Entry var isOffscreenPage = false
}

/// Глубина навигации «Файлов»: HomeView сообщает, открыта ли папка
struct FilesNavigationDepthKey: PreferenceKey {
    static let defaultValue = 0

    static func reduce(value: inout Int, nextValue: () -> Int) {
        value = max(value, nextValue())
    }
}

/// Высота поля ввода чата вместе с подсказками над ним
struct ChatComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Переключатель страниц — стеклянная капсула, как нижние вкладки iOS 26,
/// которые понравились владельцу, и как соседние кнопки шапки. Выбранная
/// страница подсвечена серой плашкой. Сам стоит на месте, пока страницы едут
private struct PageSwitcher: View {
    let progress: CGFloat
    let onSelect: (MainPage) -> Void

    @ScaledMetric(relativeTo: .subheadline) private var segmentWidth: CGFloat = 76
    /// Вместе с отступами 44 pt — как круглые кнопки по бокам шапки
    private let segmentHeight: CGFloat = 36

    var body: some View {
        let index = min(max(Int(progress.rounded()), 0), MainPage.allCases.count - 1)
        let selected = MainPage.allCases[index]
        HStack(spacing: 0) {
            ForEach(MainPage.allCases, id: \.self) { item in
                Button {
                    onSelect(item)
                } label: {
                    Text(item.title)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(selected == item ? Theme.ink : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: segmentWidth, height: segmentHeight)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(item.identifier)
                .accessibilityAddTraits(selected == item ? .isSelected : [])
            }
        }
        // Только цвет подписей: плашку двигает свайп, и анимация посреди
        // жеста отставала бы от пальца
        .animation(.easeOut(duration: 0.15), value: selected)
        .background(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(0.1))
                .frame(width: segmentWidth, height: segmentHeight)
                .offset(x: progress * segmentWidth)
        }
        .padding(4)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}
