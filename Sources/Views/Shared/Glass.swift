import SwiftUI

// Общие детали интерфейса «Стекло» (референсы владельца 19.11.2026,
// docs/design.md): точечный фон со свечением, шар агента, текст с бликом,
// значок-наклейка. Стекло элементов управления — системное (Liquid Glass),
// здесь — то, чего в системе нет

/// Фон экранов: почти чёрный (днём — светло-серый), точечная сетка и мягкое
/// свечение у края, как у карточки чата в референсе
struct AppBackdrop: View {
    /// Цвет свечения: у папки — её цвет, у чата — холодный белый
    var glow: Color = .white
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Theme.background
            Canvas { context, size in
                let step: CGFloat = 18
                let dot = CGSize(width: 1.4, height: 1.4)
                let color = scheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.06)
                var y: CGFloat = step / 2
                while y < size.height {
                    var x: CGFloat = step / 2
                    while x < size.width {
                        context.fill(Path(ellipseIn: CGRect(origin: CGPoint(x: x, y: y), size: dot)), with: .color(color))
                        x += step
                    }
                    y += step
                }
            }
            RadialGradient(
                colors: [glow.opacity(scheme == .dark ? 0.10 : 0.16), .clear],
                center: UnitPoint(x: 0.0, y: 0.32), startRadius: 0, endRadius: 420
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Шар агента: два полупрозрачных стеклянных шарика. Пока агент думает,
/// они медленно кружат и дышат светом; с «Уменьшить движение» — стоят
struct AgentOrb: View {
    var size: CGFloat = 26
    var isActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(paused: !isActive || reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let angle = isActive && !reduceMotion ? time * 1.6 : 0.8
            let pulse = isActive && !reduceMotion ? 0.5 + 0.5 * sin(time * 2.4) : 0.4
            ZStack {
                // Ореол: вечером — белый, днём — сиреневый, чтобы шар не терялся на светлом
                Circle()
                    .fill(scheme == .dark ? Color.white.opacity(0.10 + 0.12 * pulse)
                                          : Color(red: 0.72, green: 0.66, blue: 1).opacity(0.22 + 0.14 * pulse))
                    .frame(width: size * 1.5, height: size * 1.5)
                    .blur(radius: size * 0.35)
                sphere(size * 0.78)
                    .offset(x: cos(angle) * size * 0.14, y: sin(angle) * size * 0.14)
                sphere(size * 0.84)
                    .offset(x: -cos(angle) * size * 0.12, y: -sin(angle) * size * 0.12)
                // Радужный отлив стекла поверх шариков: холодный и тёплый блик ходят по кругу
                Circle()
                    .fill(AngularGradient(colors: [.cyan, .purple, .pink, .orange, .cyan], center: .center, angle: .radians(angle)))
                    .frame(width: size * 0.9, height: size * 0.9)
                    .blur(radius: size * 0.16)
                    .blendMode(scheme == .dark ? .plusLighter : .softLight)
                    .opacity(scheme == .dark ? 0.28 : 0.55)
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }

    private func sphere(_ diameter: CGFloat) -> some View {
        // Вечером — светящееся стекло, днём — белое стекло с тенью (на
        // iPhone владельца в светлой теме шарики выходили грязно-серыми)
        let dark = scheme == .dark
        let colors: [Color] = dark
            ? [.white.opacity(0.95), .white.opacity(0.32), .white.opacity(0.06)]
            : [.white, .white.opacity(0.8), Color(white: 0.88).opacity(0.55)]
        return Circle()
            .fill(RadialGradient(colors: colors, center: UnitPoint(x: 0.36, y: 0.32), startRadius: 0, endRadius: diameter * 0.62))
            .overlay(Circle().strokeBorder(dark ? Color.white.opacity(0.45) : Color.black.opacity(0.08), lineWidth: 0.6))
            .shadow(color: dark ? .clear : .black.opacity(0.14), radius: diameter * 0.12, y: diameter * 0.05)
            .frame(width: diameter, height: diameter)
            .blendMode(dark ? .screen : .normal)
    }
}

/// Текст с бегущим бликом: «Думаю…», «Ищу в документах…»
struct ShimmerText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                        GeometryReader { proxy in
                            let width = proxy.size.width
                            LinearGradient(colors: [.clear, Theme.ink.opacity(0.95), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: max(40, width * 0.45))
                                .offset(x: -width * 0.45 + (width * 1.45) * phase)
                        }
                        .mask(Text(text))
                    }
                }
            }
    }
}

/// Значок-наклейка: символ на цветной плашке с белой обводкой и тенью, чуть
/// наклонён — как наклейка на стеклянной папке
struct StickerIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [color, color.mix(with: .black, by: 0.18)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(.white, lineWidth: max(1.5, size * 0.07)))
            .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
            .rotationEffect(.degrees(-8))
            .accessibilityHidden(true)
    }
}

/// Счётчик рядом с названием: «Паспорта ③»
struct CountPill: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.well, in: Capsule())
    }
}

/// Силуэт папки: корешок слева сверху и скруглённый корпус
struct FolderShape: Shape {
    var tabWidth: CGFloat = 0.42
    var tabHeight: CGFloat = 14
    var radius: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tab = rect.width * tabWidth
        let r = min(radius, rect.height / 3)
        let tr = min(10, tabHeight)
        // Корешок: левый верхний угол, плавный спуск к корпусу
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + tab - tr, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + tab + tr * 0.6, y: rect.minY + tabHeight * 0.55),
                          control: CGPoint(x: rect.minX + tab, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + tab + tr * 2.2, y: rect.minY + tabHeight),
                          control: CGPoint(x: rect.minX + tab + tr * 1.2, y: rect.minY + tabHeight))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY + tabHeight))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + tabHeight + r), control: CGPoint(x: rect.maxX, y: rect.minY + tabHeight))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Точечная шкала в духе Nothing: точка — месяц до срока, до двух лет вперёд.
/// Мало осталось — оранжевые, срок прошёл — все точки пустые
struct DotMatrixMeter: View {
    /// Сколько месяцев осталось
    let months: Int
    var total = 24

    private var tint: Color {
        months <= 6 ? .orange : Theme.ink
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<total, id: \.self) { index in
                let lit = index < min(max(months, 0), total)
                Circle()
                    .fill(lit ? tint : Theme.ink.opacity(0.14))
                    .frame(width: 7, height: 7)
                    .shadow(color: lit ? tint.opacity(0.55) : .clear, radius: 2)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(months > total ? "Больше двух лет до срока" : "Месяцев до срока: \(max(months, 0))")
    }
}
