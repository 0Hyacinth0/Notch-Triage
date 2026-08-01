import SwiftUI

struct PowerDashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: NotchDesign.Spacing.group) {
                PowerOverviewGroup(model: model)
                BatteryDetailsCard(snapshot: model.power)
                AdapterDetailsCard(snapshot: model.power)
            }
        }
        .scrollIndicators(.automatic)
    }
}

private struct PowerOverviewGroup: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            ChargeLimitCard(model: model)

            Divider()
                .opacity(0.32)

            PowerFlowCard(snapshot: model.power)
        }
        .padding(14)
        .panelGroupSurface()
    }
}

private struct ChargeLimitCard: View {
    @ObservedObject var model: AppModel

    private var limitBinding: Binding<Int> {
        Binding(
            get: { model.chargeLimit.configuredLimit },
            set: { model.setChargeLimit($0) }
        )
    }

    var body: some View {
        VStack(spacing: 11) {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("充电管理", systemImage: "battery.100percent.bolt")
                        .font(.system(size: 12.5, weight: .semibold))

                    Text(controlSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                PowerStatusDot(health: model.powerHealth)

                if isTemporarilyFilling {
                    Button("恢复限制") {
                        model.resumeChargeLimit()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                } else {
                    Button {
                        model.temporarilyFillBattery()
                    } label: {
                        Label("充满", systemImage: "plus.circle")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(!model.chargeLimit.isSupported)
                    .help("临时允许充满至 100%")
                }

                Button {
                    model.refreshPower()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("刷新电源数据")
            }

            BatteryLimitBar(
                batteryPercent: model.power.batteryPercent,
                limitPercent: model.chargeLimit.configuredLimit,
                isCharging: model.power.isCharging,
                isConnected: model.power.isExternalPowerConnected
            )
            .frame(height: 22)

            HStack(spacing: 12) {
                Text("充电上限")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Picker("充电上限", selection: limitBinding) {
                    ForEach(model.chargeLimit.availableLimits, id: \.self) { limit in
                        Text("\(limit)").tag(limit)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 224)
                .disabled(!model.chargeLimit.isSupported)
            }
        }
    }

    private var controlSubtitle: String {
        guard model.chargeLimit.isSupported else {
            return "只读监控；系统限充不可用"
        }
        if isTemporarilyFilling {
            return "临时充满中，限制仍保留"
        }
        if model.chargeLimit.isEnabled {
            return model.power.isCharging ? "正在充电至上限" : "系统原生限制已启用"
        }
        return "手动限制尚未启用"
    }

    private var isTemporarilyFilling: Bool {
        model.power.isCharging && model.chargeLimit.isTemporarilyFilling
    }
}

private struct BatteryLimitBar: View {
    let batteryPercent: Int
    let limitPercent: Int
    let isCharging: Bool
    let isConnected: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.09))

                Capsule()
                    .fill(fillColor.opacity(0.82))
                    .frame(
                        width: proxy.size.width
                            * CGFloat(max(0, min(100, batteryPercent))) / 100
                    )
                    .animation(NotchDesign.Motion.value, value: batteryPercent)

                Rectangle()
                    .fill(.primary.opacity(0.58))
                    .frame(width: 1, height: 18)
                    .offset(
                        x: max(
                            0,
                            proxy.size.width
                                * CGFloat(max(0, min(100, limitPercent))) / 100 - 1
                        )
                    )

                HStack(spacing: 5) {
                    Image(systemName: stateSymbol)
                        .font(.system(size: 10, weight: .bold))
                    Text("\(batteryPercent)%")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer()
                    Text("上限 \(limitPercent)%")
                        .font(.system(size: 9.5, weight: .semibold))
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 10)
                .foregroundStyle(.primary.opacity(0.88))
            }
        }
    }

    private var fillColor: Color {
        if batteryPercent <= 20 { return .red }
        if batteryPercent >= limitPercent { return .green }
        return .mint
    }

    private var stateSymbol: String {
        if isCharging { return "bolt.fill" }
        if isConnected { return "powerplug.fill" }
        return "battery.75"
    }
}

private struct PowerFlowCard: View {
    let snapshot: PowerSnapshot

    private var batteryPower: Double {
        abs(snapshot.batteryPowerWatts ?? 0)
    }

    private var systemPower: Double {
        max(0, snapshot.systemLoadWatts ?? 0)
    }

    private var inputPower: Double {
        if snapshot.isExternalPowerConnected {
            return max(0, snapshot.adapterInputWatts ?? (batteryPower + systemPower))
        }
        return batteryPower
    }

    var body: some View {
        VStack(spacing: 11) {
            HStack(spacing: 7) {
                Image(systemName: "bolt.horizontal.fill")
                    .foregroundStyle(.secondary)
                Text("实时功率")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
            }

            HStack(spacing: 8) {
                FlowNode(
                    symbol: snapshot.isExternalPowerConnected
                        ? "powerplug.fill"
                        : "battery.75",
                    label: snapshot.isExternalPowerConnected ? "适配器" : "电池",
                    value: watts(inputPower > 0 ? inputPower : batteryPower),
                    tint: .green
                )

                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)

                FlowNode(
                    symbol: "laptopcomputer",
                    label: "系统",
                    value: watts(systemPower),
                    tint: .cyan
                )

                if snapshot.isExternalPowerConnected {
                    Image(systemName: snapshot.isCharging ? "plus" : "equal")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)

                    FlowNode(
                        symbol: batterySymbol,
                        label: batteryFlowLabel,
                        value: watts(batteryPower),
                        tint: snapshot.isCharging ? .green : .secondary
                    )
                }
            }

