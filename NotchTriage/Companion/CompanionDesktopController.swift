import AppKit
import Combine
import SwiftUI

@MainActor private final class CompanionPanel: NSPanel {
    var permitsKey = false
    override var canBecomeKey: Bool { permitsKey }
    override var canBecomeMain: Bool { false }
}

@MainActor final class CompanionDesktopController: NSObject {
    private let store: CompanionStore
    private weak var model: AppModel?
    private var wastePanels: [UUID: NSPanel] = [:]
    private let petPanel = CompanionPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let gamePanel = CompanionPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let hudPanel = CompanionPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let carePanel = CompanionPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let guidePanel = CompanionPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let careVisibility = CompanionCareVisibility()
    private var outsideClickMonitor: Any?, localClickMonitor: Any?
    private var dragPoint = NSPoint.zero, dragStamp = 0.0, dragOffset = NSPoint.zero
    private var dragLean = 0.0
    private var draggingFromNest = false, leftNestDuringDrag = false
    private var petView: CompanionPetView!
    private var gameView: CompanionGameView!
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var asleep = false, fullscreen = false
    private var lastTime = ProcessInfo.processInfo.systemUptime, lastCheck = 0.0, lastUI = 0.0
    private var previousAction = -1, actionTime = 0.0
    private var nestingStart: Double?, emergingStart: Double?
    private var nestOrigin = NSPoint.zero
    private var roamingTarget: NSPoint?, nextRoam = 0.0
    private var dragging = false, sessionScreen: NSScreen?, lastSessionID: UUID?
    private var sounds: [NSSound] = []
    private var cadence = 1.0
    private var simulationRemainder = 0.0
    private var lastSound = 0.0, lastEventScore = 0, lastHP = 3, lastShots = 0

