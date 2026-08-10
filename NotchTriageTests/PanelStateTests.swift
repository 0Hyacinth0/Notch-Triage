import CoreGraphics
import XCTest

@testable import NotchTriage

final class PanelStateTests: XCTestCase {
    func testInitialStateProjectsCompactPresentation() {
        let state = PanelState()

        XCTAssertEqual(state.mode, .compact)
        XCTAssertEqual(state.geometryPhase, .compact)
        XCTAssertEqual(state.windowGeometryPhase, .compact)
        XCTAssertFalse(state.isExpanded)
        XCTAssertFalse(state.isPanelClosing)
        XCTAssertFalse(state.usesExpandedNotchShape)
        XCTAssertFalse(state.isHoveringNotch)
        XCTAssertFalse(state.isNotchCanvasExpanded)
        XCTAssertTrue(state.canShowNotificationPulse)
    }

    func testHoverCollapseRejectsStaleCompletionAfterPointerReenters() {
        var state = PanelState()
        XCTAssertEqual(state.reduce(.pointerEntered), [.cancelHoverCollapse])
        XCTAssertEqual(state.mode, .peek)

        XCTAssertEqual(
            state.reduce(.pointerExited),
            [
                .cancelHoverCollapse,
                .scheduleHoverCollapse(revision: 2, delayMilliseconds: 130),
            ]
        )
        XCTAssertEqual(
            state.reduce(.hoverCollapseDelayElapsed(revision: 2)),
            []
        )
        XCTAssertEqual(state.mode, .compact)
        XCTAssertTrue(state.isCanvasHeldOpen)

        _ = state.reduce(.pointerEntered)
        _ = state.reduce(.hoverCollapseAnimationCompleted(revision: 2))

        XCTAssertEqual(state.mode, .peek)
        XCTAssertFalse(state.isCanvasHeldOpen)
    }

    func testWorkspaceClosePreservesTargetVersionTwoStageCanvasRelease() {
        var state = PanelState()
        _ = state.reduce(.workspaceOpened)
        XCTAssertTrue(state.usesExpandedNotchShape)

        XCTAssertEqual(
            state.reduce(.workspaceCloseRequested),
            [
                .cancelHoverCollapse,
                .cancelWorkspaceClose,
                .cancelUpdatePromptPresentation,
                .scheduleWorkspaceClose(
                    revision: 2,
                    surfaceDelayMilliseconds: 340,
                    canvasDelayMilliseconds: 320
                ),
            ]
        )
        XCTAssertEqual(state.mode, .closingWorkspace)
        XCTAssertEqual(state.geometryPhase, .workspace)
        XCTAssertEqual(state.windowGeometryPhase, .workspace)
        XCTAssertTrue(state.usesExpandedNotchShape)

        _ = state.reduce(.workspaceSurfaceCloseDelayElapsed(revision: 2))
        XCTAssertEqual(state.mode, .compact)
        XCTAssertEqual(state.geometryPhase, .peek)
        XCTAssertEqual(state.windowGeometryPhase, .peek)
        XCTAssertTrue(state.isCanvasHeldOpen)

        _ = state.reduce(.workspaceCanvasCloseDelayElapsed(revision: 2))
        XCTAssertFalse(state.isCanvasHeldOpen)
        XCTAssertEqual(state.geometryPhase, .compact)
    }

    func testReopeningWorkspaceInvalidatesOldCloseCallbacks() {
        var state = PanelState()
        _ = state.reduce(.workspaceOpened)
        _ = state.reduce(.workspaceCloseRequested)
        _ = state.reduce(.workspaceOpened)

        _ = state.reduce(.workspaceSurfaceCloseDelayElapsed(revision: 2))
        _ = state.reduce(.workspaceCanvasCloseDelayElapsed(revision: 2))

        XCTAssertEqual(state.mode, .workspace)
        XCTAssertEqual(state.geometryPhase, .workspace)
    }

    func testPointerEventsDuringClosingDoNotChangeTargetVersionClose() {
        var state = PanelState()
        _ = state.reduce(.workspaceOpened)
        _ = state.reduce(.workspaceCloseRequested)
        _ = state.reduce(.pointerEntered)
        XCTAssertEqual(state.geometryPhase, .workspace)
        XCTAssertEqual(state.windowGeometryPhase, .workspace)

        _ = state.reduce(.workspaceSurfaceCloseDelayElapsed(revision: 2))

        XCTAssertEqual(state.mode, .compact)
        XCTAssertEqual(state.geometryPhase, .peek)
        XCTAssertFalse(state.isPointerInside)

        _ = state.reduce(.workspaceCanvasCloseDelayElapsed(revision: 2))
        XCTAssertEqual(state.geometryPhase, .compact)
    }