            GeometryReader { proxy in
                let total = max(1, systemPower + (snapshot.isCharging ? batteryPower : 0))
                let systemWidth = proxy.size.width * systemPower / total
                let batteryWidth = proxy.size.width - systemWidth

                HStack(spacing: 2) {
                    Capsule()
                        .fill(.cyan.gradient)
                        .frame(width: max(4, systemWidth - 1))
                    Capsule()
                        .fill((snapshot.isCharging ? Color.green : .secondary).gradient)
                        .frame(width: max(4, batteryWidth - 1))
                }
            }
            .frame(height: 6)
        }
    }

    private var batterySymbol: String {
        if snapshot.isCharging { return "battery.100.bolt" }
        if snapshot.isFullyCharged { return "battery.100" }
        return "battery.75"
    }

    private var batteryFlowLabel: String {
        if snapshot.isCharging { return "电池" }
        if snapshot.isFullyCharged { return "保持" }
        return "待机"
    }
}

private struct FlowNode: View {
    let symbol: String
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BatteryDetailsCard: View {
    let snapshot: PowerSnapshot

    var body: some View {
        MetricSection(title: "电池", symbol: "battery.100") {
            PowerMetricRow(
                symbol: "square.stack.3d.up",
                title: "设计容量",
                value: capacity(snapshot.designCapacityMAh),
                trailing: snapshot.designCapacityMAh == nil ? nil : "100%"
            )
            PowerMetricRow(
                symbol: "waveform.path.ecg",
                title: "硬件最大容量",
                value: capacity(snapshot.hardwareMaximumCapacityMAh),
                trailing: percent(snapshot.hardwareHealthPercent)
            )
            PowerMetricRow(
                symbol: "arrow.triangle.2.circlepath",
                title: "循环次数",
                value: integer(snapshot.cycleCount)
            )

            Divider().opacity(0.35)

            PowerMetricRow(
                symbol: "thermometer.medium",
                title: "电池温度",
                value: decimal(snapshot.temperatureCelsius, suffix: "°C", digits: 1)
            )
            if snapshot.isExternalPowerConnected {
                PowerMetricRow(
                    symbol: "clock",
                    title: "充满时间",
                    value: minutes(snapshot.timeToFullMinutes)
                )
            } else {
                PowerMetricRow(
                    symbol: "hourglass",
                    title: "预计可用时间",
                    value: minutes(snapshot.timeToEmptyMinutes)
                )
            }

            Divider().opacity(0.35)

            PowerMetricRow(
                symbol: "bolt.horizontal",
                title: "电池电流",
                value: decimal(snapshot.batteryCurrentAmps, suffix: " A", digits: 2)
            )
            PowerMetricRow(
                symbol: "v.square",
                title: "电池电压",
                value: decimal(snapshot.batteryVoltageVolts, suffix: " V", digits: 2)
            )
            PowerMetricRow(
                symbol: "w.square",
                title: "电池功率",
                value: decimal(snapshot.batteryPowerWatts.map(abs), suffix: " W", digits: 2)
            )
            PowerMetricRow(
                symbol: "laptopcomputer",
                title: "系统负载",
                value: decimal(snapshot.systemLoadWatts, suffix: " W", digits: 2)
            )
            PowerMetricRow(
                symbol: "battery.25",
                title: "低电量模式",
                value: snapshot.lowPowerModeEnabled ? "已开启" : "已关闭"
            )
        }
    }
}

private struct AdapterDetailsCard: View {
    let snapshot: PowerSnapshot

    var body: some View {
        MetricSection(title: "电源适配器", symbol: "powerplug.fill") {
            if snapshot.adapter.isConnected {
                PowerMetricRow(
                    symbol: "bolt.horizontal",
                    title: "协商电流",
                    value: decimal(snapshot.adapter.currentAmps, suffix: " A", digits: 2)
                )
                PowerMetricRow(
                    symbol: "v.square",
                    title: "协商电压",
                    value: decimal(snapshot.adapter.voltageVolts, suffix: " V", digits: 2)
                )
                PowerMetricRow(
                    symbol: "w.square",
                    title: "协商功率",
                    value: decimal(snapshot.adapter.negotiatedWatts, suffix: " W", digits: 2)
                )
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "powerplug")
                    Text("未连接电源适配器")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 36)
            }
        }
    }

}

private struct MetricSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
            }

            content
        }
        .padding(13)
        .panelGroupSurface()
    }
}

private struct PowerMetricRow: View {
    let symbol: String
    let title: String
    let value: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 15)

            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 10)

            Text(value)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())

            if let trailing {
                Text(trailing)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
                    .contentTransition(.numericText())
            }
        }
        .frame(minHeight: 18)
    }
}

private struct PowerStatusDot: View {
    let health: ServiceHealth

    var body: some View {
        Circle()
            .fill(Color(nsColor: health.color))
            .frame(width: 6, height: 6)
            .help(health.message)
    }
}

private func capacity(_ value: Int?) -> String {
    value.map { "\($0) mAh" } ?? "—"
}

private func integer(_ value: Int?) -> String {
    value.map(String.init) ?? "—"
}

private func percent(_ value: Int?) -> String? {
    value.map { "\($0)%" }
}

private func decimal(
    _ value: Double?,
    suffix: String,
    digits: Int
) -> String {
    guard let value, value.isFinite else { return "—" }
    return String(format: "%.*f%@", digits, value, suffix)
}

private func watts(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    return String(format: "%.1f W", value)
}

private func minutes(_ value: Int?) -> String {
    guard let value else { return "—" }
    if value >= 60 {
        return "\(value / 60) 小时 \(value % 60) 分"
    }
    return "\(value) 分"
}
