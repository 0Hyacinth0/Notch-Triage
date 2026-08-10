import Foundation

/// The single source of truth for the notch panel's presentation.
///
/// Business data such as media, notifications, and power snapshots remains
/// outside this type. This state only owns presentation, temporary geometry
/// holds, and the revisions used to reject stale asynchronous completions.
struct PanelState: Equatable {
    enum Mode: Equatable {
        case compact
        case peek
        case workspace
        case closingWorkspace
    }

    enum PresentationOverride: Equatable {
        case fileDropTarget(
            sessionID: UUID,
            acceptance: FileDropAcceptance,
            returnMode: DropReturnMode
        )
        case releaseUpdatePrompt(id: UUID)
        case installingUpdate
    }

    enum DropReturnMode: Equatable {
        case compact
        case peek
        case workspace
    }

    struct EffectRevisions: Equatable {
        var hover: UInt64 = 0
        var close: UInt64 = 0
        var hud: UInt64 = 0
        var update: UInt64 = 0
    }

    var mode: Mode = .compact
    var presentationOverride: PresentationOverride?
    var systemHUD: SystemHUDSnapshot?
    var isPointerInside = false
    var isCanvasHeldOpen = false
    var effectRevisions = EffectRevisions()

    var isExpanded: Bool {
        mode == .workspace || mode == .closingWorkspace
    }

    var isPanelClosing: Bool {
        mode == .closingWorkspace
    }

    var usesExpandedNotchShape: Bool {
        mode == .workspace || mode == .closingWorkspace
    }

    var isHoveringNotch: Bool {
        mode == .peek
    }

    var isNotchCanvasExpanded: Bool {
        geometryPhase != .compact
    }

    var windowGeometryPhase: PanelGeometryPhase {
        geometryPhase
    }

    var geometryPhase: PanelGeometryPhase {
        switch mode {
        case .workspace, .closingWorkspace:
            return .workspace
        case .peek:
            return .peek
        case .compact:
            return isCanvasHeldOpen || systemHUD != nil ? .peek : .compact
        }
    }

    var blocksOrdinaryPanelInput: Bool {
        presentationOverride != nil
    }

    var isPresentingReleaseUpdatePrompt: Bool {
        if case .releaseUpdatePrompt = presentationOverride {
            return true
        }
        return false
    }

    var fileDropTarget: (
        sessionID: UUID,
        acceptance: FileDropAcceptance
    )? {
        guard case .fileDropTarget(
            let sessionID,
            let acceptance,
            _
        ) = presentationOverride else {
            return nil
        }
        return (sessionID, acceptance)
    }

    var isPresentingFileDropTarget: Bool {
        fileDropTarget != nil
    }

    var canShowNotificationPulse: Bool {
        mode == .compact
            && presentationOverride == nil
            && systemHUD == nil
            && !isCanvasHeldOpen
    }