    func testHUDUsesKindSpecificTimeoutAndRejectsStaleDismissal() {
        var state = PanelState()
        let volume = SystemHUDSnapshot.volume(0.4, muted: false)
        let brightness = SystemHUDSnapshot.brightness(0.8)

        XCTAssertEqual(
            state.reduce(.hudReceived(volume)),
            [
                .cancelHUDDismiss,
                .scheduleHUDDismiss(revision: 1, delayMilliseconds: 1_650),
            ]
        )
        XCTAssertEqual(state.geometryPhase, .peek)

        XCTAssertEqual(
            state.reduce(.hudReceived(brightness)),
            [
                .cancelHUDDismiss,
                .scheduleHUDDismiss(revision: 2, delayMilliseconds: 1_650),
            ]
        )
        _ = state.reduce(.hudDismissDelayElapsed(revision: 1))
        XCTAssertEqual(state.systemHUD, brightness)

        _ = state.reduce(.hudDismissDelayElapsed(revision: 2))
        XCTAssertNil(state.systemHUD)
        XCTAssertTrue(state.isCanvasHeldOpen)
        _ = state.reduce(.hudDismissAnimationCompleted(revision: 2))
        XCTAssertEqual(state.geometryPhase, .compact)

        let airPods = SystemHUDSnapshot.airPods(name: "AirPods Pro")
        XCTAssertEqual(
            state.reduce(.hudReceived(airPods)),
            [
                .cancelHUDDismiss,
                .scheduleHUDDismiss(revision: 3, delayMilliseconds: 2_600),
            ]
        )
    }

    func testClosingAndReleaseOverrideBlockHUD() {
        var state = PanelState()
        let volume = SystemHUDSnapshot.volume(0.5, muted: false)
        _ = state.reduce(.workspaceOpened)
        _ = state.reduce(.workspaceCloseRequested)

        XCTAssertEqual(state.reduce(.hudReceived(volume)), [])
        XCTAssertNil(state.systemHUD)

        _ = state.reduce(.workspaceOpened)
        let promptID = UUID()
        _ = state.reduce(.releaseUpdatePromptPresented(id: promptID))
        XCTAssertTrue(state.blocksOrdinaryPanelInput)
        XCTAssertEqual(state.reduce(.hudReceived(volume)), [])
        XCTAssertNil(state.systemHUD)

        _ = state.reduce(.releaseUpdatePromptDismissed(id: UUID()))
        XCTAssertTrue(state.blocksOrdinaryPanelInput)
        _ = state.reduce(.releaseUpdatePromptDismissed(id: promptID))
        XCTAssertFalse(state.blocksOrdinaryPanelInput)
    }

    func testActivitySuspensionClearsHUDAndCanvasHold() {
        var state = PanelState()
        _ = state.reduce(.hudReceived(.brightness(0.5)))
        let revision = state.effectRevisions.hud
        _ = state.reduce(.hudDismissDelayElapsed(revision: revision))
        XCTAssertTrue(state.isCanvasHeldOpen)

        XCTAssertEqual(state.reduce(.activitySuspended), [.cancelHUDDismiss])
        XCTAssertNil(state.systemHUD)
        XCTAssertFalse(state.isCanvasHeldOpen)
        XCTAssertEqual(state.geometryPhase, .compact)
    }

    func testAutomaticPromptUsesRevisionedEffectAndCloseCancelsIt() {
        var state = PanelState()

        XCTAssertEqual(
            state.reduce(
                .automaticUpdateWorkspaceRequested(releaseVersion: "2.0")
            ),
            [
                .cancelHoverCollapse,
                .cancelWorkspaceClose,
                .cancelUpdatePromptPresentation,
                .scheduleUpdatePromptPresentation(
                    revision: 1,
                    releaseVersion: "2.0",
                    delayMilliseconds: 240
                ),
            ]
        )
        XCTAssertEqual(state.mode, .workspace)

        let effects = state.reduce(.workspaceCloseRequested)
        XCTAssertTrue(effects.contains(.cancelUpdatePromptPresentation))
        XCTAssertEqual(state.effectRevisions.update, 2)
    }

    func testInstallingOverrideHasPriorityAndOpensWorkspace() {
        var state = PanelState()
        let effects = state.reduce(.installStarted)

        XCTAssertEqual(state.mode, .workspace)
        XCTAssertEqual(state.presentationOverride, .installingUpdate)
        XCTAssertTrue(effects.contains(.cancelWorkspaceClose))
        XCTAssertTrue(effects.contains(.cancelUpdatePromptPresentation))

        XCTAssertEqual(
            state.reduce(.releaseUpdatePromptPresented(id: UUID())),
            []
        )
        XCTAssertEqual(state.presentationOverride, .installingUpdate)
    }

