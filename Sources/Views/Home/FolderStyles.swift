import SwiftUI

/// Вид папок на главном. Две версии подряд владельцу не понравились (сборка 22
/// и черновик после неё), поэтому их четыре — каждая строго по одному из его
/// референсов 19.11.2026, выбор в «Настройки → Оформление». Общее у трёх
/// референсов, которое обе прежние версии упустили: силуэт с корешком — это
/// передняя стенка, а содержимое выглядывает из-за неё и просвечивает сквозь
/// матовое стекло цветным пятном
enum FolderCardStyle: String, CaseIterable, Identifiable {
    /// Светло-серое матовое стекло, листы за ним, цветная наклейка — «Портфолио»
    case portfolio
    /// Молочное стекло, подкрашенное снимками в белых рамках, наклейка-контур — «My scans»
    case scans
    /// Чёрная папка, белые листы, тёмный матовый карман
    case black
    /// Карточка-папка: название внутри, за ней лист и снимок
    case card

    static let storageKey = "folderStyle"
    /// Светлое «Портфолио» ближе всего к оформлению, которым владелец пользуется
    static let standard = FolderCardStyle.portfolio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portfolio: "Портфолио"
        case .scans: "Снимки"
        case .black: "Чёрные"
        case .card: "Карточки"
        }
    }

    /// Ширина рисунка к высоте. У карточки внутри название — она выше
    var aspectRatio: CGFloat {
        self == .card ? 1.08 : 1.2
    }
}

/// Передняя стенка папки — силуэт с корешком слева сверху, от `top` до низа
/// во всю ширину. Размеры — доли рамки: папка одинакова в сетке и в уменьшенном
/// образце в настройках, а заливки, обводки и маски совпадают без подгонки
struct FolderFront: Shape {
    /// Где начинается корешок — доля высоты
    var top: CGFloat
    /// Ширина корешка — доля ширины
    var tab: CGFloat = 0.46
    /// Ступенька от корешка к корпусу — доля высоты
    var step: CGFloat = 0.09
    /// Радиус углов — доля ширины
    var radius: CGFloat = 0.13

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + rect.height * top, width: rect.width, height: rect.height * (1 - top))
        return FolderShape(tabWidth: tab, tabHeight: rect.height * step, radius: rect.width * radius).path(in: body)
    }
}

/// Карман без корешка у нижнего края — для чёрной папки
struct FolderPocket: Shape {
    var top: CGFloat
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: rect.width * radius, style: .continuous)
            .path(in: CGRect(x: rect.minX, y: rect.minY + rect.height * top, width: rect.width, height: rect.height * (1 - top)))
    }
}

// MARK: - «Портфолио»

/// Светло-серое матовое стекло. Из-за стенки выглядывают листы с загнутым
/// уголком — последние файлы папки, верхом документа наружу; сквозь стекло
/// они видны размытым пятном. Наклейка — справа внизу. В сборках 23–24 листы
/// были пустые, белый и пастельные (владелец 19.11.2026: «почему у папок нет
/// превью вложений»); такие остались у папки без файлов с превью
struct PortfolioFolderArt: View {
    let folder: VaultFolder
    let accent: Color
    /// Сколько всего в папке: листов выглядывает не больше трёх, у пустой — ни одного
    let count: Int
    /// Последние файлы — свои и из вложенных папок
    let preview: [VaultFile]
    let isDropTarget: Bool

    @Environment(\.colorScheme) private var scheme