    mutating func reduce(_ event: PanelEvent) -> [PanelEffect] {
        switch event {
        case .pointerEntered:
            isPointerInside = true
            guard presentationOverride == nil,
                  mode != .workspace,
                  mode != .closingWorkspace else {
                return []
            }
            effectRevisions.hover &+= 1
            mode = .peek
            isCanvasHeldOpen = false
            return [.cancelHoverCollapse]

        case .pointerExited:
            isPointerInside = false
            guard presentationOverride == nil, mode == .peek else { return [] }
            effectRevisions.hover &+= 1
            let revision = effectRevisions.hover
            return [
                .cancelHoverCollapse,
                .scheduleHoverCollapse(revision: revision, delayMilliseconds: 130),
            ]

        case .hoverCollapseDelayElapsed(let revision):
            guard revision == effectRevisions.hover,
                  mode == .peek,
                  !isPointerInside else { return [] }
            mode = .compact
            isCanvasHeldOpen = true
            return []

        case .hoverCollapseAnimationCompleted(let revision):
            guard revision == effectRevisions.hover,
                  mode == .compact,
                  systemHUD == nil else { return [] }
            isCanvasHeldOpen = false
            return []

        case .workspaceOpened:
            guard presentationOverride == nil else { return [] }
            effectRevisions.hover &+= 1
            effectRevisions.close &+= 1
            effectRevisions.update &+= 1
            mode = .workspace
            isCanvasHeldOpen = false
            return [
                .cancelHoverCollapse,
                .cancelWorkspaceClose,
                .cancelUpdatePromptPresentation,
            ]

        case .automaticUpdateWorkspaceRequested(let releaseVersion):
            guard presentationOverride == nil else { return [] }
            effectRevisions.hover &+= 1
            effectRevisions.close &+= 1
            effectRevisions.update &+= 1
            let revision = effectRevisions.update
            mode = .workspace
            isCanvasHeldOpen = false
            return [
                .cancelHoverCollapse,
                .cancelWorkspaceClose,
                .cancelUpdatePromptPresentation,
                .scheduleUpdatePromptPresentation(
                    revision: revision,
                    releaseVersion: releaseVersion,
                    delayMilliseconds: 240
                ),
            ]

        case .workspaceCloseRequested:
            guard presentationOverride == nil, mode == .workspace else { return [] }
            effectRevisions.hover &+= 1
            effectRevisions.close &+= 1
            effectRevisions.update &+= 1
            let revision = effectRevisions.close
            mode = .closingWorkspace
            isCanvasHeldOpen = false
            return [
                .cancelHoverCollapse,
                .cancelWorkspaceClose,
                .cancelUpdatePromptPresentation,
                .scheduleWorkspaceClose(
                    revision: revision,
                    surfaceDelayMilliseconds: 340,
                    canvasDelayMilliseconds: 320
                ),
            ]

        case .workspaceSurfaceCloseDelayElapsed(let revision):
            guard revision == effectRevisions.close,
                  mode == .closingWorkspace else { return [] }
            mode = .compact
            isPointerInside = false
            isCanvasHeldOpen = true
            return []

        case .workspaceCanvasCloseDelayElapsed(let revision):
            guard revision == effectRevisions.close,
                  mode == .compact,
                  presentationOverride == nil,
                  systemHUD == nil else { return [] }
            isCanvasHeldOpen = false
            return []

        case .hudReceived(let snapshot):
            guard presentationOverride == nil,
                  mode != .closingWorkspace else { return [] }
            effectRevisions.hud &+= 1
            let revision = effectRevisions.hud
            systemHUD = snapshot
            if mode == .compact {
                isCanvasHeldOpen = false
            }
            let visibility = snapshot.kind == .airPods ? 2_600 : 1_650
            return [
                .cancelHUDDismiss,
                .scheduleHUDDismiss(
                    revision: revision,
                    delayMilliseconds: visibility
                ),
            ]

        case .hudDismissDelayElapsed(let revision):
            guard revision == effectRevisions.hud,
                  systemHUD != nil else { return [] }
            systemHUD = nil
            if mode == .compact {
                isCanvasHeldOpen = true
            }
            return []

        case .hudDismissAnimationCompleted(let revision):
            guard revision == effectRevisions.hud,
                  mode == .compact,
                  systemHUD == nil else { return [] }
            isCanvasHeldOpen = false
            return []

        case .fileDragEntered(let sessionID, let acceptance):
            switch presentationOverride {
            case .installingUpdate, .releaseUpdatePrompt:
                return []
            case .fileDropTarget(
                let currentSessionID,
                _,
                let returnMode
            ) where currentSessionID == sessionID:
                presentationOverride = .fileDropTarget(
                    sessionID: sessionID,
                    acceptance: acceptance,
                    returnMode: returnMode
                )
                return []
            case .fileDropTarget, nil:
                break
            }

            let returnMode: DropReturnMode
            switch mode {
            case .workspace:
                returnMode = .workspace
            case .peek:
                returnMode = .peek
            case .compact, .closingWorkspace:
                returnMode = .compact
            }
            effectRevisions.hover &+= 1
            effectRevisions.close &+= 1
            effectRevisions.hud &+= 1
            effectRevisions.update &+= 1
            switch returnMode {
            case .workspace: mode = .workspace
            case .peek: mode = .peek
            case .compact: mode = .compact
            }
            presentationOverride = .fileDropTarget(
                sessionID: sessionID,
                acceptance: acceptance,
                returnMode: returnMode
            )
            systemHUD = nil
            isCanvasHeldOpen = returnMode == .compact
            return [
                .cancelHoverCollapse,
                .cancelWorkspaceClose,
                .cancelHUDDismiss,
                .cancelUpdatePromptPresentation,
            ]

        case .fileDragExited(let sessionID):
            guard case .fileDropTarget(
                sessionID,
                _,
                let returnMode
            ) = presentationOverride else {
                return []
            }
            presentationOverride = nil
            switch returnMode {
            case .workspace: mode = .workspace
            case .peek: mode = .peek
            case .compact: mode = .compact
            }
            isCanvasHeldOpen = false
            return []

        case .fileDropSucceeded(let sessionID):
            guard case .fileDropTarget(
                sessionID,
                _,
                _
            ) = presentationOverride else {
                return []
            }
            presentationOverride = nil
            mode = .workspace
            isCanvasHeldOpen = false
            return []

        case .releaseUpdatePromptPresented(let id):
            guard presentationOverride != .installingUpdate else { return [] }
            if case .releaseUpdatePrompt = presentationOverride {
                return []
            }
            effectRevisions.hover &+= 1
            effectRevisions.close &+= 1
            effectRevisions.hud &+= 1
            effectRevisions.update &+= 1
            mode = .workspace
            presentationOverride = .releaseUpdatePrompt(id: id)
            systemHUD = nil
            isCanvasHeldOpen = false
            return [
                .cancelHoverCollapse,
                .cancelWorkspaceClose,
                .cancelHUDDismiss,
                .cancelUpdatePromptPresentation,
            ]

        case .releaseUpdatePromptDismissed(let id):
            guard presentationOverride == .releaseUpdatePrompt(id: id) else {
                return []
            }
            effectRevisions.update &+= 1
            presentationOverride = nil
            return [.cancelUpdatePromptPresentation]

        case .installStarted:
            guard presentationOverride != .installingUpdate else { return [] }
            effectRevisions.hover &+= 1
            effectRevisions.close &+= 1
            effectRevisions.hud &+= 1
            effectRevisions.update &+= 1
            mode = .workspace
            presentationOverride = .installingUpdate
            systemHUD = nil
            isCanvasHeldOpen = false
            return [
                .cancelHoverCollapse,
                .cancelWorkspaceClose,
                .cancelHUDDismiss,
                .cancelUpdatePromptPresentation,
            ]

        case .installFinished:
            guard presentationOverride == .installingUpdate else { return [] }
            effectRevisions.update &+= 1
            presentationOverride = nil
            return [.cancelUpdatePromptPresentation]

        case .activitySuspended:
            effectRevisions.hud &+= 1
            systemHUD = nil
            if case .fileDropTarget(_, _, let returnMode) = presentationOverride {
                presentationOverride = nil
                switch returnMode {
                case .workspace: mode = .workspace
                case .peek:
                    // A suspended session has no meaningful pointer hover to
                    // restore, so release the Peek canvas while locked/asleep.
                    mode = .compact
                case .compact: mode = .compact
                }
            }
            if mode == .compact {
                isCanvasHeldOpen = false
            }
            return [.cancelHUDDismiss]

        case .activityResumed:
            return []

        case .reset:
            effectRevisions.hover &+= 1
            effectRevisions.close &+= 1
            effectRevisions.hud &+= 1
            effectRevisions.update &+= 1
            mode = .compact
            presentationOverride = nil
            systemHUD = nil
            isPointerInside = false
            isCanvasHeldOpen = false
            return [
                .cancelHoverCollapse,
                .cancelWorkspaceClose,
                .cancelHUDDismiss,
                .cancelUpdatePromptPresentation,
            ]
        }
    }
}

