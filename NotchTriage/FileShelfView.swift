import SwiftUI

struct FileShelfView: View {
    @ObservedObject var model: AppModel
    @State private var confirmClear = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        VStack(spacing: 12) {
            toolbar

            if model.fileShelfItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(model.fileShelfItems) { item in
                            FileShelfItemCard(model: model, item: item)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.hidden)
            }

            feedbackBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .disabled(model.panelState.blocksOrdinaryPanelInput)
        .task {
            model.refreshFileShelfAvailability()
        }
        .confirmationDialog(
            "清空暂存架中的全部引用？",
            isPresented: $confirmClear
        ) {
            Button("清空引用", role: .destructive) {
                model.clearFileShelf()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会清除 Notch Triage 中的引用，不会删除或移动原文件。")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("文件暂存架")
                    .font(.system(size: 13, weight: .semibold))
                Text("会话内保留 · \(model.fileShelfItems.count)/\(FileShelfStore.maximumItemCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                model.refreshFileShelfAvailability()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新文件可用状态")

            Button {
                model.chooseFilesForShelf()
            } label: {
                Label("添加文件…", systemImage: "plus")
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                confirmClear = true
            } label: {
                Label("清空", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(model.fileShelfItems.isEmpty)
        }
        .frame(height: 30)
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 58, height: 58)
                .background(.tint.opacity(0.11), in: .rect(cornerRadius: 17))

            Text("把文件拖到刘海区域")
                .font(.headline)

            Text("支持多个文件和文件夹；这里只保存引用，不会移动、复制或修改原文件。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)

            Button("选择文件或文件夹…") {
                model.chooseFilesForShelf()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 20)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var feedbackBar: some View {
        if let feedback = model.fileShelfFeedback {
            Label(feedback, systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            Label(
                "退出 Notch Triage 后自动清空引用",
                systemImage: "clock.arrow.circlepath"
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FileShelfItemCard: View {
    @ObservedObject var model: AppModel
    let item: FileShelfItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(
                    item.isAvailable ? Color.accentColor : Color.secondary
                )
                .frame(width: 38, height: 38)
                .background(.primary.opacity(0.055), in: .rect(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(
                        item.isAvailable ? Color.secondary : Color.red
                    )
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Menu {
                Button("打开", systemImage: "arrow.up.forward.app") {
                    model.openFileShelfItem(item)
                }
                Button("在 Finder 中显示", systemImage: "folder") {
                    model.revealFileShelfItem(item)
                }
                Button("复制", systemImage: "doc.on.doc") {
                    model.copyFileShelfItem(item)
                }
                Divider()
                Button("从暂存架移除", systemImage: "xmark", role: .destructive) {
                    model.removeFileShelfItem(item)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 14))
        .overlay {
            if !item.isAvailable {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.red.opacity(0.25), lineWidth: 0.7)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.openFileShelfItem(item)
        }
        .draggable(item.url) {
            Label(item.name, systemImage: symbol)
                .padding(8)
                .background(.regularMaterial, in: .rect(cornerRadius: 10))
        }
        .contextMenu {
            Button("打开") { model.openFileShelfItem(item) }
            Button("在 Finder 中显示") { model.revealFileShelfItem(item) }
            Button("复制") { model.copyFileShelfItem(item) }
            Divider()
            Button("从暂存架移除", role: .destructive) {
                model.removeFileShelfItem(item)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name)，\(detail)")
        .accessibilityHint("双击打开，或使用操作菜单")
    }

    private var symbol: String {
        if item.isDirectory { return "folder.fill" }
        switch item.url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "webp":
            return "photo.fill"
        case "pdf":
            return "doc.richtext.fill"
        case "zip", "rar", "7z", "tar", "gz":
            return "archivebox.fill"
        case "mp3", "m4a", "wav", "flac":
            return "waveform"
        case "mp4", "mov", "mkv":
            return "film.fill"
        default:
            return "doc.fill"
        }
    }

    private var detail: String {
        guard item.isAvailable else { return "项目不可用" }
        if item.isDirectory { return "文件夹" }
        let kind = item.url.pathExtension.isEmpty
            ? "文件"
            : item.url.pathExtension.uppercased()
        guard let byteSize = item.byteSize else { return kind }
        return "\(kind) · \(ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file))"
    }
}