    private let front = FolderFront(top: 0.2)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let dark = scheme == .dark
            ZStack {
                // Цвет листов чуть растекается вокруг папки, как на референсе
                if count > 0 || isDropTarget {
                    Ellipse()
                        .fill(accent.opacity(isDropTarget ? 0.55 : (dark ? 0.3 : 0.18)))
                        .frame(width: size.width * 0.8, height: size.height * 0.5)
                        .blur(radius: size.width * 0.12)
                        .offset(y: -size.height * 0.12)
                }
                sheets(size)
                front
                    .fill(dark ? Color(white: 0.2) : Color(white: 0.9))
                    .shadow(color: .black.opacity(dark ? 0.45 : 0.07), radius: size.width * 0.06, y: size.width * 0.03)
                // С превью стекло прозрачнее: документ за ним угадывается, а
                // не сливается в серое пятно, как пустые листы
                sheets(size)
                    .blur(radius: size.width * (preview.isEmpty ? 0.05 : 0.022))
                    .opacity(preview.isEmpty ? (dark ? 0.4 : 0.6) : (dark ? 0.62 : 0.72))
                    .mask(front)
                front.fill(LinearGradient(colors: [.white.opacity(dark ? 0.07 : 0.45), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                front.stroke(LinearGradient(colors: [.white.opacity(dark ? 0.22 : 1), .white.opacity(dark ? 0.04 : 0.5)], startPoint: .top, endPoint: .bottom),
                             lineWidth: isDropTarget ? 2 : 1)
                StickerIcon(symbol: folder.icon, color: accent, size: size.width * 0.21)
                    .position(x: size.width * 0.8, y: size.height - size.width * 0.18)
            }
        }
        .accessibilityHidden(true)
    }

    /// Листы правее середины: самый новый файл — спереди. Без превью — белый
    /// лист и пастельные за ним
    private func sheets(_ size: CGSize) -> some View {
        let files = Array(preview.prefix(3).reversed())
        let layout: [(x: CGFloat, angle: Double, tint: Double)] = switch files.isEmpty ? min(count, 3) : files.count {
        case 0: []
        case 1: [(0.56, 3, 0)]
        case 2: [(0.42, -6, 0.5), (0.63, 4, 0)]
        default: [(0.3, -8, 0.3), (0.5, -2, 0.55), (0.68, 5, 0)]
        }
        return ZStack {
            ForEach(Array(layout.enumerated()), id: \.offset) { index, sheet in
                if files.indices.contains(index) {
                    // Лист с превью выше пустого и выглядывает до верха рамки:
                    // над стенкой видна шапка документа
                    PreviewSheet(file: files[index], accent: accent, width: size.width * 0.36, height: size.height * 0.58, cut: 0.24, radius: 0.07)
                        .rotationEffect(.degrees(sheet.angle))
                        .position(x: size.width * sheet.x, y: size.height * 0.3)
                } else {
                    PaperSheet(tint: accent.opacity(sheet.tint))
                        .frame(width: size.width * 0.36, height: size.height * 0.5)
                        .rotationEffect(.degrees(sheet.angle))
                        .position(x: size.width * sheet.x, y: size.height * 0.3)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Лист с превью файла, выглядывающий из папки: виден верх документа,
/// горизонтальный документ — лист шире. Низ листа всё равно за стенкой
struct PreviewSheet: View {
    let file: VaultFile
    let accent: Color
    /// Ширина вертикального листа; горизонтальный — в `widening` раз шире
    let width: CGFloat
    let height: CGFloat
    /// Срез уголка и радиус углов — доли ширины вертикального листа; 0 — без уголка
    var cut: CGFloat = 0
    var radius: CGFloat = 0.1

    @State private var aspect: CGFloat?

    private static var widening: CGFloat { 1.35 }

    init(file: VaultFile, accent: Color, width: CGFloat, height: CGFloat, cut: CGFloat = 0, radius: CGFloat = 0.1) {
        self.file = file
        self.accent = accent
        self.width = width
        self.height = height
        self.cut = cut
        self.radius = radius
        _aspect = State(initialValue: FileThumbnail.cachedAspect(of: file))
    }

    var body: some View {
        let isWide = (aspect ?? 0) > 1.15
        let shape = CutCornerRectangle(radius: width * radius, cut: width * cut)
        // Запрос крупнее листа: превью вписывается в рамку, а лист оно заливает
        FileThumbnail(file: file, accent: accent, size: CGSize(width: width * Self.widening * 1.5, height: height * 1.5),
                      cornerRadius: 0, showsBorder: false, fills: true, alignment: .top) { loaded in
            guard abs((aspect ?? 0) - loaded) > 0.01 else { return }
            aspect = loaded
        }
        .frame(width: isWide ? width * Self.widening : width, height: height, alignment: .top)
        .background(.white)
        .clipShape(shape)
        .overlay(alignment: .topTrailing) {
            if cut > 0 { PageCurl(size: width * cut) }
        }
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }
}

/// Лист с загнутым уголком; `tint` — пастельная заливка поверх белого
struct PaperSheet: View {
    var tint: Color = .clear

    var body: some View {
        GeometryReader { proxy in
            let cut = proxy.size.width * 0.24
            let shape = CutCornerRectangle(radius: proxy.size.width * 0.07, cut: cut)
            shape
                .fill(.white)
                .overlay(shape.fill(tint))
                .overlay(alignment: .topTrailing) { PageCurl(size: cut) }
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        }
    }
}

// MARK: - «Снимки»

/// Молочное стекло, подкрашенное тем, что за ним: из-за стенки выглядывают
/// последние файлы в белых рамках, как отпечатанные снимки. Вокруг — ореол
/// цветом папки, на стекле — наклейка-контур, у нижнего края — кромка кармана
struct ScansFolderArt: View {
    let folder: VaultFolder
    let accent: Color
    let preview: [VaultFile]
    let isDropTarget: Bool

    @Environment(\.colorScheme) private var scheme

    private let front = FolderFront(top: 0.22, tab: 0.44, step: 0.1, radius: 0.11)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let dark = scheme == .dark
            ZStack {
                // Ореол чуть шире стенки — иначе его не видно из-под неё
                front
                    .fill(accent.opacity(isDropTarget ? 0.9 : (dark ? 0.75 : 0.32)))
                    .scaleEffect(1.04)
                    .blur(radius: size.width * 0.07)
                photos(size)
                front.fill(dark ? Color(white: 0.46) : Color(white: 0.95))
                photos(size)
                    .blur(radius: size.width * 0.06)
                    .opacity(dark ? 0.85 : 0.7)
                    .mask(front)
                front.fill(accent.opacity(dark ? 0.24 : 0.1))
                front.fill(LinearGradient(colors: [.white.opacity(dark ? 0.28 : 0.55), .white.opacity(dark ? 0.04 : 0.1)], startPoint: .top, endPoint: .bottom))
                front.stroke(LinearGradient(colors: [.white.opacity(dark ? 0.6 : 1), .white.opacity(dark ? 0.12 : 0.45)], startPoint: .top, endPoint: .bottom),
                             lineWidth: isDropTarget ? 2 : 1)
                Capsule()
                    .fill(.white.opacity(dark ? 0.3 : 0.75))
                    .frame(width: size.width * 0.84, height: 1)
                    .position(x: size.width / 2, y: size.height * 0.91)
                OutlineSticker(symbol: folder.icon, size: size.width * 0.22)
                    .position(x: size.width * 0.21, y: size.height * 0.52)
            }
        }
        .accessibilityHidden(true)
    }

    /// До трёх последних файлов веером; самый новый — спереди
    private func photos(_ size: CGSize) -> some View {
        let shown = Array(preview.prefix(3).reversed())
        let layout: [(x: CGFloat, angle: Double)] = switch shown.count {
        case 1: [(0.55, 4)]
        case 2: [(0.38, -8), (0.62, 5)]
        default: [(0.2, -14), (0.42, -7), (0.64, 5)]
        }
        let side = CGSize(width: size.width * 0.36, height: size.width * 0.34)
        return ZStack {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, file in
                FileThumbnail(file: file, accent: accent, size: side, cornerRadius: size.width * 0.03, showsBorder: false)
                    .padding(size.width * 0.018)
                    .background(.white, in: RoundedRectangle(cornerRadius: size.width * 0.045, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .rotationEffect(.degrees(layout[index].angle))
                    .position(x: size.width * layout[index].x, y: size.height * 0.26)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Наклейка-контур: чёрный значок на белой вырубке, как зверушки в «My scans»
struct OutlineSticker: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        let outline = symbol.replacingOccurrences(of: ".fill", with: "")
        let filled = UIImage(systemName: outline + ".fill") == nil ? outline : outline + ".fill"
        let glyph = Font.system(size: size * 0.6, weight: .semibold)
        ZStack {
            // Белая вырубка — залитый значок, раздвинутый во все стороны
            ForEach(0..<12, id: \.self) { step in
                let angle = Double(step) / 12 * 2 * .pi
                Image(systemName: filled)
                    .font(glyph)
                    .foregroundStyle(.white)
                    .offset(x: cos(angle) * size * 0.07, y: sin(angle) * size * 0.07)
            }
            Image(systemName: filled).font(glyph).foregroundStyle(.white)
            Image(systemName: outline).font(glyph).foregroundStyle(.black)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - «Чёрные»

/// Чёрная папка с корешком, из неё выглядывают белые листы со строками,
/// карман — тёмное матовое стекло: листы за ним — светлое размытое пятно.
/// Монохром; цвет папки — только точка в углу
struct BlackFolderArt: View {
    let folder: VaultFolder
    let accent: Color
    let count: Int
    /// Последние файлы: листы — их превью; без превью — белые со строками
    let preview: [VaultFile]
    let isDropTarget: Bool

    private let back = FolderFront(top: 0, tab: 0.45, step: 0.11, radius: 0.07)
    private let pocket = FolderPocket(top: 0.48, radius: 0.08)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                back
                    .fill(Color(white: 0.04))
                    .shadow(color: .black.opacity(0.3), radius: size.width * 0.05, y: size.width * 0.03)
                back.stroke(.white.opacity(isDropTarget ? 0.6 : 0.1), lineWidth: isDropTarget ? 2 : 1)
                sheets(size)
                pocket.fill(Color(white: 0.1))
                sheets(size)
                    .blur(radius: size.width * 0.045)
                    .opacity(0.6)
                    .mask(pocket)
                pocket.fill(LinearGradient(colors: [Color(white: 0.35).opacity(0.45), .black.opacity(0.88)], startPoint: .top, endPoint: .bottom))
                // Тонкие светлые линии у нижнего края, как на референсе
                ForEach(0..<2, id: \.self) { line in
                    Capsule()
                        .fill(.white.opacity(line == 0 ? 0.13 : 0.08))
                        .frame(width: size.width * 0.84, height: 1)
                        .position(x: size.width / 2, y: size.height * (0.83 + 0.04 * CGFloat(line)))
                }
                pocket.stroke(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                Image(systemName: folder.icon)
                    .font(.system(size: size.width * 0.085, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .position(x: size.width * 0.13, y: size.height * 0.64)
                Circle()
                    .fill(accent)
                    .frame(width: size.width * 0.045, height: size.width * 0.045)
                    .shadow(color: accent, radius: 4)
                    .position(x: size.width * 0.88, y: size.height * 0.64)
            }
        }
        .accessibilityHidden(true)
    }

    private func sheets(_ size: CGSize) -> some View {
        // Самый новый файл — на переднем, среднем листе
        let files = Array(preview.prefix(3).reversed())
        let layout: [(x: CGFloat, top: CGFloat, width: CGFloat, angle: Double)] = switch files.isEmpty ? min(count, 3) : files.count {
        case 0: []
        case 1: [(0.52, 0.2, 0.34, -3)]
        case 2: [(0.36, 0.26, 0.28, -5), (0.6, 0.18, 0.34, 3)]
        default: [(0.26, 0.27, 0.24, 0), (0.79, 0.3, 0.22, 0), (0.53, 0.17, 0.34, -5)]
        }
        return ZStack {
            ForEach(Array(layout.enumerated()), id: \.offset) { index, sheet in
                Group {
                    if files.indices.contains(index) {
                        PreviewSheet(file: files[index], accent: accent, width: size.width * sheet.width, height: size.height * 0.46)
                    } else {
                        LinedSheet()
                            .frame(width: size.width * sheet.width, height: size.height * 0.46)
                    }
                }
                .rotationEffect(.degrees(sheet.angle))
                .position(x: size.width * sheet.x, y: size.height * (sheet.top + 0.23))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Белый лист со строками текста: строка заголовка темнее остальных
struct LinedSheet: View {
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            RoundedRectangle(cornerRadius: width * 0.1, style: .continuous)
                .fill(Color(white: 0.95))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: width * 0.07) {
                        ForEach(0..<3, id: \.self) { line in
                            Capsule()
                                .fill(Color(white: line == 0 ? 0.72 : 0.82))
                                .frame(width: width * (line == 2 ? 0.4 : 0.62), height: max(2, width * 0.06))
                        }
                    }
                    .padding(width * 0.14)
                }
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        }
    }
}

// MARK: - «Карточки»

/// Папка-карточка: название и подпись — внутри стенки, за ней лист с
/// загнутым уголком (у пустой тоже — «записей нет»), у непустой из угла
/// выглядывает последний файл и рядом с названием горит точка цвета папки
struct CardFolderArt: View {
    let folder: VaultFolder
    let accent: Color
    let preview: [VaultFile]
    let subtitle: String
    let isEmpty: Bool
    let isDropTarget: Bool

    @Environment(\.colorScheme) private var scheme

    private let front = FolderFront(top: 0.24, tab: 0.42, step: 0.09, radius: 0.12)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let dark = scheme == .dark
            ZStack {
                sheet(size, dark: dark)
                if let file = preview.first {
                    FileThumbnail(file: file, accent: accent, size: CGSize(width: size.width * 0.34, height: size.width * 0.3),
                                  cornerRadius: size.width * 0.05, showsBorder: false)
                        .rotationEffect(.degrees(6))
                        .position(x: size.width * 0.76, y: size.height * 0.2)
                        .accessibilityHidden(true)
                }
                front
                    .fill(LinearGradient(colors: dark ? [Color(white: 0.3), Color(white: 0.2)] : [.white, Color(white: 0.94)],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(dark ? 0.45 : 0.1), radius: size.width * 0.06, y: size.width * 0.03)
                front.fill(RadialGradient(colors: [.white.opacity(dark ? 0.09 : 0.6), .clear], center: .topLeading,
                                          startRadius: 0, endRadius: size.width * 0.8))
                front.stroke(isDropTarget ? accent : .white.opacity(dark ? 0.12 : 0.9), lineWidth: isDropTarget ? 2 : 1)
                label(size)
            }
        }
    }

    /// Лист за стенкой; у непустой папки на нём значок папки
    private func sheet(_ size: CGSize, dark: Bool) -> some View {
        let width = size.width * 0.42
        let cut = width * 0.24
        let shape = CutCornerRectangle(radius: width * 0.1, cut: cut)
        return shape
            .fill(dark ? Color(white: 0.17) : Color(white: 0.86))
            .overlay(alignment: .topTrailing) {
                FoldedCorner()
                    .fill(dark ? Color(white: 0.32) : Color(white: 0.95))
                    .frame(width: cut, height: cut)
            }
            .overlay(alignment: .center) {
                if !isEmpty {
                    Image(systemName: folder.icon)
                        .font(.system(size: width * 0.24, weight: .semibold))
                        .foregroundStyle(dark ? Color(white: 0.32) : Color(white: 0.72))
                        .offset(y: -width * 0.12)
                }
            }
            .frame(width: width, height: size.height * 0.42)
            .position(x: size.width * 0.5, y: size.height * 0.22)
            .accessibilityHidden(true)
    }

    private func label(_ size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(folder.name)
                    .font(.system(.headline, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if !isEmpty {
                    Circle()
                        .fill(accent)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .center) {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Image(systemName: folder.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.18), lineWidth: 1))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, size.width * 0.09)
        .padding(.top, size.height * 0.33 + size.width * 0.06)
        .padding(.bottom, size.width * 0.08)
        .frame(width: size.width, height: size.height)
    }
}

/// Загнутый уголок листа: треугольник по линии среза
private struct FoldedCorner: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