    func testFileDragFromCompactUsesPeekAndRejectsStaleExit() {
        var state = PanelState()
        let sessionID = UUID()
        let effects = state.reduce(
            .fileDragEntered(
                sessionID: sessionID,
                acceptance: .accepted(count: 2)
            )
        )

        XCTAssertEqual(state.mode, .compact)
        XCTAssertEqual(state.geometryPhase, .peek)
        XCTAssertEqual(
            state.presentationOverride,
            .fileDropTarget(
                sessionID: sessionID,
                acceptance: .accepted(count: 2),
                returnMode: .compact
            )
        )
        XCTAssertTrue(effects.contains(.cancelWorkspaceClose))

        _ = state.reduce(.fileDragExited(sessionID: UUID()))
        XCTAssertTrue(state.isPresentingFileDropTarget)

        _ = state.reduce(.fileDragExited(sessionID: sessionID))
        XCTAssertNil(state.presentationOverride)
        XCTAssertEqual(state.geometryPhase, .compact)
    }

    func testFileDropFromWorkspaceReturnsWorkspaceAndSuccessOpensShelfCanvas() {
        var state = PanelState()
        _ = state.reduce(.workspaceOpened)
        let sessionID = UUID()
        _ = state.reduce(
            .fileDragEntered(
                sessionID: sessionID,
                acceptance: .partial(
                    acceptedCount: 1,
                    rejectedCount: 1,
                    reason: "仅支持本地文件"
                )
            )
        )

        XCTAssertEqual(
            state.presentationOverride,
            .fileDropTarget(
                sessionID: sessionID,
                acceptance: .partial(
                    acceptedCount: 1,
                    rejectedCount: 1,
                    reason: "仅支持本地文件"
                ),
                returnMode: .workspace
            )
        )

        _ = state.reduce(.fileDropSucceeded(sessionID: sessionID))
        XCTAssertNil(state.presentationOverride)
        XCTAssertEqual(state.mode, .workspace)
        XCTAssertEqual(state.geometryPhase, .workspace)
    }

    func testFileDragFromPeekRestoresPeekBeforeNormalPointerCollapse() {
        var state = PanelState()
        _ = state.reduce(.pointerEntered)
        let sessionID = UUID()
        _ = state.reduce(
            .fileDragEntered(
                sessionID: sessionID,
                acceptance: .accepted(count: 1)
            )
        )

        XCTAssertEqual(
            state.presentationOverride,
            .fileDropTarget(
                sessionID: sessionID,
                acceptance: .accepted(count: 1),
                returnMode: .peek
            )
        )
        _ = state.reduce(.fileDragExited(sessionID: sessionID))
        XCTAssertEqual(state.mode, .peek)

        let effects = state.reduce(.pointerExited)
        XCTAssertTrue(effects.contains {
            if case .scheduleHoverCollapse = $0 { return true }
            return false
        })
    }

    func testUpdateAndInstallOverridesBlockOrReplaceFileDragByPriority() {
        var state = PanelState()
        let dropID = UUID()
        _ = state.reduce(
            .fileDragEntered(
                sessionID: dropID,
                acceptance: .accepted(count: 1)
            )
        )
        let promptID = UUID()
        _ = state.reduce(.releaseUpdatePromptPresented(id: promptID))
        XCTAssertEqual(
            state.presentationOverride,
            .releaseUpdatePrompt(id: promptID)
        )
        XCTAssertEqual(
            state.reduce(
                .fileDragEntered(
                    sessionID: UUID(),
                    acceptance: .accepted(count: 1)
                )
            ),
            []
        )

        _ = state.reduce(.installStarted)
        XCTAssertEqual(state.presentationOverride, .installingUpdate)
    }

    func testActivitySuspensionCancelsFileDropAndRestoresReturnMode() {
        var state = PanelState()
        _ = state.reduce(.workspaceOpened)
        let sessionID = UUID()
        _ = state.reduce(
            .fileDragEntered(
                sessionID: sessionID,
                acceptance: .accepted(count: 1)
            )
        )

        XCTAssertEqual(state.reduce(.activitySuspended), [.cancelHUDDismiss])
        XCTAssertNil(state.presentationOverride)
        XCTAssertEqual(state.mode, .workspace)

        _ = state.reduce(.fileDragExited(sessionID: sessionID))
        XCTAssertEqual(state.mode, .workspace)
    }

    func testActivitySuspensionReleasesPeekDropCanvas() {
        var state = PanelState()
        _ = state.reduce(.pointerEntered)
        let sessionID = UUID()
        _ = state.reduce(
            .fileDragEntered(
                sessionID: sessionID,
                acceptance: .accepted(count: 1)
            )
        )

        _ = state.reduce(.activitySuspended)

        XCTAssertNil(state.presentationOverride)
        XCTAssertEqual(state.mode, .compact)
        XCTAssertEqual(state.geometryPhase, .compact)
    }
}

