import Darwin
import Foundation
import IOKit
import ObjectiveC.runtime

@MainActor
final class PowerMonitorService {
    private let onSnapshot: (PowerSnapshot, ChargeLimitSnapshot) -> Void
    private let onHealth: (ServiceHealth) -> Void
    private let chargeController = SystemChargeLimitController()

    init(
        onSnapshot: @escaping (PowerSnapshot, ChargeLimitSnapshot) -> Void,
        onHealth: @escaping (ServiceHealth) -> Void
    ) {
        self.onSnapshot = onSnapshot
        self.onHealth = onHealth
    }

    func start() {
        refresh()
    }

    func stop() {}

    func refresh() {
        let snapshot = PowerSnapshotReader.read()
        let chargeLimit = chargeController.status()
        onSnapshot(snapshot, chargeLimit)

        if chargeLimit.isSupported {
            onHealth(.ready("系统原生限充与电源遥测均可用"))
        } else {
            onHealth(.warning("电源监控可用；本机系统未提供手动限充"))
        }
    }

    func setChargeLimit(_ limit: Int) {
        onHealth(.loading("正在设置充电上限"))
        let result = chargeController.setLimit(limit)
        onHealth(result.success ? .ready(result.message) : .failed(result.message))
        refresh()
    }

    func temporarilyFillToFull() {
        onHealth(.loading("正在允许临时充满"))
        let result = chargeController.temporarilyFillToFull()
        onHealth(result.success ? .ready(result.message) : .failed(result.message))
        refresh()
    }

    func resumeChargeLimit() {
        onHealth(.loading("正在恢复充电限制"))
        let configuredLimit = chargeController.status().configuredLimit
        let result = chargeController.setLimit(configuredLimit)
        onHealth(result.success ? .ready(result.message) : .failed(result.message))
        refresh()
    }
}

private enum PowerSnapshotReader {
    static func read() -> PowerSnapshot {
        let battery = properties(for: "AppleSmartBattery")
        let pack = properties(for: "AppleSmartBatteryPack")
        let packData = dictionary(pack["BatteryData"])
        let batteryData = dictionary(battery["BatteryData"])
        let telemetry = dictionary(battery["PowerTelemetryData"])
        let distribution = dictionary(battery["PowerDistribution"])
        let adapterDetails = dictionary(battery["AdapterDetails"])

        let batteryPercent = int(battery["CurrentCapacity"])
            ?? int(packData["CurrentCapacity"])
            ?? 0
        let isCharging = bool(battery["IsCharging"])
        let fullyCharged = bool(battery["FullyCharged"])
        let externalConnected = bool(battery["ExternalConnected"])

        let designCapacity = int(packData["DesignCapacity"])
            ?? int(batteryData["DesignCapacity"])
        let hardwareMaximum = int(packData["NominalChargeCapacity"])
            ?? int(batteryData["NominalChargeCapacity"])
        let macOSMaximum = int(packData["AppleRawMaxCapacity"])
            ?? int(batteryData["FullChargeCapacity"])
        let currentCapacity = int(packData["AppleRawCurrentCapacity"])
            ?? int(batteryData["RemainingCapacity"])

        let currentAmps = signedDouble(battery["InstantAmperage"])
            .map { $0 / 1_000 }
        let voltageVolts = double(battery["Voltage"])
            .map { $0 / 1_000 }
        let calculatedBatteryPower = currentAmps.flatMap { current in
            voltageVolts.map { current * $0 }
        }
        let telemetryBatteryPower = double(telemetry["BatteryPower"])
            .map { $0 / 1_000 }
        let batteryPower = calculatedBatteryPower ?? telemetryBatteryPower
        let systemLoad = double(telemetry["SystemLoad"])
            .map { $0 / 1_000 }

        let adapterCurrent = double(adapterDetails["Current"])
            .map { $0 / 1_000 }
        let adapterVoltage = double(adapterDetails["AdapterVoltage"])
            .map { $0 / 1_000 }
        let negotiatedPower = adapterCurrent.flatMap { current in
            adapterVoltage.map { current * $0 }
        } ?? double(distribution["IPDInputPower"]).map { $0 / 1_000 }
        let ratedPower = double(adapterDetails["Watts"])
        let adapterInputPower: Double?
        if externalConnected {
            if let systemLoad {
                adapterInputPower = systemLoad + max(0, batteryPower ?? 0)
            } else {
                adapterInputPower = negotiatedPower
            }
        } else {
            adapterInputPower = nil
        }

        let adapter = AdapterSnapshot(
            isConnected: externalConnected,
            currentAmps: adapterCurrent,
            voltageVolts: adapterVoltage,
            negotiatedWatts: negotiatedPower,
            ratedWatts: ratedPower,
            name: adapterName(details: adapterDetails, ratedPower: ratedPower),
            manufacturer: string(adapterDetails["Manufacturer"]) ?? "系统未公开",
            serialNumber: string(adapterDetails["SerialNumber"])
                ?? string(adapterDetails["Serial"])
        )

        let permanentFailure = int(packData["PermanentFailureStatus"]) ?? 0
        let timeToFull = validMinutes(
            int(battery["AvgTimeToFull"])
                ?? int(battery["TimeRemaining"])
        )
        let reportedTimeToEmpty = validMinutes(
            int(battery["AvgTimeToEmpty"])
                ?? int(battery["TimeRemaining"])
        )
        let calculatedTimeToEmpty: Int?
        if let currentCapacity,
           let currentAmps,
           currentAmps < -0.05 {
            calculatedTimeToEmpty = validMinutes(
                Int(
                    (
                        Double(currentCapacity)
                            / (abs(currentAmps) * 1_000)
                            * 60
                    ).rounded()
                )
            )
        } else {
            calculatedTimeToEmpty = nil
        }

        return PowerSnapshot(
            batteryPercent: batteryPercent,
            isCharging: isCharging,
            isFullyCharged: fullyCharged,
            isExternalPowerConnected: externalConnected,
            designCapacityMAh: designCapacity,
            hardwareMaximumCapacityMAh: hardwareMaximum,
            macOSMaximumCapacityMAh: macOSMaximum,
            currentCapacityMAh: currentCapacity,
            cycleCount: int(battery["CycleCount"])
                ?? int(packData["CycleCount"]),
            healthStatus: healthStatus(
                battery: battery,
                permanentFailure: permanentFailure
            ),
            temperatureCelsius: temperature(packData["Temperature"]),
            timeToFullMinutes: isCharging ? timeToFull : nil,
            timeToEmptyMinutes: !externalConnected && !isCharging
                ? (reportedTimeToEmpty ?? calculatedTimeToEmpty)
                : nil,
            serialNumber: string(battery["Serial"])
                ?? string(packData["Serial"]),
            batteryCurrentAmps: currentAmps,
            batteryVoltageVolts: voltageVolts,
            batteryPowerWatts: batteryPower,
            systemLoadWatts: systemLoad,
            adapterInputWatts: adapterInputPower,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            adapter: adapter,
            updatedAt: Date()
        )
    }

