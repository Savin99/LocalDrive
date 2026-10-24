import SwiftUI

// Предложение разложить файлы. Пока не нажали «Выполнить», в хранилище ничего
// не меняется. «Другая папка…» ставит выбранную папку всем сохранениям и
// переносам. Состояние — в FileProposalLedger: пересозданная карточка не даст
// выполнить предложение второй раз
struct FileProposalCardView: View {
    let proposal: FileProposal

    @Environment(VaultStore.self) private var store
    @Environment(ChatAttachmentInbox.self) private var inbox: ChatAttachmentInbox?
    @State private var picking = false

    private var ledger: FileProposalLedger { .shared }

    var body: some View {
        let status = ledger.status(of: proposal.id)
        let effective = ledger.effective(proposal)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .accessibilityHidden(true)
                Text(proposal.summary)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(effective.actions.enumerated()), id: \.offset) { _, action in
                    actionRow(action)
                }
            }

            footer(status)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .sheet(isPresented: $picking) {
            FolderPickerSheet(
                transfer: FileTransfer(mode: .move, files: []),
                currentFolderID: nil,
                onPick: { folder in ledger.retarget(proposal.id, to: folder.id) },
                customTitle: "Куда положить",
                customSubject: proposal.summary
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chatCard-proposal")
    }

    // MARK: - Действия

    private func actionRow(_ action: FileProposal.Action) -> some View {
        let (symbol, text) = describe(action)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func describe(_ action: FileProposal.Action) -> (String, String) {
        switch action {
        case .saveAttachment(let id, let folder, let name):
            let original = inbox?.item(id)?.name ?? inbox?.names[id] ?? "вложение"
            var text = "«\(original)» → \(folderLabel(folder))"
            if let name, name != original { text += " как «\((name as NSString).deletingPathExtension)»" }
            return ("square.and.arrow.down", text)
        case .moveFiles(let files, let folder):
            let what = files.count <= 2
                ? files.map { "«\($0.name)»" }.joined(separator: ", ")
                : pluralize(files.count, "файл", "файла", "файлов")
            return ("folder", "Перенести \(what) → \(folderLabel(folder))")
        case .renameFile(let file, let newName):
            return ("pencil", "«\(file.name)» → «\(newName)»")
        case .createFolder(let name):
            return ("folder.badge.plus", "Новая папка «\(name)»")
        }
    }

    private func folderLabel(_ target: FolderTarget) -> String {
        switch target {
        case .existing: "«\(FileProposalBuilder.folderTitle(target, store: store))»"
        case .new(let name): "«\(name)» (новая папка)"
        }
    }

    // MARK: - Кнопки и итог

    @ViewBuilder
    private func footer(_ status: FileProposalLedger.Status) -> some View {
        switch status {
        case .pending:
            ChatChipFlow(spacing: 8) {
                Button {
                    let inbox = self.inbox ?? ChatAttachmentInbox.unavailable
                    Task { await ledger.run(proposal, store: store, inbox: inbox) }
                } label: {
                    Label("Выполнить", systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .primaryCapsule()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("proposalApply")

                if proposal.placesFiles {
                    Button {
                        picking = true
                    } label: {
                        Text("Другая папка…")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .secondaryCapsule()
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("proposalOtherFolder")
                }

                Button {
                    ledger.cancel(proposal.id)
                } label: {
                    Text("Отмена")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .secondaryCapsule()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("proposalCancel")
            }
        case .running:
            HStack(spacing: 8) {
                ProgressView()
                Text("Выполняю…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .done(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("proposalResult")
        case .failed(let text):
            VStack(alignment: .leading, spacing: 8) {
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("proposalResult")
                Button("Попробовать ещё раз") { ledger.reset(proposal.id) }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
            }
        case .cancelled:
            Text("Отменено — ничего не изменилось")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("proposalResult")
        }
    }
}

/// Вложение в переписке: превью и имя. Если файл уже сохранили или убрали,
/// остаётся имя
struct ChatAttachmentCardView: View {
    let id: String

    @Environment(ChatAttachmentInbox.self) private var inbox: ChatAttachmentInbox?

    var body: some View {
        let item = inbox?.item(id)
        HStack(spacing: 10) {
            if let item {
                FileThumbnail(file: item.previewFile, accent: Theme.ink, size: CGSize(width: 44, height: 44), cornerRadius: 10)
            } else {
                Image(systemName: "doc")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item?.name ?? inbox?.names[id] ?? "Вложение")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.map { RussianFormat.size($0.byteCount) }
                     ?? inbox?.savedFolders[id].map { "Сохранён в «\($0)»" }
                     ?? "уже не во вложениях")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .cardStyle(cornerRadius: 16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chatCard-attachment")
    }
}