    init(store: CompanionStore, model: AppModel) {
        self.store = store
        self.model = model
        super.init()
        for panel in [petPanel, gamePanel, hudPanel, carePanel, guidePanel] {
            panel.level = .init(rawValue: NSWindow.Level.statusBar.rawValue + 2)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
        }
        guidePanel.permitsKey = true
        let guideHost = NSHostingView(rootView: CompanionNestGuide(store: store))
        guideHost.sizingOptions = []
        guidePanel.contentView = guideHost
        gamePanel.ignoresMouseEvents = true
        petView = CompanionPetView(store: store, owner: self)
        petPanel.contentView = petView
        gameView = CompanionGameView(store: store)
        gamePanel.contentView = gameView
        let hosting = NSHostingView(rootView: CompanionGameHUD(store: store))
        hosting.sizingOptions = []
        hudPanel.contentView = hosting
        let careHost = NSHostingView(
            rootView: CompanionCarePanel(store: store, visibility: careVisibility) { [weak self] in
                self?.closeCare()
            })
        careHost.sizingOptions = []
        carePanel.contentView = careHost
        carePanel.permitsKey = true
        carePanel.level = .init(rawValue: petPanel.level.rawValue + 1)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.dismissCareOutside() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.dismissCareOutside() }
            return event
        }
        store.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.refresh() } }.store(
            in: &subscriptions)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name).sink { [weak self] _ in self?.suspend()
            }.store(in: &subscriptions)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for: name).sink { [weak self] _ in
                self?.asleep = false
                self?.refresh()
            }.store(in: &subscriptions)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] _ in
                guard let self, let screen = self.screen() else { return }
                let old = self.fullscreen
                self.fullscreen = self.checkFullscreen(screen)
                if self.fullscreen && !old { self.store.pause() }
                self.refresh()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: gamePanel)
            .sink { [weak self] _ in
                guard let self, self.store.session?.manual == true, self.store.session?.paused == false else {
                    return
                }
                self.store.pause()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification).sink {
            [weak self] _ in
            if self?.store.session?.manual == true {
                self?.store.pause()
                self?.refresh()
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).sink {
            [weak self] _ in
            self?.store.pause()
            self?.sessionScreen = nil
            self?.refresh()
        }.store(in: &subscriptions)
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frame() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        store.desktopDragHandler = { [weak self] point in
            guard let self else { return }
            if let point {
                if !self.dragging {
                    self.beginDrag()
                    self.store.emerge()
                    self.refresh()
                }
                self.drag(to: point)
            } else {
                self.endDrag()
            }
        }
        store.start()
        refresh()
    }
    func stop() {
        timer?.invalidate()
        timer = nil
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil
        store.desktopDragHandler = nil
        store.stop()
        hide()
        sounds.forEach { $0.stop() }
    }
    private func suspend() {
        asleep = true
        store.pause()
        store.isVisible = false
        nestingStart = nil
        emergingStart = nil
        hide()
        sounds.forEach { $0.stop() }
    }
    private func hide() {
        closeCare()
        guidePanel.orderOut(nil)
        store.nestFeedback.reset()
        store.nestFeedback.occupied = false
        petPanel.orderOut(nil)
        gamePanel.orderOut(nil)
        hudPanel.orderOut(nil)
        wastePanels.values.forEach { $0.orderOut(nil) }
    }
    private func setCadence(_ interval: Double) {
        guard cadence != interval else { return }
        cadence = interval
        timer?.invalidate()
        timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frame() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    private func screen() -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                == store.preferences.screenID
        } ?? NotchScreen.preferred
    }
    private func safeFrame(_ screen: NSScreen) -> NSRect { screen.visibleFrame.insetBy(dx: 8, dy: 8) }
    private func notch(_ screen: NSScreen) -> NSPoint {
        if let entrance = store.nestFeedback.entrance { return entrance }
        let target = NotchScreen.preferred ?? screen
        let expanded =
            model.map {
                $0.isHoveringNotch || $0.isExpanded || $0.isPanelClosing || $0.systemHUD != nil
                    || $0.panelState.isPresentingFileDropTarget
            } ?? false
        let height =
            expanded
            ? NotchLayout.hoveredHeight : min(model?.menuBarHeight ?? max(target.safeAreaInsets.top, 24), 40)
        return .init(x: target.frame.midX, y: target.frame.maxY - height)
    }
    private func checkFullscreen(_ screen: NSScreen) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
            front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return false }
        guard
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let target = CGRect(
            x: screen.frame.minX, y: top - screen.frame.maxY, width: screen.frame.width,
            height: screen.frame.height)
        return windows.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier,
                (w[kCGWindowLayer as String] as? Int) == 0,
                let b = w[kCGWindowBounds as String] as? NSDictionary,
                let r = CGRect(dictionaryRepresentation: b)
            else { return false }
            return r.intersection(target).width >= target.width - 2
                && r.intersection(target).height >= target.height - 2
        }
    }
    private func refresh() {
        guard store.preferences.enabled, store.pet != nil, !asleep, !fullscreen, let screen = screen() else {
            store.isVisible = false
            hide()
            setCadence(1)
            return
        }
        store.isVisible = true
        refreshWaste(screen)
        let now = ProcessInfo.processInfo.systemUptime
        if previousAction != store.actionRevision {
            previousAction = store.actionRevision
            actionTime = now
            petView.action = store.action
            petView.actionTime = now
            if store.action == "display" { sessionScreen = nil }
            if store.action == "nest" {
                nestingStart = now
                emergingStart = nil
                nestOrigin = petPanel.frame.origin
                closeCare()
                store.nestFeedback.family = store.pet?.family ?? 0
                store.nestFeedback.phase = .entering
            }
            if store.action == "out" {
                closeCare()
                emergingStart = dragging ? nil : now
                nestingStart = nil
                store.nestFeedback.family = store.pet?.family ?? 0
                if !dragging { store.nestFeedback.phase = .exiting }
            }
            playTone(game: false, rising: store.action != "nest")
        }
        if let family = store.pet?.family, store.nestFeedback.family != family {
            store.nestFeedback.family = family
        }
        let occupied = store.preferences.inNest && nestingStart == nil
        if store.nestFeedback.occupied != occupied { store.nestFeedback.occupied = occupied }
        refreshNestGuide(screen)
        setCadence(
            store.session?.paused == false
                ? 1.0 / 60
                : !store.preferences.inNest || nestingStart != nil || emergingStart != nil ? 1.0 / 30 : 1)
        if let s = store.session {
            closeCare()
            if lastSessionID != s.id || sessionScreen == nil && s.paused {
                sessionScreen = screen
                lastSessionID = s.id
                lastEventScore = 0
                lastHP = 3
                lastShots = 0
            }
            guard let gameScreen = sessionScreen, NSScreen.screens.contains(where: { $0 === gameScreen })
            else {
                store.pause()
                hide()
                return
            }
            let frame = safeFrame(gameScreen)
            // A small desktop arcade occupies only a corner of the display.
            let width = min(360.0, frame.width - 24)
            let height = (width - 24) / (s.game == .snake ? 1.5 : 100.0 / 60) + 24
            let arcade = NSRect(
                x: frame.maxX - width - 16, y: frame.minY + 24,
                width: width, height: height)
            gamePanel.setFrame(arcade, display: true)
            hudPanel.setFrame(
                .init(
                    x: arcade.minX, y: arcade.maxY + 4,
                    width: width, height: 116), display: true)
            if !store.preferences.inNest { hudPanel.orderFrontRegardless() } else { hudPanel.orderOut(nil) }
            if s.paused || store.preferences.inNest {
                if store.preferences.inNest {
                    gamePanel.orderOut(nil)
                } else if !gamePanel.isVisible {
                    gamePanel.orderFrontRegardless()
                }
                gameView.needsDisplay = true
                gamePanel.permitsKey = false
                gamePanel.ignoresMouseEvents = true
            } else {
                gamePanel.permitsKey = s.manual
                gamePanel.ignoresMouseEvents = !s.manual
                if !gamePanel.isVisible { gamePanel.orderFrontRegardless() }
                if s.manual && !gamePanel.isKeyWindow {
                    NSApp.activate(ignoringOtherApps: true)
                    gamePanel.makeKey()
                    gameView.window?.makeFirstResponder(gameView)
                }
                if !s.manual && gamePanel.isKeyWindow { gamePanel.resignKey() }
            }
        } else {
            lastSessionID = nil
            sessionScreen = nil
            gamePanel.orderOut(nil)
            hudPanel.orderOut(nil)
        }
        if store.session != nil && nestingStart == nil && !dragging && emergingStart == nil {
            petPanel.orderOut(nil)
            return
        }
        if store.preferences.inNest && nestingStart == nil {
            petPanel.orderOut(nil)
            return
        }
        let size = Double(store.preferences.scale * 40 + 40)
        if petPanel.frame.width != size { petPanel.setContentSize(.init(width: size, height: size)) }
        if !petPanel.isVisible {
            let safe = safeFrame(screen)
            let p = NSPoint(
                x: safe.minX + store.preferences.positionX * (safe.width - size),
                y: safe.minY + store.preferences.positionY * (safe.height - size))
            petPanel.setFrameOrigin(p)
            petPanel.orderFrontRegardless()
        }
    }
    private func frame() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.05, max(0, now - lastTime))
        lastTime = now
        if now - lastCheck >= 1 {
            lastCheck = now
            let was = fullscreen
            fullscreen = screen().map(checkFullscreen) ?? true
            if fullscreen && !was {
                store.pause()
                sounds.forEach { $0.stop() }
            }
            refresh()
        }
        guard store.preferences.enabled, !asleep, !fullscreen, let screen = screen() else { return }
        if let s = store.session {
            if store.preferences.inNest { s.pause() }
            if !s.paused {
                simulationRemainder += dt
                while simulationRemainder >= 1.0 / 120 && !s.paused && !s.finished {
                    s.update(1.0 / 120)
                    simulationRemainder -= 1.0 / 120
                }
            } else {
                simulationRemainder = 0
            }
            if s.shotEvents != lastShots {
                playTone(game: true, rising: true)
                lastShots = s.shotEvents
            }
            if s.score != lastEventScore || s.hp != lastHP {
                playTone(game: true, rising: s.hp >= lastHP)
                lastEventScore = s.score
                lastHP = s.hp
            }
            if !s.paused { gameView.needsDisplay = true }
            if s.finished || now - lastUI >= 0.25 {
                lastUI = now
                store.refreshGameUI()
            }
        }
        let reduced =
            store.preferences.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if store.nestFeedback.reduced != reduced { store.nestFeedback.reduced = reduced }
        petView.walking = false
        petView.carried = dragging
        petView.sleeping = store.preferences.resting || store.pet?.autoResting == true
        let hovered = petPanel.frame.contains(NSEvent.mouseLocation)
        petView.hovered = hovered
        if let start = nestingStart {
            let duration = reduced ? 0.25 : 1.35
            let progress = min(1, (now - start) / duration)
            let target = notch(screen)
            let size = petPanel.frame.size
            // First approach the entrance, then make a small anticipatory crouch
            // and spring through the notch's lower edge. Clip against that real
            // desktop edge, not an arbitrary fraction of the pet's height.
            let approach = min(1, progress / 0.62)
            let eased = approach * approach * (3 - 2 * approach)
            let entranceY = target.y - size.height + 14
            let dive = max(0, (progress - 0.62) / 0.38)
            let lift = reduced ? size.height * dive : size.height * pow(dive, 0.8)
            petPanel.setFrameOrigin(
                .init(
                    x: nestOrigin.x + (target.x - size.width / 2 - nestOrigin.x) * eased,
                    y: nestOrigin.y + (entranceY - nestOrigin.y) * eased + lift))
            petView.walking = progress < 0.62
            petView.clipHeight = max(0, min(size.height, target.y - petPanel.frame.minY))
            store.nestFeedback.progress = progress
            petView.nestSquash =
                reduced
                ? 0 : sin(max(0, min(1, (progress - 0.46) / 0.24)) * .pi) * 0.14 - sin(dive * .pi) * 0.08
            if progress >= 1 {
                nestingStart = nil
                petView.clipHeight = nil
                petView.nestSquash = 0
                petPanel.orderOut(nil)
                store.nestFeedback.reset()
                store.showFirstNestGuide()
                refresh()
            }
        } else if let start = emergingStart {
            let progress = min(1, (now - start) / (reduced ? 0.25 : 1.05))
            let target = notch(screen)
            let eased = 1 - pow(1 - progress, 3)
            petPanel.setFrameOrigin(
                .init(
                    x: target.x - petPanel.frame.width / 2,
                    y: target.y - petPanel.frame.height * (0.12 + eased)))
            petView.clipHeight = max(0, min(petPanel.frame.height, target.y - petPanel.frame.minY))
            store.nestFeedback.progress = progress
            if progress >= 1 {
                emergingStart = nil
                petView.clipHeight = nil
                petView.releaseTime = now
                store.nestFeedback.reset()
                savePosition()
            }
        } else if !dragging && !carePanel.isVisible && !hovered && store.session == nil
            && !store.preferences.resting
            && store.pet?.autoResting == false && (store.pet?.energy ?? 0) >= 20 && !store.preferences.inNest
        {
            if now >= nextRoam && roamingTarget == nil {
                let distance = Double.random(in: 60...180)
                let angle = Double.random(in: 0...(.pi * 2))
                let safe = safeFrame(screen)
                let p = NSPoint(
                    x: min(
                        safe.maxX - petPanel.frame.width,
                        max(safe.minX, petPanel.frame.minX + cos(angle) * distance)),
                    y: min(
                        safe.maxY - petPanel.frame.height - 120,
                        max(safe.minY, petPanel.frame.minY + sin(angle) * distance)))
                if !banned(p, screen: screen) { roamingTarget = p }
                nextRoam = now + Double.random(in: 15...45)
            }
            if let p = roamingTarget {
                let old = petPanel.frame.origin
                let distance = hypot(p.x - old.x, p.y - old.y)
                if distance < 2 {
                    roamingTarget = nil
                    savePosition()
                } else {
                    let travel = min(distance, store.preferences.speed * dt)
                    let position = NSPoint(
                        x: old.x + (p.x - old.x) / distance * travel,
                        y: old.y + (p.y - old.y) / distance * travel)
                    if banned(position, screen: screen) {
                        roamingTarget = nil
                    } else {
                        petView.walking = true
                        petView.facingLeft = p.x < old.x
                        petPanel.setFrameOrigin(position)
                    }
                }
            }
        }
        // Damped swing of the carried body and a gentle return after release.
        dragLean *= exp(-dt * (dragging ? 4 : 10))
        petView.lean = reduced ? 0 : dragLean
        if petPanel.isVisible && !dragging {
            let p = NSEvent.mouseLocation
            let local = NSPoint(x: p.x - petPanel.frame.minX, y: p.y - petPanel.frame.minY)
            petPanel.ignoresMouseEvents = !petView.bodyHit(local)
        }
        if petPanel.isVisible && now - petView.lastDraw >= (reduced ? 0.2 : 1.0 / 30) {
            petView.lastDraw = now
            petView.needsDisplay = true
        }
    }
    private func banned(_ point: NSPoint, screen: NSScreen) -> Bool {
        let frame = NSRect(origin: point, size: petPanel.frame.size)
        if let model {
            if model.isExpanded {
                let workspace = NSRect(
                    x: screen.frame.midX - NotchLayout.expandedPanelWidth / 2,
                    y: screen.frame.maxY - NotchLayout.expandedPanelHeight - model.menuBarHeight,
                    width: NotchLayout.expandedPanelWidth, height: NotchLayout.expandedPanelHeight)
                if frame.intersects(workspace) { return true }
            }
            let lyrics = model.lyrics
            if lyrics.appearance.enabled && lyrics.document != nil {
                let a = lyrics.appearance
                let region = NSRect(
                    x: screen.frame.midX - a.width / 2,
                    y: screen.frame.maxY - model.menuBarHeight - a.gap
                        - LyricsDisplayMetrics.maximumHeight(a), width: a.width,
                    height: LyricsDisplayMetrics.maximumHeight(a))
                if frame.intersects(region) { return true }
            }
        }
        return store.preferences.banned.contains { rect in
            frame.intersects(
                .init(
                    x: screen.visibleFrame.minX + rect.x * screen.visibleFrame.width,
                    y: screen.visibleFrame.minY + rect.y * screen.visibleFrame.height,
                    width: rect.width * screen.visibleFrame.width,
                    height: rect.height * screen.visibleFrame.height))
        }
    }
    private func refreshWaste(_ screen: NSScreen) {
        let objects = store.pet?.wasteObjects.filter { !$0.inNest } ?? []
        let visible = !store.preferences.inNest && store.session == nil
        let ids = Set(objects.map(\.id))
        for id in Array(wastePanels.keys) where !ids.contains(id) {
            wastePanels.removeValue(forKey: id)?.orderOut(nil)
        }
        for object in objects {
            let panel: NSPanel
            if let existing = wastePanels[object.id] {
                panel = existing
            } else {
                panel = CompanionPanel(
                    contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                    defer: false)
                panel.level = petPanel.level
                panel.collectionBehavior = petPanel.collectionBehavior
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.hidesOnDeactivate = false
                panel.isReleasedWhenClosed = false
                panel.contentView = CompanionWasteView { [weak store] in store?.cleanWaste(object.id) }
                wastePanels[object.id] = panel
            }
            let safe = safeFrame(screen)
            panel.setFrame(
                .init(
                    x: safe.minX + object.x * (safe.width - 32), y: safe.minY + object.y * (safe.height - 32),
                    width: 32, height: 24), display: true)
            if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        }
    }
    func beginDrag(at grabPoint: NSPoint? = nil) {
        closeCare()
        store.nestFeedback.reset()
        draggingFromNest = store.preferences.inNest
        leftNestDuringDrag = false
        dragging = true
        petView.carried = true
        dragPoint = grabPoint ?? NSEvent.mouseLocation
        dragStamp = ProcessInfo.processInfo.systemUptime
        dragOffset = NSPoint(x: dragPoint.x - petPanel.frame.minX, y: dragPoint.y - petPanel.frame.minY)
        if !petPanel.isVisible {
            dragOffset = NSPoint(x: petPanel.frame.width / 2, y: petPanel.frame.height / 2)
        }
        petPanel.ignoresMouseEvents = false
        nestingStart = nil
        emergingStart = nil
        petView.clipHeight = nil
        petView.nestSquash = 0
        roamingTarget = nil
        setCadence(1.0 / 30)
        petView.needsDisplay = true
        if petPanel.isVisible { petView.displayIfNeeded() }
        store.pause()
    }
    private func canNest(at pointer: NSPoint, on screen: NSScreen) -> Bool {
        let targetScreen = NotchScreen.preferred ?? screen
        let surface: NSRect
        if let resolved = store.nestFeedback.surfaceFrame {
            surface = resolved
        } else {
            let left =
                model.map { NotchLayout.compactWingWidth(for: $0.leftWingContent, media: $0.media) } ?? 48
            let right =
                model.map { NotchLayout.compactWingWidth(for: $0.rightWingContent, media: $0.media) } ?? 48
            let width = left + (model?.notchWidth ?? 186) + right
            surface = NSRect(
                x: targetScreen.frame.midX - width / 2 + (right - left) / 2,
                y: notch(screen).y, width: width, height: targetScreen.frame.maxY - notch(screen).y)
        }
        let zone = NSRect(
            x: surface.minX - 10, y: surface.minY - 45,
            width: surface.width + 20, height: targetScreen.frame.maxY - surface.minY + 47)
        return zone.contains(pointer) || zone.intersects(petPanel.frame.insetBy(dx: 20, dy: 20))
    }

    func drag(to point: NSPoint) {
        guard let screen = screen() else { return }
        let safe = safeFrame(screen)
        let size = petPanel.frame.size
        let p = NSPoint(
            x: min(safe.maxX - size.width, max(safe.minX, point.x - dragOffset.x)),
            y: min(screen.frame.maxY - size.height / 2, max(safe.minY, point.y - dragOffset.y)))
        let now = ProcessInfo.processInfo.systemUptime
        let delta = max(0.016, now - dragStamp)
        let velocity = (point.x - dragPoint.x) / delta
        dragLean = max(-22, min(22, dragLean * 0.4 - velocity * 0.008))
        dragPoint = point
        dragStamp = now
        petPanel.setFrameOrigin(p)
        petView.carried = true
        petView.lean = store.preferences.reduceMotion ? 0 : dragLean
        petView.needsDisplay = true
        if petPanel.isVisible { petView.displayIfNeeded() }
        let insideNest = canNest(at: point, on: screen)
        if draggingFromNest && !insideNest { leftNestDuringDrag = true }
        petView.nearNest = insideNest && (!draggingFromNest || leftNestDuringDrag)
        store.nestFeedback.family = store.pet?.family ?? 0
        store.nestFeedback.phase = petView.nearNest ? .near : .none
    }
    func endDrag() {
        let shouldNest =
            (!draggingFromNest || leftNestDuringDrag)
            && (screen().map { canNest(at: NSEvent.mouseLocation, on: $0) } ?? false)
        dragging = false
        petView.carried = false
        petView.releaseTime = ProcessInfo.processInfo.systemUptime
        store.nestFeedback.reset()
        if shouldNest {
            store.nest()
            refresh()  // Start the entrance animation in this event, not a later queued store update.
        } else {
            savePosition()
        }
        petView.nearNest = false
        petView.needsDisplay = true
        nextRoam = ProcessInfo.processInfo.systemUptime + 20
    }
    private func savePosition() {
        guard let screen = screen() else { return }
        let safe = safeFrame(screen)
        let frame = petPanel.frame
        store.editPreferences { p in
            p.positionX = min(1, max(0, (frame.minX - safe.minX) / max(1, safe.width - frame.width)))
            p.positionY = min(1, max(0, (frame.minY - safe.minY) / max(1, safe.height - frame.height)))
        }
    }
    private func refreshNestGuide(_ screen: NSScreen) {
        guard store.preferences.inNest, nestingStart == nil, store.nestGuideRequested else {
            guidePanel.orderOut(nil)
            return
        }
        let anchor = notch(screen)
        let safe = (NotchScreen.preferred ?? screen).visibleFrame.insetBy(dx: 8, dy: 8)
        let size = NSSize(width: 350, height: 175)
        guidePanel.setFrame(
            NSRect(
                x: min(safe.maxX - size.width, max(safe.minX, anchor.x - size.width / 2)),
                y: max(safe.minY, anchor.y - size.height - 12), width: size.width, height: size.height),
            display: true)
        if !guidePanel.isVisible { guidePanel.orderFrontRegardless() }
    }
    func toggleCare() {
        if carePanel.isVisible {
            closeCare()
            return
        }
        guard let screen = screen(), store.pet != nil, !store.preferences.inNest else { return }
        roamingTarget = nil
        nextRoam = ProcessInfo.processInfo.systemUptime + 30
        let safe = safeFrame(screen)
        let size = CGSize(width: 414, height: 534)
        let right = petPanel.frame.maxX + 8
        let x = right + size.width <= safe.maxX ? right : petPanel.frame.minX - size.width - 8
        let position = NSPoint(
            x: max(safe.minX, min(safe.maxX - size.width, x)),
            y: max(safe.minY, min(safe.maxY - size.height, petPanel.frame.midY - size.height / 2)))
        carePanel.setFrame(NSRect(origin: position, size: size), display: true)
        careVisibility.visible = true
        carePanel.alphaValue = 0
        carePanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration =
                store.preferences.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? 0 : 0.18
            carePanel.animator().alphaValue = 1
        }
    }
    func closeCare() {
        if careVisibility.visible { careVisibility.visible = false }
        carePanel.orderOut(nil)
    }
    private func dismissCareOutside() {
        guard carePanel.isVisible else { return }
        let point = NSEvent.mouseLocation
        if !carePanel.frame.contains(point) && !petPanel.frame.contains(point) { closeCare() }
    }
    func menu(at event: NSEvent, view: NSView) {
        let menu = NSMenu()
        let entries = [
            ("摸摸", "pet"), ("喂正餐", "meal"), ("吃点心", "snack"), ("洗澡", "bath"), ("清理全部", "clean"),
            ("休息 / 叫醒", "rest"), ("让它玩贪吃蛇", "snake"), ("让它玩星灯航行", "flight"), ("回窝", "nest"),
            ("伙伴设置", "settings"),
        ]
        for (title, command) in entries {
            let item = NSMenuItem(title: title, action: #selector(command(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
    @objc private func command(_ item: NSMenuItem) {
        switch item.representedObject as? String {
        case "nest": store.nest()
        case "rest": store.rest()
        case "snake": store.startGame(.snake)
        case "flight": store.startGame(.flight)
        case "settings": store.openSettings()
        case let kind?: store.care(kind)
        default: break
        }
    }
    private func playTone(game: Bool, rising: Bool) {
        let enabled = game ? store.preferences.gameSound : store.preferences.petSound
        let now = ProcessInfo.processInfo.systemUptime
        guard enabled, now - lastSound > 0.15 else { return }
        lastSound = now
        sounds.removeAll { !$0.isPlaying }
        guard sounds.count < 8 else { return }
        let rate = 22050
        let length = game ? 0.10 : 0.28
        let samples = Int(Double(rate) * length)
        var data = Data()
        func bytes<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        bytes(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        bytes(UInt32(16))
        bytes(UInt16(1))
        bytes(UInt16(1))
        bytes(UInt32(rate))
        bytes(UInt32(rate * 2))
        bytes(UInt16(2))
        bytes(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        bytes(UInt32(samples * 2))
        for n in 0..<samples {
            let t = Double(n) / Double(rate)
            let envelope = sin(.pi * t / length) * exp(-t * 6)
            let frequency = (game ? 520.0 : 660.0) + (rising ? 160 : -160) * t / length
            bytes(Int16(sin(2 * .pi * frequency * t) * envelope * 6500))
        }
        if let sound = NSSound(data: data) {
            sound.volume = Float(game ? store.preferences.gameVolume : store.preferences.petVolume)
            sounds.append(sound)
            sound.play()
        }
    }
}

@MainActor private final class CompanionPetView: NSView {
    let store: CompanionStore
    weak var owner: CompanionDesktopController?
    var action = "", actionTime = 0.0, nearNest = false, lastDraw = 0.0
    var clipHeight: CGFloat?
    var walking = false, carried = false, sleeping = false, hovered = false, facingLeft = false
    var lean = 0.0, releaseTime = -99.0, nestSquash = 0.0
    private var down = NSPoint.zero, didDrag = false
    init(store: CompanionStore, owner: CompanionDesktopController) {
        self.store = store
        self.owner = owner
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { return nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let pet = store.pet else { return }
        let now = ProcessInfo.processInfo.systemUptime
        NSGraphicsContext.saveGraphicsState()
        if let clipHeight { NSRect(x: 0, y: 0, width: bounds.width, height: clipHeight).clip() }
        let idleCycle = now.truncatingRemainder(dividingBy: 28)
        let pose: CompanionPose =
            carried
            ? .carried
            : sleeping
                ? .sleep
                : walking
                    ? .walk
                    : hovered
                        ? .wave
                        : idleCycle < 2.2 ? .stretch : idleCycle < 4 ? .look : idleCycle > 23 ? .groom : .idle
        CompanionArtwork.drawPet(
            pet, rect: bounds.insetBy(dx: 16, dy: 16), time: now, effects: store.preferences.effects,
            reduced: store.preferences.reduceMotion
                || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, action: action,
            actionAge: now - actionTime, previousForm: store.previousForm,
            accessories: store.archive.accessories[pet.id, default: []],
            pose: pose, facingLeft: facingLeft, lean: lean, releaseAge: now - releaseTime, squash: nestSquash)
        NSGraphicsContext.restoreGraphicsState()
        if store.preferences.bubbleWave && (pose == .wave || action == "pet" && now - actionTime < 1.2) {
            let age = pose == .wave ? now.truncatingRemainder(dividingBy: 1.2) : now - actionTime
            NSColor.systemCyan.withAlphaComponent(max(0, 1 - age / 1.2)).setStroke()
            for i in 0..<4 {
                NSBezierPath(
                    ovalIn: .init(x: Double(i) * 20 + 8, y: 30 + age * 40, width: 5, height: 5)
                ).stroke()
            }
        }
        if !carried && (store.preferences.resting || pet.autoResting) {
            ("z" as NSString).draw(
                at: .init(x: bounds.maxX - 20, y: bounds.maxY - 25),
                withAttributes: [
                    .foregroundColor: NSColor.systemMint,
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                ])
        }
    }
    func bodyHit(_ p: NSPoint) -> Bool {
        let r = bounds.insetBy(dx: 16, dy: 16)
        return r.insetBy(dx: r.width * 0.16, dy: r.height * 0.12).contains(p)
    }
    override func mouseDown(with event: NSEvent) {
        down = NSEvent.mouseLocation
        didDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        if !didDrag && hypot(p.x - down.x, p.y - down.y) > 3 {
            didDrag = true
            owner?.beginDrag(at: down)
        }
        if didDrag { owner?.drag(to: p) }
    }
    override func mouseUp(with event: NSEvent) {
        if didDrag { owner?.endDrag() } else { owner?.toggleCare() }
    }
    override func rightMouseDown(with event: NSEvent) { owner?.menu(at: event, view: self) }
}

@MainActor final class CompanionGameView: NSView {
    let store: CompanionStore
    var demoSession: CompanionSession?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(store: CompanionStore) {
        self.store = store
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { return nil }
    private var field: NSRect {
        guard let s = demoSession ?? store.session else { return bounds }
        let aspect = s.game == .snake ? 1.5 : 100.0 / 60
        let available = bounds.insetBy(dx: 12, dy: 12)
        let width = min(available.width, available.height * aspect)
        let height = width / aspect
        return NSRect(
            x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let s = demoSession ?? store.session else { return }
        let f = field
        let accent = s.game == .snake ? NSColor.systemMint : NSColor.systemCyan
        let reduced =
            store.preferences.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let glow = store.preferences.effects
        NSGraphicsContext.saveGraphicsState()
        let shell = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 18, yRadius: 18)
        shell.addClip()
        NSGradient(
            starting: NSColor(calibratedWhite: 0.07, alpha: 0.72 + store.preferences.dim),
            ending: NSColor(calibratedWhite: 0.025, alpha: 0.62 + store.preferences.dim))?.draw(
                in: shell, angle: 90)
        accent.withAlphaComponent(0.3).setStroke()
        shell.lineWidth = 1
        shell.stroke()
        let edge = NSBezierPath(roundedRect: f, xRadius: 8, yRadius: 8)
        accent.withAlphaComponent(0.13).setStroke()
        edge.lineWidth = 1
        edge.stroke()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: f).addClip()
        if s.game == .snake {
            let grid = NSBezierPath()
            for i in 1..<30 {
                let x = f.minX + Double(i) * f.width / 30
                grid.move(to: .init(x: x, y: f.minY))
                grid.line(to: .init(x: x, y: f.maxY))
            }
            for i in 1..<20 {
                let y = f.minY + Double(i) * f.height / 20
                grid.move(to: .init(x: f.minX, y: y))
                grid.line(to: .init(x: f.maxX, y: y))
            }
            NSColor.white.withAlphaComponent(0.035).setStroke()
            grid.lineWidth = 0.5
            grid.stroke()
        } else {
            for i in 0..<32 {
                let x = f.minX + Double((i * 73 + 17) % 997) / 997 * f.width
                let y =
                    f.minY + (Double((i * 41) % 197) + (reduced ? 0 : s.time * Double(5 + i % 3)))
                    .truncatingRemainder(dividingBy: 197) / 197 * f.height
                NSColor.white.withAlphaComponent(i % 3 == 0 ? 0.35 : 0.12).setFill()
                NSRect(x: x, y: y, width: i % 3 == 0 ? 2 : 1, height: 1).fill()
            }
        }
        let unit = f.width / (s.game == .snake ? 30 : 100)
        func point(_ p: CompanionPoint) -> NSPoint { .init(x: f.minX + p.x * unit, y: f.minY + p.y * unit) }
        func pixel(_ p: CompanionPoint, size: Double, color: NSColor) {
            let q = point(p)
            let side = max(1.5, size * unit)
            let r = NSRect(x: q.x - side / 2, y: q.y - side / 2, width: side, height: side)
            NSGraphicsContext.saveGraphicsState()
            if glow > 0 {
                let shadow = NSShadow()
                shadow.shadowColor = color.withAlphaComponent(0.55)
                shadow.shadowBlurRadius = min(7, side * 0.65) * glow
                shadow.set()
            }
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: min(2, side * 0.16), yRadius: min(2, side * 0.16)).fill()
            NSGraphicsContext.restoreGraphicsState()
            if side > 5 {
                color.blended(withFraction: 0.6, of: .white)?.withAlphaComponent(0.6).setFill()
                NSRect(x: r.minX + 2, y: r.minY + 1, width: max(1, side - 4), height: 1).fill()
            }
        }
        func trail(_ p: CompanionPoint, length: Double, color: NSColor) {
            guard glow > 0 else { return }
            let q = point(p)
            let r = NSRect(x: q.x - 1.5, y: q.y, width: 3, height: length)
            NSGradient(
                starting: color.withAlphaComponent(0.65 * min(1, glow)),
                ending: color.withAlphaComponent(0))?.draw(in: r, angle: 90)
        }
        let skin = s.skin
        if s.game == .snake {
            for (i, p) in s.snake.enumerated() {
                let q = CompanionPoint(x: p.x + 0.5, y: p.y + 0.5)
                pixel(
                    q, size: 0.85,
                    color: skin
                        ? .systemPink
                        : (i == 0
                            ? .systemMint
                            : CompanionArtwork.palettes[s.family].withAlphaComponent(
                                max(0.45, 1 - Double(i) / Double(max(1, s.snake.count)) * 0.5))))
                if i == 0 {
                    pixel(.init(x: q.x - 0.18, y: q.y - 0.12), size: 0.12, color: .black)
                    pixel(.init(x: q.x + 0.18, y: q.y - 0.12), size: 0.12, color: .black)
                }
            }
            for p in s.food {
                let q = point(.init(x: p.x + 0.5, y: p.y + 0.5))
                let pulse = reduced ? 0.5 : (sin(s.time * 4) + 1) / 2
                if glow > 0 {
                    NSColor.systemPink.withAlphaComponent((0.15 + pulse * 0.1) * min(1, glow)).setStroke()
                    NSBezierPath(
                        ovalIn: .init(
                            x: q.x - 6 - pulse * 2, y: q.y - 6 - pulse * 2,
                            width: 12 + pulse * 4, height: 12 + pulse * 4)
                    ).stroke()
                }
                pixel(.init(x: p.x + 0.5, y: p.y + 0.5), size: 0.55, color: .systemPink)
                pixel(.init(x: p.x + 0.55, y: p.y + 0.1), size: 0.18, color: .systemGreen)
            }
            if s.manual && s.rank(6) > 0 {
                for i in 1...2 {
                    let v = [
                        CompanionPoint(x: 0, y: -1), .init(x: 1, y: 0), .init(x: 0, y: 1), .init(x: -1, y: 0),
                    ][s.direction]
                    pixel(
                        .init(
                            x: s.snake[0].x + 0.5 + v.x * Double(i), y: s.snake[0].y + 0.5 + v.y * Double(i)),
                        size: 0.18, color: .white.withAlphaComponent(0.4))
                }
            }
        } else {
            for e in s.enemies {
                let c: NSColor = e.boss ? .systemPurple : e.kind == 3 ? .systemOrange : .systemPink
                let r = e.boss ? 5.0 : 1.2
                if !CompanionArcadeArtwork.draw(
                    e.boss ? 3 : e.kind == 3 ? 2 : 1,
                    at: point(e.position), size: e.boss ? 40 : 18, rotated: true)
                {
                    pixel(e.position, size: r * 1.5, color: c)
                    pixel(.init(x: e.position.x - r, y: e.position.y), size: r * 0.8, color: c)
                    pixel(.init(x: e.position.x + r, y: e.position.y), size: r * 0.8, color: c)
                }
                if e.boss {
                    NSColor.systemPink.setFill()
                    NSRect(
                        x: f.minX + f.width * 0.25, y: f.minY + 8,
                        width: f.width * 0.5 * max(0, e.hp / e.maxHP), height: 4
                    ).fill()
                }
                if e.kind == 3 && e.shot > 2.7 {
                    pixel(.init(x: e.position.x, y: e.position.y + 1.8), size: 0.4, color: .systemYellow)
                }
            }
            for b in s.bullets {
                trail(b.position, length: -8, color: .systemOrange)
                if !CompanionArcadeArtwork.draw(5, at: point(b.position), size: 11, rotated: true) {
                    pixel(b.position, size: 0.5, color: .systemOrange)
                }
            }
            for b in s.shots {
                trail(b.position, length: 10, color: .systemCyan)
                if !CompanionArcadeArtwork.draw(4, at: point(b.position), size: 12) {
                    pixel(b.position, size: 0.35, color: .white)
                }
            }
            for p in s.supplies {
                pixel(p, size: 0.9, color: .systemGreen)
                pixel(p, size: 0.4, color: .white)
            }
            if s.time >= s.invulnerableUntil || Int(s.time * 12) % 2 == 0 {
                if glow > 0 {
                    let flame = reduced ? 8 : 9 + sin(s.time * 24) * 3
                    trail(.init(x: s.player.x, y: s.player.y + 1.3), length: flame, color: .systemCyan)
                }
                if skin {
                    let badge = point(s.player)
                    NSColor.systemPink.withAlphaComponent(0.75).setStroke()
                    NSBezierPath(ovalIn: .init(x: badge.x - 11, y: badge.y - 11, width: 22, height: 22))
                        .stroke()
                }
                if !CompanionArcadeArtwork.draw(0, at: point(s.player), size: 22) {
                    pixel(
                        s.player, size: 1.1, color: skin ? .systemPink : CompanionArtwork.palettes[s.family])
                    pixel(.init(x: s.player.x, y: s.player.y - 0.9), size: 0.8, color: .white)
                    pixel(.init(x: s.player.x - 1, y: s.player.y + 0.5), size: 0.8, color: .systemMint)
                    pixel(.init(x: s.player.x + 1, y: s.player.y + 0.5), size: 0.8, color: .systemMint)
                }
            }
            // The small bright cockpit dot exposes the unchanged collision core.
            if s.manual {
                pixel(s.player, size: 0.35, color: .white)
            }
            if s.charges > 0 {
                NSColor.systemCyan.withAlphaComponent(0.45).setStroke()
                let p = point(s.player)
                if glow > 0 { CompanionArcadeArtwork.draw(7, at: p, size: 34, alpha: 0.55) }
                NSBezierPath(
                    ovalIn: .init(x: p.x - 2 * unit, y: p.y - 2 * unit, width: 4 * unit, height: 4 * unit)
                ).stroke()
            }
        }
        if store.preferences.effects > 0 && !store.preferences.reduceMotion
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        {
            for p in s.particles {
                let q = point(p.position)
                let age = 0.45 - p.life
                if s.game == .flight {
                    let frame = min(3, max(0, Int(age / 0.45 * 4)))
                    let explosion = p.kind == 1 && p.size >= 1 || p.kind == 2
                    if CompanionArcadeArtwork.draw(
                        (explosion ? 12 : 8) + frame, at: q,
                        size: explosion ? min(68, 24 + p.size * 6) : 20,
                        alpha: min(1, p.life / 0.12) * min(1, glow))
                    {
                        continue
                    }
                }
                let radius = (p.size + age * 6) * unit
                NSGraphicsContext.saveGraphicsState()
                let color: NSColor = p.kind == 1 ? .systemOrange : p.kind == 2 ? .systemPink : .systemMint
                let shadow = NSShadow()
                shadow.shadowBlurRadius = 6 * store.preferences.effects
                shadow.shadowColor = color.withAlphaComponent(0.4)
                shadow.set()
                color.withAlphaComponent(p.life / 0.45).setFill()
                for i in 0..<8 {
                    let angle = Double(i) * .pi / 4
                    NSRect(x: q.x + cos(angle) * radius, y: q.y + sin(angle) * radius, width: 3, height: 3)
                        .fill()
                }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if s.paused {
            ("已暂停" as NSString).draw(
                at: .init(x: bounds.midX - 22, y: bounds.midY - 7),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white,
                ])
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    private func direction(_ code: UInt16) -> Int? {
        switch code {
        case 126, 13: return 0
        case 124, 2: return 1
        case 125, 1: return 2
        case 123, 0: return 3
        default: return nil
        }
    }
    override func keyDown(with event: NSEvent) {
        guard let s = store.session, s.manual else { return }
        if event.keyCode == 53 {
            store.pause()
            return
        }
        guard !s.paused, let dir = direction(event.keyCode) else { return }
        if s.game == .snake { if !event.isARepeat { s.turn(dir) } } else { s.keys.insert(dir) }
    }
    override func keyUp(with event: NSEvent) {
        if let dir = direction(event.keyCode) { store.session?.keys.remove(dir) }
    }
    override func mouseDown(with event: NSEvent) { mouseDragged(with: event) }
    override func mouseDragged(with event: NSEvent) {
        guard let s = store.session, s.manual, s.game == .flight else { return }
        let p = convert(event.locationInWindow, from: nil)
        let f = field
        s.mouseTarget = .init(x: (p.x - f.minX) / f.width * 100, y: (p.y - f.minY) / f.height * 60)
    }
}

private struct CompanionGameHUD: View {
    @ObservedObject var store: CompanionStore
    var body: some View {
        if let s = store.session {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: s.game == .snake ? "square.grid.3x3.fill" : "paperplane.fill")
                        .foregroundStyle(s.game == .snake ? Color.mint : Color.cyan)
                    Text(s.game.title).font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    Text("\(s.score)").font(
                        .system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                    Text("分").font(.caption2).foregroundStyle(.secondary)
                    Text(s.game == .snake ? "\(s.snake.count) 格" : "\(s.wave) 波 · ♥ \(s.hp)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Text(s.manual ? "你在操作" : "伙伴在玩")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(s.manual ? "交还" : "接管") { store.handoff() }
                    Button(s.paused ? "继续" : "暂停") {
                        if s.paused { store.resume() } else { store.pause() }
                    }.disabled(!s.candidates.isEmpty)
                    if !s.candidates.isEmpty {
                        Button("遗物") { store.openSettings("小游戏") }
                    }
                    Button {
                        store.nest()
                    } label: {
                        Image(systemName: "house")
                    }
                    .help("回窝并保存本局").accessibilityLabel("回窝并保存本局")
                    Button {
                        store.finish()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("结束并结算").accessibilityLabel("结束并结算")
                }.font(.caption)
                relicSlots(s)
            }
            .buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
            .padding(4)
        }
    }

    @ViewBuilder private func relicSlots(_ session: CompanionSession) -> some View {
        HStack(spacing: 5) {
            Text("固定").font(.system(size: 9)).foregroundStyle(.secondary)
            ForEach(0..<2, id: \.self) { index in
                relicSlot(session.permanent.indices.contains(index) ? session.permanent[index] : nil,
                          rank: 1, game: session.game, permanent: true)
            }
            Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 20).padding(.horizontal, 2)
            Text("本局").font(.system(size: 9)).foregroundStyle(.secondary)
            let numbers = session.temporary.keys.sorted()
            ForEach(0..<6, id: \.self) { index in
                relicSlot(numbers.indices.contains(index) ? numbers[index] : nil,
                          rank: numbers.indices.contains(index) ? session.temporary[numbers[index]] ?? 1 : 0,
                          game: session.game, permanent: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder private func relicSlot(_ number: Int?, rank: Int, game: CompanionGame,
                                        permanent: Bool) -> some View {
        if let number {
            let relic = CompanionCatalog.relics(game)[number-1]
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let icon = CompanionRelicArtwork.image(game: game, number: number) {
                        Image(nsImage: icon).resizable().interpolation(.none).scaledToFit()
                    } else {
                        Image(systemName: "sparkle").resizable().scaledToFit().padding(6)
                            .foregroundStyle(permanent ? .mint : .cyan)
                    }
                }
                .padding(2)
                Text("R\(rank)").font(.system(size: 7, weight: .bold, design: .rounded))
                    .padding(.horizontal, 2).background(.black.opacity(0.72), in: Capsule())
            }
            .frame(width: 27, height: 27)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                (permanent ? Color.mint : Color.cyan).opacity(0.38), lineWidth: 0.7))
            .help("\(permanent ? "固定遗物" : "本局遗物")：\(relic.name) R\(rank) · \(relic.effect)")
            .accessibilityLabel("\(relic.name)，R\(rank)")
        } else {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.white.opacity(0.13), style: StrokeStyle(lineWidth: 0.8, dash: [2, 2]))
                .frame(width: 27, height: 27)
                .accessibilityLabel(permanent ? "固定遗物空槽" : "本局遗物空槽")
        }
    }
}

@MainActor private final class CompanionWasteView: NSView {
    let clean: () -> Void
    init(clean: @escaping () -> Void) {
        self.clean = clean
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { return nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(red: 0.65, green: 0.43, blue: 0.28, alpha: 1).setFill()
        NSRect(x: 8, y: 4, width: 16, height: 5).fill()
        NSRect(x: 11, y: 9, width: 10, height: 5).fill()
        NSRect(x: 14, y: 14, width: 4, height: 4).fill()
        NSColor.white.withAlphaComponent(0.5).setFill()
        NSRect(x: 12, y: 10, width: 2, height: 2).fill()
    }
    override func mouseUp(with event: NSEvent) { clean() }
}
