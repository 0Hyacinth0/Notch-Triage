import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let persistentUtilityReason =
        "Notch Triage remains available while its panel is collapsed"
    let model = AppModel()
    private var panelController: NotchPanelController?
    private var settingsWindowController: SettingsWindowController?

    nonisolated static func shouldStartAppServices(
        environment: [String: String]
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The hosted XCTest runner launches the app executable but does not
        // guarantee a graceful applicationWillTerminate callback. Starting
        // long-lived media helpers there would orphan them when the test host
        // exits, so pure model tests keep the app shell dormant.
        guard Self.shouldStartAppServices(
            environment: ProcessInfo.processInfo.environment
        ) else { return }

        // SwiftUI can opt accessory apps into AppKit automatic termination
        // when no conventional window is visible. The notch panel is meant
        // to remain resident even while collapsed, so keep the process alive.
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = true
        ProcessInfo.processInfo.disableAutomaticTermination(
            persistentUtilityReason
        )
        NSApp.setActivationPolicy(.accessory)

        let settingsController = SettingsWindowController(model: model)
        settingsWindowController = settingsController
        model.settingsWindowOpener = { [weak settingsController] in
            settingsController?.show()
        }

        let controller = NotchPanelController(model: model)
        panelController = controller
        controller.show()
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.settingsWindowOpener = nil
        model.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func showNotchPanel() {
        panelController?.show()
    }
}

@MainActor
private final class SettingsWindowTitleSink {
    weak var window: NSWindow?

    func update(for paneTitle: String) {
        window?.title = "Notch Triage 设置 — \(paneTitle)"
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let titleSink: SettingsWindowTitleSink

    init(model: AppModel) {
        let titleSink = SettingsWindowTitleSink()
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(
            rootView: SettingsRootView(
                model: model,
                onPaneChange: { [weak titleSink] paneTitle in
                    titleSink?.update(for: paneTitle)
                }
            )
        )
        settingsWindow.contentView = hostingView
        window = settingsWindow
        self.titleSink = titleSink
        super.init()

        titleSink.window = window
        titleSink.update(for: "外观")
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 780, height: 540)
        window.delegate = self
        let frameAutosaveName = "NotchTriage.SettingsWindow"
        if !window.setFrameUsingName(frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(frameAutosaveName)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

@MainActor
private final class InteractiveNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class NotchPanelController {
    private let model: AppModel
    private let panel: NSPanel
    private var cancellables = Set<AnyCancellable>()
    private var resizeRevision = 0
    private var scheduledResizeTask: Task<Void, Never>?
    private var frameAnimationTimer: Timer?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var outsideCollapseTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model

        panel = InteractiveNotchPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: NotchLayout.panelWidth,
                height: model.menuBarHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = false
        let hostingView = NSHostingView(rootView: NotchRootView(model: model))
        hostingView.sizingOptions = []
        panel.contentView = hostingView

        installOutsideClickMonitors()

        model.$panelState
            .map { $0.windowGeometryPhase }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.scheduleResize(animated: true)
            }
            .store(in: &cancellables)

        model.$panelState
            .map { !$0.isExpanded && !$0.isPresentingFileDropTarget }
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self, self.panel.isKeyWindow else {
                    return
                }
                self.panel.resignKey()
            }
            .store(in: &cancellables)

        model.$panelState
            .map(\.isPresentingFileDropTarget)
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.outsideCollapseTask?.cancel()
                self?.outsideCollapseTask = nil
            }
            .store(in: &cancellables)

