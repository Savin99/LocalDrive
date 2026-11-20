import SwiftUI

// Лист файла в его собственных пропорциях: горизонтальный сертификат —
// горизонтальный лист, страница — вертикальный, превью видно целиком. Раньше
// любой файл заливал вертикальную плитку, и от горизонтального документа
// оставалась увеличенная середина (владелец 19.11.2026: «некрасивое превью,
// просто растянул на всю»). Под листом — подпись его ширины
struct FileSheet<Caption: View>: View {
    /// Что задано: в сетке — ширина колонки, в ленте — высота ряда
    enum Fit {
        case width(CGFloat)
        case height(CGFloat)
    }

    let file: VaultFile
    let accent: Color
    let fit: Fit
    var radius: CGFloat = 14
    var spacing: CGFloat = 8
    /// Режим выбора: nil — не выбирают; true — лист отмечен
    var selection: Bool?
    @ViewBuilder var caption: () -> Caption

    @State private var aspect: CGFloat?

    /// Самый узкий лист — страница A4, самый широкий — кадр 16:9. Чек в рулон
    /// или панорама обрезаются до этих границ
    private static var narrowest: CGFloat { 0.7 }
    private static var widest: CGFloat { 1.78 }
    /// Пока превью не загрузилось и для файлов без превью
    private static var unknown: CGFloat { 0.8 }

    init(
        file: VaultFile,
        accent: Color,
        fit: Fit,
        radius: CGFloat = 14,
        spacing: CGFloat = 8,
        selection: Bool? = nil,
        @ViewBuilder caption: @escaping () -> Caption
    ) {
        self.file = file
        self.accent = accent
        self.fit = fit
        self.radius = radius
        self.spacing = spacing
        self.selection = selection
        self.caption = caption
        // Пропорции знакомого файла — сразу: лист не прыгает при прокрутке
        _aspect = State(initialValue: FileThumbnail.cachedAspect(of: file))
    }

    private var isVideo: Bool {
        file.type.conforms(to: .movie) || file.type.conforms(to: .video)
    }

    private var size: CGSize {
        let ratio = min(max(aspect ?? Self.unknown, Self.narrowest), Self.widest)
        switch fit {
        case .width(let width): return CGSize(width: width, height: (width / ratio).rounded())
        case .height(let height): return CGSize(width: (height * ratio).rounded(), height: height)
        }
    }

    /// Рамка, в которую превью вписывается целиком при любых пропорциях
    private var requested: CGSize {
        switch fit {
        case .width(let width): CGSize(width: width, height: (width / Self.narrowest).rounded())
        case .height(let height): CGSize(width: (height * Self.widest).rounded(), height: height)
        }
    }

    var body: some View {
        let size = size
        // Фото и видео — без уголка: это не бумага
        let curl = isVideo ? 0 : max(18, min(size.width, size.height) * 0.17)
        let shape = CutCornerRectangle(radius: radius, cut: curl)
        VStack(alignment: .leading, spacing: spacing) {
            FileThumbnail(file: file, accent: accent, size: requested, cornerRadius: 0, showsBorder: false, fills: true) { loaded in
                guard abs((aspect ?? 0) - loaded) > 0.01 else { return }
                withAnimation(.snappy(duration: 0.2)) { aspect = loaded }
            }
            .frame(width: size.width, height: size.height)
            // Лист со срезанным уголком, подгиб — поверх
            .clipShape(shape)
            .overlay(alignment: .topTrailing) {
                if isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 4)
                        .padding(8)
                } else {
                    PageCurl(size: curl)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let badge = file.extensionBadge {
                    TypeBadge(text: badge)
                        .padding(8)
                }
            }
            .overlay {
                if selection == true {
                    ZStack {
                        shape.fill(accent.opacity(0.32))
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(accent)
                            .frame(width: 42, height: 42)
                            .overlay(Image(systemName: "checkmark").font(.system(size: 19, weight: .bold)).foregroundStyle(.white))
                            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .overlay(alignment: .topLeading) {
                if selection == false {
                    FileSelectionMark(isSelected: false, accent: accent)
                        .padding(8)
                }
            }
            .animation(.snappy(duration: 0.18), value: selection)
            .overlay(shape.stroke(Theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 8, y: 4)

            caption()
                .frame(width: size.width, alignment: .leading)
        }
    }
}