    private static func properties(for serviceClass: String) -> [String: Any] {
        guard let matching = IOServiceMatching(serviceClass) else { return [:] }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }

        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(
            service,
            &unmanagedProperties,
            kCFAllocatorDefault,
            0
        )
        guard result == KERN_SUCCESS,
              let properties = unmanagedProperties?.takeRetainedValue() else {
            return [:]
        }
        return properties as NSDictionary as? [String: Any] ?? [:]
    }

    private static func dictionary(_ value: Any?) -> [String: Any] {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        if let dictionary = value as? NSDictionary {
            return dictionary as? [String: Any] ?? [:]
        }
        return [:]
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func signedDouble(_ value: Any?) -> Double? {
        (value as? NSNumber).map { Double($0.int64Value) }
    }

    private static func bool(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func temperature(_ value: Any?) -> Double? {
        guard let raw = double(value) else { return nil }
        if raw > 1_000 { return raw / 100 }
        if raw > 200 { return raw / 10 - 273.15 }
        return raw
    }

    private static func validMinutes(_ value: Int?) -> Int? {
        guard let value, value > 0, value < 65_535 else { return nil }
        return value
    }

    private static func adapterName(
        details: [String: Any],
        ratedPower: Double?
    ) -> String {
        if let name = string(details["Name"]), !name.isEmpty {
            return name
        }
        if let description = string(details["Description"]),
           !description.isEmpty,
           description.lowercased() != "pd charger" {
            return description
        }
        if let ratedPower {
            return "\(Int(ratedPower.rounded()))W USB-C Power Adapter"
        }
        return "USB-C Power Adapter"
    }

    private static func healthStatus(
        battery: [String: Any],
        permanentFailure: Int
    ) -> String {
        if let health = string(battery["BatteryHealth"]), !health.isEmpty {
            return health
        }
        return permanentFailure == 0 ? "Normal" : "建议维修"
    }
}

private struct ChargeControlResult {
    let success: Bool
    let message: String
}

private final class SystemChargeLimitController {
    private let frameworkHandle: UnsafeMutableRawPointer?
    private let clientClass: AnyClass?
    private let client: AnyObject?

    init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI",
            RTLD_NOW
        )
        frameworkHandle = handle

        guard handle != nil,
              let cls: AnyClass = NSClassFromString("PowerUISmartChargeClient"),
              let rawValue = class_createInstance(cls, 0),
              let method = class_getInstanceMethod(
                cls,
                NSSelectorFromString("initWithClientName:")
              ) else {
            clientClass = nil
            client = nil
            return
        }

        typealias Initialize = @convention(c) (
            AnyObject,
            Selector,
            NSString
        ) -> AnyObject
        let initialize = unsafeBitCast(
            method_getImplementation(method),
            to: Initialize.self
        )
        let selector = NSSelectorFromString("initWithClientName:")
        clientClass = cls
        client = initialize(rawValue as AnyObject, selector, "Notch Triage")
    }

    func status() -> ChargeLimitSnapshot {
        guard callBoolean("isMCLSupported") == true else {
            return .unavailable
        }

        let available = (callObject("availableChargeLimitsWithError:") as? [NSNumber])?
            .map(\.intValue)
            .sorted()
            ?? [80, 85, 90, 95, 100]
        let enabled = callUnsigned("isMCLCurrentlyEnabled:") == 1
        let configured = Int(callUnsigned("getMCLLimitWithError:") ?? 100)
        let effective = Int(callUnsigned("currentChargeLimit:") ?? UInt64(configured))

        return ChargeLimitSnapshot(
            isSupported: true,
            isEnabled: enabled,
            configuredLimit: configured,
            effectiveLimit: effective,
            availableLimits: available
        )
    }

    func setLimit(_ limit: Int) -> ChargeControlResult {
        let state = status()
        guard state.isSupported else {
            return .init(success: false, message: "本机系统不支持手动充电上限")
        }
        guard state.availableLimits.contains(limit),
              let byteLimit = UInt8(exactly: limit) else {
            return .init(success: false, message: "系统不接受 \(limit)% 充电上限")
        }

        let setResult = callBooleanWithByteAndError(
            "setMCLLimit:error:",
            value: byteLimit
        )
        guard setResult.success else {
            return .init(
                success: false,
                message: setResult.error ?? "设置充电上限失败"
            )
        }

        let enableResult = callBooleanWithError("enableMCL:")
        guard enableResult.success else {
            return .init(
                success: false,
                message: enableResult.error ?? "启用充电上限失败"
            )
        }
        return .init(success: true, message: "充电上限已设为 \(limit)%")
    }

    func temporarilyFillToFull() -> ChargeControlResult {
        guard status().isSupported else {
            return .init(success: false, message: "本机系统不支持临时充满")
        }
        let result = callBooleanWithError("temporarilyDisableMCL:")
        return .init(
            success: result.success,
            message: result.success
                ? "已临时允许充满至 100%"
                : (result.error ?? "无法临时充满")
        )
    }

    private func method(named name: String) -> Method? {
        guard let clientClass else { return nil }
        return class_getInstanceMethod(clientClass, NSSelectorFromString(name))
    }

    private func callBoolean(_ name: String) -> Bool? {
        guard let client, let method = method(named: name) else { return nil }
        typealias Function = @convention(c) (AnyObject, Selector) -> Bool
        let function = unsafeBitCast(
            method_getImplementation(method),
            to: Function.self
        )
        return function(client, NSSelectorFromString(name))
    }

    private func callUnsigned(_ name: String) -> UInt64? {
        guard let client, let method = method(named: name) else { return nil }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            UnsafeMutablePointer<AnyObject?>?
        ) -> UInt64
        let function = unsafeBitCast(
            method_getImplementation(method),
            to: Function.self
        )
        var error: AnyObject?
        let value = function(client, NSSelectorFromString(name), &error)
        return error == nil ? value : nil
    }

    private func callObject(_ name: String) -> AnyObject? {
        guard let client, let method = method(named: name) else { return nil }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            UnsafeMutablePointer<AnyObject?>?
        ) -> Unmanaged<AnyObject>?
        let function = unsafeBitCast(
            method_getImplementation(method),
            to: Function.self
        )
        var error: AnyObject?
        let value = function(client, NSSelectorFromString(name), &error)
        guard error == nil else { return nil }
        return value?.takeUnretainedValue()
    }

    private func callBooleanWithError(
        _ name: String
    ) -> (success: Bool, error: String?) {
        guard let client, let method = method(named: name) else {
            return (false, "系统限充接口不可用")
        }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            UnsafeMutablePointer<AnyObject?>?
        ) -> Bool
        let function = unsafeBitCast(
            method_getImplementation(method),
            to: Function.self
        )
        var error: AnyObject?
        let success = function(client, NSSelectorFromString(name), &error)
        return (success, errorMessage(error))
    }

    private func callBooleanWithByteAndError(
        _ name: String,
        value: UInt8
    ) -> (success: Bool, error: String?) {
        guard let client, let method = method(named: name) else {
            return (false, "系统限充接口不可用")
        }
        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            UInt8,
            UnsafeMutablePointer<AnyObject?>?
        ) -> Bool
        let function = unsafeBitCast(
            method_getImplementation(method),
            to: Function.self
        )
        var error: AnyObject?
        let success = function(
            client,
            NSSelectorFromString(name),
            value,
            &error
        )
        return (success, errorMessage(error))
    }

    private func errorMessage(_ error: AnyObject?) -> String? {
        (error as? NSError)?.localizedDescription
            ?? error.map { String(describing: $0) }
    }
}
