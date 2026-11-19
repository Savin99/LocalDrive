import SwiftUI

/// Оформление приложения: как в системе, всегда светлое или всегда тёмное
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Как в системе"
        case .light: "Светлое"
        case .dark: "Тёмное"
        }
    }

    /// nil — как в системе
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

// Выбор оформления в настройках — три мини-экрана с галочкой у выбранного,
// как в референсе владельца (19.11.2026)
struct AppearancePicker: View {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue

    var body: some View {
        HStack(spacing: 12) {
            ForEach(AppAppearance.allCases) { option in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { appearance = option.rawValue }
                } label: {
                    VStack(spacing: 8) {
                        preview(option)
                            .frame(height: 96)
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(appearance == option.rawValue ? Theme.accent : Theme.border,
                                                  lineWidth: appearance == option.rawValue ? 2.5 : 1)
                            }
                            .overlay(alignment: .bottomLeading) {
                                if appearance == option.rawValue {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.title3)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, Theme.accent)
                                        .padding(6)
                                }
                            }
                        Text(option.title)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(appearance == option.rawValue ? .isSelected : [])
                .accessibilityIdentifier("appearance-\(option.rawValue)")
            }
        }
        .padding(.vertical, 6)
    }

    /// Мини-экран: шапка, строки и карточка. «Как в системе» — половина светлая, половина тёмная
    @ViewBuilder
    private func preview(_ option: AppAppearance) -> some View {
        switch option {
        case .light: screen(dark: false)
        case .dark: screen(dark: true)
        case .system:
            ZStack {
                screen(dark: false)
                screen(dark: true)
                    .mask(alignment: .trailing) {
                        GeometryReader { proxy in
                            Rectangle().frame(width: proxy.size.width / 2).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
            }
        }
    }

    private func screen(dark: Bool) -> some View {
        let base = dark ? Color(white: 0.08) : Color(white: 0.97)
        let line = dark ? Color(white: 0.25) : Color(white: 0.84)
        return RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(base)
            .overlay(alignment: .top) {
                VStack(spacing: 6) {
                    Capsule().fill(line).frame(width: 26, height: 6)
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(line).frame(height: 18)
                    Capsule().fill(line).frame(height: 5)
                    Capsule().fill(line).frame(width: 40, height: 5).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// «Настройки → Оформление → Вид папок»
struct FolderStyleSettingsView: View {
    var body: some View {
        List {
            Section {
                FolderStylePicker()
            } footer: {
                Text("Каждый вид — по одному из референсов. Образец — ваша первая папка; вид меняется сразу на главном и во вложенных папках.")
            }
        }
        .navigationTitle("Вид папок")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// Вид папок — четыре образца с галочкой у выбранного. В образце — первая
// папка владельца с её файлами: выбирать на своих документах нагляднее
struct FolderStylePicker: View {
    @AppStorage(FolderCardStyle.storageKey) private var style = FolderCardStyle.standard.rawValue
    @Environment(VaultStore.self) private var store

    /// Образец, пока своих папок нет
    private static let sample = VaultFolder(id: UUID(), name: "Документы", icon: "doc.text.fill", color: "indigo", createdAt: .now)

    var body: some View {
        let folder = store.rootFolders.first(where: { !$0.isSuperHidden }) ?? Self.sample
        let stats = store.stats(for: folder)
        let preview = store.previewFiles(in: folder)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(FolderCardStyle.allCases) { option in
                let selected = style == option.rawValue
                Button {
                    withAnimation(.snappy(duration: 0.25)) { style = option.rawValue }
                } label: {
                    VStack(spacing: 8) {
                        // Папка в натуральную ширину, уменьшенная: так образец
                        // точь-в-точь как в сетке, с теми же шрифтами
                        FolderCard(folder: folder, stats: stats, preview: preview, style: option)
                            .frame(width: 168)
                            .scaleEffect(0.8)
                            .frame(width: 134, height: 140)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Theme.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 2.5 : 1)
                            }
                            .overlay(alignment: .bottomLeading) {
                                if selected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.title3)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, Theme.accent)
                                        .padding(6)
                                }
                            }
                            .accessibilityHidden(true)
                        Text(option.title)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Theme.ink)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("folderStyle-\(option.rawValue)")
            }
        }
        .padding(.vertical, 6)
    }
}
