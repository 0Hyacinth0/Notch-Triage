import AppKit
import Combine
import SwiftUI

@MainActor private struct LyricsOverlayContent: View {
    @ObservedObject var store: LyricsStore
    var body: some View {
        Group {
            if store.previewing {
                LyricsDisplayView(document: .demo, appearance: store.appearance, elapsed: { _ in 0 }, demo: true)
            } else if let document = store.document {
                LyricsDisplayView(document: document, appearance: store.appearance, elapsed: { store.elapsed(at: $0) }, playing: store.media.isPlaying, spectrum: store.spectrum)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}

@MainActor final class LyricsOverlayController {
    private let model: AppModel
    private let panel: NSPanel
    private var subscriptions = Set<AnyCancellable>()
    private var asleep = false
    private var measuredDocument: LyricsDocument?
    private var measuredAppearance: LyricsAppearance?
    private var measuredWidth: CGFloat = 0
    private var measuredHeight: CGFloat = 100
    init(model: AppModel) {
        self.model = model
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        model.lyrics.objectWillChange.sink { [weak self] in
            // Published emits before assignment; update visibility with the committed values.
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &subscriptions)
        model.$panelState.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        for event in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: event).sink { [weak self] _ in self?.asleep = true; self?.refresh() }.store(in: &subscriptions)
        }
        for event in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: event).sink { [weak self] _ in self?.asleep = false; self?.refresh() }.store(in: &subscriptions)
        }
        refresh()
    }
    private func refresh() {
        let store = model.lyrics
        guard !asleep, model.panelState.mode == .compact,
              store.previewing || (store.appearance.enabled && store.document != nil && store.canSynchronize),
              let screen = NotchScreen.preferred else {
            store.setSpectrumVisible(false)
            panel.orderOut(nil)
            // Remove the animated tree as well as the window while hidden.
            panel.contentView = nil
            return
        }
        store.setSpectrumVisible(!store.previewing)
        let width = min(LyricsDisplayMetrics.width(contentWidth: store.appearance.width, appearance: store.appearance), screen.frame.width - 8)
        let document = store.previewing ? LyricsDocument.demo : store.document ?? .demo
        // Allocate for every line, so the media polling interval cannot crop a
        // newly wrapped line between two snapshot updates.
        if measuredDocument != document || measuredAppearance != store.appearance || measuredWidth != width {
            measuredHeight = document.lines.map { LyricsDisplayMetrics.height(document: document, time: $0.start, appearance: store.appearance, width: width) }.max() ?? 100
            measuredDocument = document; measuredAppearance = store.appearance; measuredWidth = width
        }
        let height = min(screen.frame.height - model.menuBarHeight, measuredHeight)
        let inset = LyricsDisplayMetrics.topInset(store.appearance)
        let menu = NotchLayout.menuBarHeight(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - menu - store.appearance.gap + inset - height, width: width, height: height), display: true)
        if panel.contentView == nil {
            let hosting = NSHostingView(rootView: LyricsOverlayContent(store: store))
            hosting.sizingOptions = []
            panel.contentView = hosting
        }
        panel.orderFrontRegardless()
    }
}

enum NotchScreen {
    @MainActor static var preferred: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
