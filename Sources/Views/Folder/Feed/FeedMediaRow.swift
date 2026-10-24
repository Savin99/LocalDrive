import SwiftUI

/// Стык внутри ряда: куда встанет перетаскиваемое фото
struct FeedSeam: Equatable, Hashable {
    let blockID: UUID
    let index: Int
}

// Ряд медиа: justified-раскладка плюс невидимые зоны на стыках,
// в которые можно уронить фото из этого же или соседнего ряда
struct FeedMediaRow: View {
    let block: FeedBlock
    let files: [VaultFile]
    let aspects: [Double]
    let accent: Color
    let isSelecting: Bool
    let zoomNamespace: Namespace.ID

    let onOpen: (String) -> Void
    let onDropMedia: (FeedDragPayload, FeedSeam) -> Bool

    @Binding var hoveredSeam: FeedSeam?

    var body: some View {
        JustifiedRowLayout {
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                thumbnail(file, aspect: aspects.indices.contains(index) ? aspects[index] : MediaAspect.fallback)
                    .mediaAspect(aspects.indices.contains(index) ? aspects[index] : MediaAspect.fallback)
                    .justifiedRole(.photo)
            }

            ForEach(0...files.count, id: \.self) { index in
                seam(at: index)
                    .justifiedRole(.seam)
            }
        }
    }

    private func thumbnail(_ file: VaultFile, aspect: Double) -> some View {
        Button {
            onOpen(file.name)
        } label: {
            ZStack {
                FileThumbnail(
                    file: file,
                    accent: accent,
                    size: CGSize(width: 300 * aspect, height: 300),
                    cornerRadius: FeedPage.mediaRadius,
                    showsBorder: false,
                    fills: true
                )

                if file.isPlayable {
                    Image(systemName: "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(11)
                        .background(.black.opacity(0.48), in: Circle())
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
        // Не .disabled: он гасит содержимое, и ряд тускнел в режиме выделения
        .allowsHitTesting(!isSelecting)
        .matchedTransitionSource(id: file.name, in: zoomNamespace)
        .draggable(FeedDragPayload.media(blockID: block.id, fileName: file.name)) {
            FileThumbnail(
                file: file,
                accent: accent,
                size: CGSize(width: 120 * aspect, height: 120),
                cornerRadius: 8,
                showsBorder: false
            )
        }
    }

    private func seam(at index: Int) -> some View {
        let seam = FeedSeam(blockID: block.id, index: index)
        return Color.clear
            .contentShape(Rectangle())
            .overlay {
                if hoveredSeam == seam {
                    Capsule()
                        .fill(accent)
                        .frame(width: 3)
                        .transition(.opacity)
                }
            }
            .dropDestination(for: FeedDragPayload.self) { payload, _ in
                guard let first = payload.first else { return false }
                return onDropMedia(first, seam)
            } isTargeted: { targeted in
                withAnimation(.snappy(duration: 0.15)) {
                    if targeted {
                        hoveredSeam = seam
                    } else if hoveredSeam == seam {
                        hoveredSeam = nil
                    }
                }
            }
    }
}

extension VaultFile {
    var isPlayable: Bool {
        type.conforms(to: .movie) || type.conforms(to: .video)
    }
}
