import AppKit
import SwiftUI

/// AppKit drag bridge for the visible notch surface.
///
/// Reading file URLs here is part of the user's active drag gesture. The
/// bridge never moves, copies, or edits a source item; it only forwards local
/// file references to `AppModel` after a successful drop.
struct NotchFileDropTarget: NSViewRepresentable {
    let onDragEntered: (_ sessionID: UUID, _ urls: [URL], _ itemCount: Int) -> Bool
    let onDragExited: (_ sessionID: UUID) -> Void
    let onDrop: (_ sessionID: UUID, _ urls: [URL], _ itemCount: Int) -> Bool

    func makeNSView(context: Context) -> FileDropView {
        let view = FileDropView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: FileDropView, context: Context) {
        update(nsView)
    }

    static func dismantleNSView(
        _ nsView: FileDropView,
        coordinator: Void
    ) {
        nsView.cancelCurrentSession()
    }

    private func update(_ view: FileDropView) {
        view.onDragEntered = onDragEntered
        view.onDragExited = onDragExited
        view.onDrop = onDrop
    }
}

extension NotchFileDropTarget {
    final class FileDropView: NSView {
        var onDragEntered: ((UUID, [URL], Int) -> Bool)?
        var onDragExited: ((UUID) -> Void)?
        var onDrop: ((UUID, [URL], Int) -> Bool)?

        private var sessionID: UUID?
        private var isPermitted = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([
                .fileURL,
                .URL,
                .string,
                .png,
                .tiff,
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func draggingEntered(
            _ sender: any NSDraggingInfo
        ) -> NSDragOperation {
            let sessionID = UUID()
            self.sessionID = sessionID
            let payload = Self.payload(from: sender.draggingPasteboard)
            isPermitted = onDragEntered?(
                    sessionID,
                    payload.urls,
                    payload.itemCount
                ) ?? false
            return isPermitted && !payload.urls.isEmpty ? .copy : []
        }

        override func draggingUpdated(
            _ sender: any NSDraggingInfo
        ) -> NSDragOperation {
            let payload = Self.payload(from: sender.draggingPasteboard)
            return !payload.urls.isEmpty && isPermitted ? .copy : []
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            cancelCurrentSession()
        }

        override func prepareForDragOperation(
            _ sender: any NSDraggingInfo
        ) -> Bool {
            isPermitted
                && !Self.payload(from: sender.draggingPasteboard).urls.isEmpty
        }

        override func performDragOperation(
            _ sender: any NSDraggingInfo
        ) -> Bool {
            let payload = Self.payload(from: sender.draggingPasteboard)
            guard isPermitted, !payload.urls.isEmpty else { return false }
            let sessionID = self.sessionID ?? UUID()
            self.sessionID = nil
            let accepted = onDrop?(
                sessionID,
                payload.urls,
                payload.itemCount
            ) ?? false
            isPermitted = false
            if !accepted {
                onDragExited?(sessionID)
            }
            return accepted
        }

        func cancelCurrentSession() {
            guard let sessionID else { return }
            self.sessionID = nil
            isPermitted = false
            onDragExited?(sessionID)
        }

        private static func payload(
            from pasteboard: NSPasteboard
        ) -> (urls: [URL], itemCount: Int) {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [
                .urlReadingFileURLsOnly: true,
            ]
            let urls = (pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: options
            ) as? [NSURL] ?? [])
                .compactMap { $0 as URL }
                .filter(\.isFileURL)
            let itemCount = max(
                pasteboard.pasteboardItems?.count ?? 0,
                urls.count
            )
            return (urls, itemCount)
        }
    }
}