enum PanelEvent: Equatable {
    case pointerEntered
    case pointerExited
    case hoverCollapseDelayElapsed(revision: UInt64)
    case hoverCollapseAnimationCompleted(revision: UInt64)
    case workspaceOpened
    case automaticUpdateWorkspaceRequested(releaseVersion: String)
    case workspaceCloseRequested
    case workspaceSurfaceCloseDelayElapsed(revision: UInt64)
    case workspaceCanvasCloseDelayElapsed(revision: UInt64)
    case hudReceived(SystemHUDSnapshot)
    case hudDismissDelayElapsed(revision: UInt64)
    case hudDismissAnimationCompleted(revision: UInt64)
    case fileDragEntered(sessionID: UUID, acceptance: FileDropAcceptance)
    case fileDragExited(sessionID: UUID)
    case fileDropSucceeded(sessionID: UUID)
    case releaseUpdatePromptPresented(id: UUID)
    case releaseUpdatePromptDismissed(id: UUID)
    case installStarted
    case installFinished
    case activitySuspended
    case activityResumed
    case reset
}

enum PanelEffect: Equatable {
    case cancelHoverCollapse
    case scheduleHoverCollapse(revision: UInt64, delayMilliseconds: Int)
    case cancelWorkspaceClose
    case scheduleWorkspaceClose(
        revision: UInt64,
        surfaceDelayMilliseconds: Int,
        canvasDelayMilliseconds: Int
    )
    case cancelHUDDismiss
    case scheduleHUDDismiss(revision: UInt64, delayMilliseconds: Int)
    case cancelUpdatePromptPresentation
    case scheduleUpdatePromptPresentation(
        revision: UInt64,
        releaseVersion: String,
        delayMilliseconds: Int
    )
}