        model.$fileDropInFlightSessionID
            .removeDuplicates()
            .compactMap { $0 }
            .sink { [weak self] _ in
                // A fast drop can be accepted before SwiftUI has mounted the
                // visible DropTarget. Cancel the mouse-up dismissal as soon
                // as the accepted session is marked, rather than relying on
                // the target override to appear first.
                self?.outsideCollapseTask?.cancel()
                self?.outsideCollapseTask = nil
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.scheduleResize(animated: false)
            }
            .store(in: &cancellables)
    }

    deinit {
        scheduledResizeTask?.cancel()
        outsideCollapseTask?.cancel()
        frameAnimationTimer?.invalidate()
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
        }
    }

    func show() {
        resize(
            state: model.panelState,
            animated: false
        )
        panel.orderFrontRegardless()
    }

    private func scheduleResize(animated: Bool) {
        scheduledResizeTask?.cancel()
        scheduledResizeTask = Task { @MainActor [weak self] in
            // Published SwiftUI state can change while AppKit is in its
            // constraint pass. Resizing the hosting window synchronously in
            // that callback causes _postWindowNeedsUpdateConstraints to trap.
            // Defer one display interval and coalesce intermediate states.
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, let self else { return }
            self.resize(
                state: self.model.panelState,
                animated: animated
            )
        }
    }

    private func resize(
        state: PanelState,
        animated: Bool
    ) {
        guard let screen = preferredScreen() else { return }
        let shouldAnimate = animated
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let menuBarHeight = NotchLayout.menuBarHeight(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
        let notchWidth = resolvedNotchWidth(on: screen)

        model.menuBarHeight = menuBarHeight
        model.notchWidth = notchWidth

        let leftWingWidth = NotchLayout.compactWingWidth(
            for: model.leftWingContent,
            media: model.media
        )
        let rightWingWidth = NotchLayout.compactWingWidth(
            for: model.rightWingContent,
            media: model.media
        )

        // The resize is deferred by one display interval above. During close,
        // windowGeometryPhase points directly at the final compact/Peek frame
        // while SwiftUI keeps the workspace mounted until the animation ends.
        let geometry = NotchLayout.geometry(
            screenFrame: screen.frame,
            menuBarHeight: menuBarHeight,
            phase: state.windowGeometryPhase,
            compactSurfaceWidth: NotchLayout.compactSurfaceWidth(
                leftWingWidth: leftWingWidth,
                notchWidth: notchWidth,
                rightWingWidth: rightWingWidth
            ),
            compactSurfaceHorizontalOffset: NotchLayout.compactSurfaceHorizontalOffset(
                leftWingWidth: leftWingWidth,
                rightWingWidth: rightWingWidth
            )
        )
        let frame = geometry.windowFrame
        let expanded = state.isExpanded
        let hovering = state.isHoveringNotch
        let closing = state.isPanelClosing
        let canvasExpanded = state.isNotchCanvasExpanded

        // Hover animation runs entirely inside a stationary Peek canvas.
        // Growing that canvas immediately avoids compositor lag between the
        // window frame and SwiftUI's black surface. The canvas is collapsed
        // only after SwiftUI reports logical animation completion.
        if !expanded, !closing, (hovering || canvasExpanded), shouldAnimate {
            resizeRevision += 1
            frameAnimationTimer?.invalidate()
            frameAnimationTimer = nil
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            return
        }

        if !expanded, !closing, !hovering, !canvasExpanded, shouldAnimate {
            resizeRevision += 1
            frameAnimationTimer?.invalidate()
            frameAnimationTimer = nil
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            return
        }

        resizeRevision += 1
        let revision = resizeRevision
        let wasExpanded = panel.frame.height > NotchLayout.hoveredHeight + 40

        frameAnimationTimer?.invalidate()
        frameAnimationTimer = nil

        guard shouldAnimate else {
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            return
        }

        let duration: TimeInterval
        let curve: FrameAnimationCurve
        if closing {
            duration = 0.30
            curve = .close
        } else if expanded {
            duration = 0.38
            curve = .open
        } else if hovering {
            duration = 0.28
            curve = .hover
        } else if wasExpanded {
            duration = 0.30
            curve = .close
        } else {
            duration = 0.28
            curve = .hover
        }

        animatePanel(
            to: frame,
            duration: duration,
            curve: curve,
            revision: revision
        )
        panel.orderFrontRegardless()
    }

    private func animatePanel(
        to targetFrame: NSRect,
        duration: TimeInterval,
        curve: FrameAnimationCurve,
        revision: Int
    ) {
        let startFrame = panel.frame
        guard startFrame != targetFrame, duration > 0 else {
            panel.setFrame(targetFrame, display: true)
            return
        }

        let startTime = Date.timeIntervalSinceReferenceDate
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self,
                      self.resizeRevision == revision else {
                    timer.invalidate()
                    return
                }

                let elapsed = Date.timeIntervalSinceReferenceDate - startTime
                let linearProgress = min(1, max(0, elapsed / duration))
                let progress = curve.value(at: CGFloat(linearProgress))
                let interpolatedFrame = NSRect(
                    x: startFrame.origin.x
                        + (targetFrame.origin.x - startFrame.origin.x) * progress,
                    y: startFrame.origin.y
                        + (targetFrame.origin.y - startFrame.origin.y) * progress,
                    width: startFrame.width
                        + (targetFrame.width - startFrame.width) * progress,
                    height: startFrame.height
                        + (targetFrame.height - startFrame.height) * progress
                )

                self.panel.setFrame(interpolatedFrame, display: true)

                if linearProgress >= 1 {
                    timer.invalidate()
                    self.frameAnimationTimer = nil
                    self.panel.setFrame(targetFrame, display: true)
                }
            }
        }
        timer.tolerance = 1 / 480
        frameAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func installOutsideClickMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            // A global monitor only receives clicks delivered to other apps,
            // so every event here begins outside this panel. Delay dismissal
            // until mouse-up: an active Finder drag may still enter the notch,
            // in which case the drop target or accepted session cancels it.
            Task { @MainActor [weak self] in
                self?.scheduleGlobalOutsideCollapse()
            }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self,
                      event.window === self.panel else {
                    return
                }
                if event.type == .leftMouseDown,
                   !self.panel.isKeyWindow {
                    // The compact notch is a nonactivating panel, but a direct
                    // click is an explicit request to interact with it. Make
                    // the panel key without activating the owning app so the
                    // system renders active Liquid Glass while it is in use.
                    self.panel.makeKey()
                }
                let location = self.panel.convertPoint(
                    toScreen: event.locationInWindow
                )
                self.collapseIfNeeded(at: location)
            }
            return event
        }
    }

    private func scheduleGlobalOutsideCollapse() {
        outsideCollapseTask?.cancel()
        outsideCollapseTask = Task { @MainActor [weak self] in
            while NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled,
                  let self,
                  self.model.isExpanded,
                  self.model.pendingFileDropSessionID == nil,
                  !self.model.isFileDropInFlight,
                  !self.model.panelState.isPresentingFileDropTarget else {
                return
            }
            self.model.collapseExpanded()
        }
    }

    private func collapseIfNeeded(at screenPoint: NSPoint) {
        guard model.isExpanded,
              !expandedSurfaceFrame.contains(screenPoint) else {
            return
        }
        model.collapseExpanded()
    }

    private var expandedSurfaceFrame: NSRect {
        NotchLayout.workspaceVisibleSurfaceFrame(in: panel.frame)
    }

    private func resolvedNotchWidth(on screen: NSScreen) -> CGFloat {
        let measuredWidth: CGFloat?
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            measuredWidth = rightArea.minX - leftArea.maxX
        } else {
            measuredWidth = nil
        }
        return NotchLayout.resolvedNotchWidth(
            hasSafeArea: screen.safeAreaInsets.top > 0,
            measuredWidth: measuredWidth
        )
    }

    private func preferredScreen() -> NSScreen? {
        if let builtIn = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] != nil)
                && $0.safeAreaInsets.top > 0
        }) {
            return builtIn
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

private enum FrameAnimationCurve {
    case open
    case close
    case hover

    func value(at progress: CGFloat) -> CGFloat {
        let progress = min(1, max(0, progress))
        switch self {
        case .open:
            return smootherstep(progress)
        case .close:
            if progress < 0.5 {
                return 4 * pow(progress, 3)
            }
            return 1 - pow(-2 * progress + 2, 3) / 2
        case .hover:
            // Quintic smootherstep: monotonic, with zero velocity and
            // acceleration at both ends. This keeps the 120 Hz resize fluid
            // without the spring-like kick of SwiftUI's smooth preset.
            return smootherstep(progress)
        }
    }

    private func smootherstep(_ progress: CGFloat) -> CGFloat {
        let value = progress * progress * progress
            * (progress * (progress * 6 - 15) + 10)
        return min(1, max(0, value))
    }
}