final class NotchLayoutTests: XCTestCase {
    func testXCTestHostDoesNotStartLongLivedAppServices() {
        XCTAssertFalse(
            AppDelegate.shouldStartAppServices(
                environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]
            )
        )
        XCTAssertTrue(AppDelegate.shouldStartAppServices(environment: [:]))
    }

    func testPanelHeightsPreserveExistingGeometry() {
        XCTAssertEqual(
            NotchLayout.panelHeight(menuBarHeight: 32, phase: .compact),
            32
        )
        XCTAssertEqual(
            NotchLayout.panelHeight(menuBarHeight: 32, phase: .peek),
            74
        )
        XCTAssertEqual(
            NotchLayout.panelHeight(menuBarHeight: 90, phase: .peek),
            90
        )
        XCTAssertEqual(
            NotchLayout.panelHeight(menuBarHeight: 32, phase: .workspace),
            550
        )
    }

    func testWindowAndVisibleSurfaceFramesShareOneProjection() {
        let screen = CGRect(x: 0, y: 0, width: 1_512, height: 982)
        let peek = NotchLayout.geometry(
            screenFrame: screen,
            menuBarHeight: 32,
            phase: .peek,
            compactSurfaceWidth: 272,
            compactSurfaceHorizontalOffset: -18.5
        )
        XCTAssertEqual(peek.windowFrame, CGRect(x: 476, y: 908, width: 560, height: 74))
        XCTAssertEqual(
            peek.hoverTrackingFrame,
            CGRect(x: 601.5, y: 908, width: 272, height: 74)
        )
        XCTAssertEqual(peek.dropHitFrame, peek.hoverTrackingFrame)

        let workspace = NotchLayout.geometry(
            screenFrame: screen,
            menuBarHeight: 32,
            phase: .workspace
        )
        XCTAssertEqual(
            workspace.windowFrame,
            CGRect(x: 476, y: 432, width: 560, height: 550)
        )
        XCTAssertEqual(
            workspace.visibleSurfaceFrame,
            CGRect(x: 496, y: 432, width: 520, height: 550)
        )
        XCTAssertEqual(
            workspace.hoverTrackingFrame,
            CGRect(x: 476, y: 908, width: 560, height: 74)
        )
        XCTAssertEqual(workspace.dropHitFrame, workspace.hoverTrackingFrame)
        XCTAssertTrue(workspace.visibleSurfaceFrame.contains(CGPoint(x: 496, y: 500)))
        XCTAssertFalse(workspace.visibleSurfaceFrame.contains(CGPoint(x: 495, y: 500)))
    }

    func testMenuBarHeightUsesExistingMinimum() {
        let screen = CGRect(x: 100, y: 50, width: 1_200, height: 900)
        XCTAssertEqual(
            NotchLayout.menuBarHeight(
                screenFrame: screen,
                visibleFrame: CGRect(x: 100, y: 50, width: 1_200, height: 876)
            ),
            32
        )
        XCTAssertEqual(
            NotchLayout.menuBarHeight(
                screenFrame: screen,
                visibleFrame: CGRect(x: 100, y: 50, width: 1_200, height: 852)
            ),
            48
        )
    }

    func testCompactSurfaceAndNotchFallbacksAreCentralized() {
        XCTAssertEqual(
            NotchLayout.compactSurfaceWidth(
                leftWingWidth: 37,
                notchWidth: 186,
                rightWingWidth: 37
            ),
            272
        )
        XCTAssertEqual(
            NotchLayout.peekSurfaceWidth(compactSurfaceWidth: 272),
            272
        )
        XCTAssertEqual(
            NotchLayout.peekSurfaceWidth(compactSurfaceWidth: 510),
            510
        )
        XCTAssertEqual(
            NotchLayout.peekSurfaceWidth(compactSurfaceWidth: 800),
            560
        )
        XCTAssertEqual(
            NotchLayout.compactSurfaceHorizontalOffset(
                leftWingWidth: 37,
                rightWingWidth: 0
            ),
            -18.5
        )
        XCTAssertEqual(
            NotchLayout.resolvedNotchWidth(
                hasSafeArea: false,
                measuredWidth: nil
            ),
            168
        )
        XCTAssertEqual(
            NotchLayout.resolvedNotchWidth(
                hasSafeArea: true,
                measuredWidth: .nan
            ),
            186
        )
        XCTAssertEqual(
            NotchLayout.resolvedNotchWidth(
                hasSafeArea: true,
                measuredWidth: 220
            ),
            220
        )
    }
}
