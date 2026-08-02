import SwiftUI

struct SystemHUDContent: View {
    let snapshot: SystemHUDSnapshot
    let menuBarHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentVisible = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: menuBarHeight)

            Group {
                if snapshot.kind == .airPods {
                    airPodsContent
                } else {
                    levelContent
                }
            }
            .padding(.horizontal, 24)
            .frame(maxHeight: .infinity)
            .opacity(contentVisible ? 1 : 0)
            .offset(y: reduceMotion || contentVisible ? 0 : -3)
        }
        .foregroundStyle(.white)
        .onAppear {
            withAnimation(reduceMotion ? .linear(duration: 0.12) : NotchDesign.Motion.panelOpen) {
                contentVisible = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.title)，\(snapshot.subtitle)")
    }

    private var levelContent: some View {
        HStack(spacing: 12) {
            systemIcon

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(snapshot.title)
                        .font(.system(size: 10.5, weight: .bold))
                    Spacer(minLength: 8)
                    Text(snapshot.subtitle)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                AnimatedLevelBar(
                    value: snapshot.value ?? 0,
                    gradient: levelGradient
                )
                .frame(height: 4.5)
            }
        }
    }

    private var airPodsContent: some View {
        HStack(spacing: 11) {
            systemIcon

            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(snapshot.subtitle)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer(minLength: 8)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var systemIcon: some View {
        switch snapshot.kind {
        case .volume:
            Image(systemName: snapshot.symbol)
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(systemIconColor)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(
                    .wiggle.forward.byLayer,
                    options: .nonRepeating.speed(1.18),
                    value: snapshot.subtitle
                )
                .frame(width: 22, height: 27)

        case .brightness:
            Image(systemName: snapshot.symbol)
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(systemIconColor)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(
                    .breathe.pulse.byLayer,
                    options: .nonRepeating.speed(1.15),
                    value: snapshot.subtitle
                )
                .frame(width: 22, height: 27)

        case .airPods:
            Image(systemName: snapshot.symbol)
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(systemIconColor)
                .symbolEffect(
                    .breathe.pulse.byLayer,
                    options: .nonRepeating.speed(1.05),
                    value: snapshot.id
                )
                .frame(width: 22, height: 27)
        }
    }

    private var levelGradient: LinearGradient {
        switch snapshot.kind {
        case .volume:
            return LinearGradient(
                colors: [
                    Color(red: 0.30, green: 0.48, blue: 1.00),
                    Color(red: 0.20, green: 0.82, blue: 1.00)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .brightness:
            return LinearGradient(
                colors: [
                    Color(red: 1.00, green: 0.48, blue: 0.08),
                    Color(red: 1.00, green: 0.87, blue: 0.18)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .airPods:
            return LinearGradient(
                colors: [.cyan, .mint],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private var systemIconColor: Color {
        snapshot.kind == .airPods ? .cyan : .white.opacity(0.94)
    }
}

private struct AnimatedLevelBar: View {
    let value: Double
    let gradient: LinearGradient
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedValue = 0.0

    private var normalizedValue: Double {
        max(0, min(1, value))
    }

    var body: some View {
        GeometryReader { proxy in
            let filledWidth = displayedValue > 0
                ? max(proxy.size.height, proxy.size.width * displayedValue)
                : 0

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.14))

                Capsule(style: .continuous)
                    .fill(gradient)
                    .frame(width: filledWidth)
            }
        }
        .onAppear {
            displayedValue = reduceMotion ? normalizedValue : 0
            withAnimation(reduceMotion ? .linear(duration: 0.01) : NotchDesign.Motion.panelOpen) {
                displayedValue = normalizedValue
            }
        }
        .onChange(of: value) { _, _ in
            withAnimation(reduceMotion ? .linear(duration: 0.01) : NotchDesign.Motion.value) {
                displayedValue = normalizedValue
            }
        }
    }
}
