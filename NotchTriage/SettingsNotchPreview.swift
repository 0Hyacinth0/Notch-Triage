import SwiftUI

/// Uses the same silhouette, slot widths, ring sizes and center indicator as
/// LivingNotch. Keep the physical notch centered as either wing changes.
struct SettingsNotchPreview<LeftWing: View, RightWing: View>: View {
    let notchWidth: CGFloat
    let height: CGFloat
    let leftWingWidth: CGFloat
    let rightWingWidth: CGFloat
    var concealedSide: NotchWingSide?
    @ViewBuilder var leftWing: () -> LeftWing
    @ViewBuilder var rightWing: () -> RightWing

    var body: some View {
        NotchSilhouette(
            shoulderRadius: NotchLayout.shoulderRadius,
            bottomCornerRadius: 12
        )
        .fill(.black)
        .frame(
            width: NotchLayout.compactSurfaceWidth(
                leftWingWidth: leftWingWidth,
                notchWidth: notchWidth,
                rightWingWidth: rightWingWidth
            ),
            height: height
        )
        .overlay {
            HStack(spacing: 0) {
                leftWing()
                    .frame(width: leftWingWidth, height: height)
                    .opacity(concealedSide == .left ? 0 : 1)

                Capsule()
                    .fill(.white.opacity(0.12))
                    .frame(width: 22, height: 2)
                    .padding(.top, max(0, height - 9))
                    .frame(width: notchWidth, height: height, alignment: .top)

                rightWing()
                    .frame(width: rightWingWidth, height: height)
                    .opacity(concealedSide == .right ? 0 : 1)
            }
        }
        .offset(x: NotchLayout.compactSurfaceHorizontalOffset(
            leftWingWidth: leftWingWidth,
            rightWingWidth: rightWingWidth
        ))
    }
}

enum CompactPreviewSamples {
    static let media = MediaSnapshot(
        sourceName: "Music",
        bundleIdentifier: nil,
        title: "",
        artist: "",
        duration: 240,
        elapsed: 180,
        isPlaying: true
    )

    static let power: PowerSnapshot = {
        var snapshot = PowerSnapshot.empty
        snapshot.batteryPercent = 86
        snapshot.isCharging = true
        snapshot.isExternalPowerConnected = true
        snapshot.adapterInputWatts = 32
        return snapshot
    }()
}

struct RingHoverExpansionPreview: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = Phase.compact

    private enum Phase {
        case compact, media, battery
    }

    private var height: CGFloat { min(model.menuBarHeight, 40) }
    private var slotWidth: CGFloat { NotchLayout.compactWingSlotWidth }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("悬停效果预览")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            ZStack(alignment: .top) {
                SettingsNotchPreview(
                    notchWidth: model.notchWidth,
                    height: height,
                    leftWingWidth: slotWidth,
                    rightWingWidth: slotWidth,
                    concealedSide: phase == .media ? .left : (phase == .battery ? .right : nil)
                ) {
                    MediaProgressRing(
                        snapshot: CompactPreviewSamples.media,
                        style: model.ringAppearance.style(for: .media),
                        diameter: 22,
                        lineWidth: 3.2
                    )
                } rightWing: {
                    UsageArc(
                        progress: 0.86,
                        style: model.ringAppearance.style(for: .battery),
                        lineWidth: 3.2
                    )
                    .frame(width: 22, height: 22)
                }

                // A separate full-width canvas keeps the battery's adaptive
                // alignment guide from shifting the centered notch.
                ZStack(alignment: .top) {
                    Color.clear
                        .allowsHitTesting(false)

                    CompactMediaTransportSurface(
                        side: .left,
                        isRevealed: phase == .media,
                        reduceMotion: reduceMotion
                    ) { command in
                        CompactMediaTransportLabel(
                            snapshot: CompactPreviewSamples.media,
                            style: model.ringAppearance.style(for: .media),
                            command: command
                        )
                    }
                    .frame(width: NotchLayout.compactMediaControlsWidth, height: height)
                    .offset(x: -(model.notchWidth + NotchLayout.compactMediaControlsWidth) / 2)

                    CompactBatteryStatusReveal(
                        model: model,
                        snapshot: CompactPreviewSamples.power,
                        side: .right,
                        isRevealed: phase == .battery,
                        reduceMotion: reduceMotion,
                        style: model.ringAppearance.style(for: .battery)
                    )
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(height: height)
                    .alignmentGuide(HorizontalAlignment.center) { _ in
                        -model.notchWidth / 2
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                Image(systemName: "cursorarrow")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 1, y: 1)
                    .offset(
                        x: (phase == .media ? -1 : 1) * (model.notchWidth + slotWidth) / 2 + 6,
                        y: height / 2 + 4
                    )
                    .opacity(phase == .compact ? 0 : 1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height + 14, alignment: .top)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("正在播放与电池圆环横向展开效果预览")

            Text("演示布局：左侧正在播放，右侧电池。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .task(id: [model.compactRingHoverExpansionEnabled, reduceMotion]) {
            phase = .compact
            guard model.compactRingHoverExpansionEnabled else { return }
            guard !reduceMotion else {
                phase = .media
                return
            }
            let stages: [(Phase, Duration)] = [
                (.compact, .milliseconds(900)),
                (.media, .milliseconds(1_800)),
                (.compact, .milliseconds(700)),
                (.battery, .milliseconds(1_800))
            ]
            while !Task.isCancelled {
                for (next, duration) in stages {
                    withAnimation(NotchDesign.Motion.hover) { phase = next }
                    do {
                        try await Task.sleep(for: duration)
                    } catch {
                        return
                    }
                }
            }
        }
    }
}
