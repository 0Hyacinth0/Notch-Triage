import Foundation
import SwiftUI

extension AppModel {
    var isExpanded: Bool { panelState.isExpanded }
    var isPanelClosing: Bool { panelState.isPanelClosing }
    var isNotchCanvasExpanded: Bool { panelState.isNotchCanvasExpanded }
    var isHoveringNotch: Bool { panelState.isHoveringNotch }
    var systemHUD: SystemHUDSnapshot? { panelState.systemHUD }

    func sendPanelEvent(_ event: PanelEvent) {
        var nextState = panelState
        let effects = nextState.reduce(event)
        if nextState != panelState {
            replacePanelState(nextState)
        }
        performPanelEffects(effects)
    }

    private func performPanelEffects(_ effects: [PanelEffect]) {
        for effect in effects {
            switch effect {
            case .cancelHoverCollapse:
                hoverCollapseTask?.cancel()
                hoverCollapseTask = nil

            case .scheduleHoverCollapse(let revision, let delayMilliseconds):
                hoverCollapseTask?.cancel()
                hoverCollapseTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(
                        for: .milliseconds(delayMilliseconds)
                    )
                    guard !Task.isCancelled, let self else { return }
                    withAnimation(
                        self.motion(NotchDesign.Motion.hover),
                        completionCriteria: .logicallyComplete
                    ) {
                        self.sendPanelEvent(
                            .hoverCollapseDelayElapsed(revision: revision)
                        )
                    } completion: { [weak self] in
                        self?.sendPanelEvent(
                            .hoverCollapseAnimationCompleted(revision: revision)
                        )
                    }
                }

            case .cancelWorkspaceClose:
                panelCloseTask?.cancel()
                panelCloseTask = nil

            case .scheduleWorkspaceClose(
                let revision,
                let surfaceDelayMilliseconds,
                let canvasDelayMilliseconds
            ):
                panelCloseTask?.cancel()
                panelCloseTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(
                        for: .milliseconds(surfaceDelayMilliseconds)
                    )
                    guard !Task.isCancelled, let self else { return }
                    withAnimation(self.motion(NotchDesign.Motion.panelClose)) {
                        self.sendPanelEvent(
                            .workspaceSurfaceCloseDelayElapsed(revision: revision)
                        )
                    }

                    try? await Task.sleep(
                        for: .milliseconds(canvasDelayMilliseconds)
                    )
                    guard !Task.isCancelled else { return }
                    self.sendPanelEvent(
                        .workspaceCanvasCloseDelayElapsed(revision: revision)
                    )
                }

            case .cancelHUDDismiss:
                systemHUDDismissTask?.cancel()
                systemHUDDismissTask = nil

            case .scheduleHUDDismiss(let revision, let delayMilliseconds):
                systemHUDDismissTask?.cancel()
                systemHUDDismissTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(
                        for: .milliseconds(delayMilliseconds)
                    )
                    guard !Task.isCancelled, let self else { return }
                    withAnimation(
                        self.motion(NotchDesign.Motion.panelClose),
                        completionCriteria: .logicallyComplete
                    ) {
                        self.sendPanelEvent(
                            .hudDismissDelayElapsed(revision: revision)
                        )
                    } completion: { [weak self] in
                        self?.sendPanelEvent(
                            .hudDismissAnimationCompleted(revision: revision)
                        )
                    }
                }

            case .cancelUpdatePromptPresentation:
                updatePromptPresentationTask?.cancel()
                updatePromptPresentationTask = nil

            case .scheduleUpdatePromptPresentation(
                let revision,
                let releaseVersion,
                let delayMilliseconds
            ):
                updatePromptPresentationTask?.cancel()
                updatePromptPresentationTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(
                        for: .milliseconds(delayMilliseconds)
                    )
                    guard !Task.isCancelled,
                          let self,
                          self.panelState.effectRevisions.update == revision,
                          self.panelState.mode == .workspace,
                          self.panelState.presentationOverride == nil,
                          self.availableUpdate?.version == releaseVersion,
                          let release = self.availableUpdate else { return }
                    self.presentUpdatePrompt(for: release)
                }
            }
        }
    }
}
