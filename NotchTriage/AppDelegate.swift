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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow

    init(model: AppModel) {
        let hostingView = NSHostingView(rootView: SettingsRootView(model: model))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Notch Triage 设置"
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 780, height: 540)
        window.contentView = hostingView
        window.delegate = self
        window.setFrameAutosaveName("NotchTriage.SettingsWindow")
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
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

    private let panelWidth: CGFloat = 560
    private let hoveredHeight: CGFloat = 74
    private let expandedGap: CGFloat = 16
    private let expandedPanelHeight: CGFloat = 460

    init(model: AppModel) {
        self.model = model

        panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: panelWidth,
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
        panel.becomesKeyOnlyIfNeeded = true
        let hostingView = NSHostingView(rootView: NotchRootView(model: model))
        hostingView.sizingOptions = []
        panel.contentView = hostingView

        installOutsideClickMonitors()

        Publishers.CombineLatest4(
            model.$isExpanded.removeDuplicates(),
            model.$isHoveringNotch.removeDuplicates(),
            model.$isPanelClosing.removeDuplicates(),
            model.$isNotchCanvasExpanded.removeDuplicates()
        )
            .sink { [weak self] _, _, _, _ in
                self?.scheduleResize(animated: true)
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
            expanded: model.isExpanded,
            hovering: model.isHoveringNotch,
            closing: model.isPanelClosing,
            canvasExpanded: model.isNotchCanvasExpanded,
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
                expanded: self.model.isExpanded,
                hovering: self.model.isHoveringNotch,
                closing: self.model.isPanelClosing,
                canvasExpanded: self.model.isNotchCanvasExpanded,
                animated: animated
            )
        }
    }

    private func resize(
        expanded: Bool,
        hovering: Bool,
        closing: Bool,
        canvasExpanded: Bool,
        animated: Bool
    ) {
        guard let screen = preferredScreen() else { return }
        let shouldAnimate = animated
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let menuBarHeight = max(
            32,
            screen.frame.maxY - screen.visibleFrame.maxY
        )
        let notchWidth = resolvedNotchWidth(on: screen)

        model.menuBarHeight = menuBarHeight
        model.notchWidth = notchWidth

        let height: CGFloat
        if closing {
            // Keep the canvas expanded while SwiftUI fades the surface out.
            // Shrinking a window that still contains the fixed-height panel
            // creates a constraint re-entry crash on macOS 27.
            height = hoveredHeight
                + expandedGap
                + expandedPanelHeight
        } else if expanded {
            height = hoveredHeight
                + expandedGap
                + expandedPanelHeight
        } else if hovering || canvasExpanded {
            height = max(menuBarHeight, hoveredHeight)
        } else {
            height = menuBarHeight
        }
        let frame = NSRect(
            x: screen.frame.midX - panelWidth / 2,
            y: screen.frame.maxY - height,
            width: panelWidth,
            height: height
        )

        // Hover animation runs entirely inside a stationary 74 pt canvas.
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
        let wasExpanded = panel.frame.height > hoveredHeight + 40

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
            // so every event here is unambiguously outside this panel.
            Task { @MainActor [weak self] in
                guard let self, self.model.isExpanded else { return }
                self.model.collapseExpanded()
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
                let location = self.panel.convertPoint(
                    toScreen: event.locationInWindow
                )
                self.collapseIfNeeded(at: location)
            }
            return event
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
        let visibleHeight = hoveredHeight + expandedGap + expandedPanelHeight
        return NSRect(
            x: panel.frame.midX - 260,
            y: panel.frame.maxY - visibleHeight,
            width: 520,
            height: visibleHeight
        )
    }

    private func resolvedNotchWidth(on screen: NSScreen) -> CGFloat {
        guard screen.safeAreaInsets.top > 0,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else {
            return 168
        }

        let leftEdge = leftArea.maxX
        let rightEdge = rightArea.minX
        let measuredWidth = rightEdge - leftEdge

        guard measuredWidth.isFinite, measuredWidth > 100 else {
            return 186
        }
        return measuredWidth
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
