import AppKit
import CoreAudio
import CoreGraphics
import Darwin
import Foundation

@MainActor
final class SystemHUDService {
    typealias EventHandler = @MainActor (SystemHUDSnapshot) -> Void

    private typealias DisplayServicesGetBrightness = @convention(c) (
        CGDirectDisplayID,
        UnsafeMutablePointer<Float>
    ) -> Int32

    private let onEvent: EventHandler
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?
    private var outputListenerAddresses: [AudioObjectPropertyAddress] = []

    private var currentOutputDevice = AudioDeviceID(kAudioObjectUnknown)
    private var knownDevices = Set<AudioDeviceID>()
    private var lastVolume: Double?
    private var lastMuted: Bool?
    private var lastBrightness: Double?
    private var lastManualBrightnessEventUptime: TimeInterval?
    private var lastAirPodsEvent: (name: String, date: Date)?

    private var globalSystemKeyMonitor: Any?
    private var localSystemKeyMonitor: Any?
    private var brightnessObserver: NSObjectProtocol?
    private var displayServicesHandle: UnsafeMutableRawPointer?
    private var getDisplayBrightness: DisplayServicesGetBrightness?

    init(onEvent: @escaping EventHandler) {
        self.onEvent = onEvent
        loadDisplayServices()
    }

    func start() {
        if getDisplayBrightness == nil {
            loadDisplayServices()
        }
        stopAudioListeners()
        installSystemAudioListeners()
        knownDevices = Set(audioDevices())
        updateDefaultOutput(showConnection: false)

        lastBrightness = readBrightness()
        installBrightnessObservers()
    }

    func stop() {
        removeBrightnessObservers()
        stopAudioListeners()

        if let displayServicesHandle {
            dlclose(displayServicesHandle)
        }
        displayServicesHandle = nil
        getDisplayBrightness = nil
    }

    func refreshBrightness() {
        pollBrightness()
    }

    private func installBrightnessObservers() {
        removeBrightnessObservers()

        globalSystemKeyMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .systemDefined
        ) { [weak self] event in
            guard Self.isBrightnessKeyEvent(event) else { return }
            Task { @MainActor [weak self] in
                self?.handleManualBrightnessEvent()
            }
        }
        localSystemKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .systemDefined
        ) { [weak self] event in
            if Self.isBrightnessKeyEvent(event) {
                Task { @MainActor [weak self] in
                    self?.handleManualBrightnessEvent()
                }
            }
            return event
        }
        brightnessObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.BezelServices.BrightnessChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // BezelServices also broadcasts changes caused by automatic
                // brightness, True Tone, and ambient-light adjustments. Those
                // should update our baseline without looking like a user action.
                self.pollBrightness(
                    allowHUD: self.isManualBrightnessEventRecent
                )
            }
        }
    }

    private func removeBrightnessObservers() {
        if let globalSystemKeyMonitor {
            NSEvent.removeMonitor(globalSystemKeyMonitor)
        }
        if let localSystemKeyMonitor {
            NSEvent.removeMonitor(localSystemKeyMonitor)
        }
        if let brightnessObserver {
            DistributedNotificationCenter.default().removeObserver(brightnessObserver)
        }
        globalSystemKeyMonitor = nil
        localSystemKeyMonitor = nil
        brightnessObserver = nil
        lastManualBrightnessEventUptime = nil
    }

    private func installSystemAudioListeners() {
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.updateDefaultOutput(showConnection: true)
            }
        }
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectAddPropertyListenerBlock(
            systemObject,
            &defaultAddress,
            .main,
            defaultBlock
        ) == noErr {
            defaultOutputListener = defaultBlock
        }

        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleDeviceListChanged()
            }
        }
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectAddPropertyListenerBlock(
            systemObject,
            &devicesAddress,
            .main,
            devicesBlock
        ) == noErr {
            deviceListListener = devicesBlock
        }
    }

    private func stopAudioListeners() {
        removeOutputDeviceListeners()

        if let defaultOutputListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                systemObject,
                &address,
                .main,
                defaultOutputListener
            )
        }
        defaultOutputListener = nil

        if let deviceListListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                systemObject,
                &address,
                .main,
                deviceListListener
            )
        }
        deviceListListener = nil
    }

    private func updateDefaultOutput(showConnection: Bool) {
        guard let device = defaultOutputDevice() else { return }
        let previousDevice = currentOutputDevice
        if device != currentOutputDevice {
            removeOutputDeviceListeners()
            currentOutputDevice = device
            installOutputDeviceListeners(for: device)
        }

        let current = readVolumeState(for: device)
        lastVolume = current?.volume
        lastMuted = current?.muted

        if showConnection,
           previousDevice != AudioDeviceID(kAudioObjectUnknown),
           previousDevice != device,
           let name = audioDeviceName(device),
           isAirPods(device: device, name: name) {
            emitAirPods(name: name)
        }
    }

    private func installOutputDeviceListeners(for device: AudioDeviceID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.emitVolumeIfChanged()
            }
        }
        outputDeviceListener = block

        let selectors: [AudioObjectPropertySelector] = [
            kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyMute
        ]
        let elements: [AudioObjectPropertyElement] = [
            kAudioObjectPropertyElementMain,
            1,
            2
        ]

        for selector in selectors {
            for element in elements {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: element
                )
                guard AudioObjectHasProperty(device, &address) else { continue }
                if AudioObjectAddPropertyListenerBlock(
                    device,
                    &address,
                    .main,
                    block
                ) == noErr {
                    outputListenerAddresses.append(address)
                }
            }
        }
    }

    private func removeOutputDeviceListeners() {
        guard currentOutputDevice != AudioDeviceID(kAudioObjectUnknown),
              let outputDeviceListener else {
            outputListenerAddresses.removeAll()
            self.outputDeviceListener = nil
            return
        }

        for storedAddress in outputListenerAddresses {
            var address = storedAddress
            AudioObjectRemovePropertyListenerBlock(
                currentOutputDevice,
                &address,
                .main,
                outputDeviceListener
            )
        }
        outputListenerAddresses.removeAll()
        self.outputDeviceListener = nil
    }

    private func emitVolumeIfChanged() {
        guard let state = readVolumeState(for: currentOutputDevice) else { return }
        let volumeChanged = lastVolume.map { abs($0 - state.volume) > 0.003 } ?? false
        let muteChanged = lastMuted.map { $0 != state.muted } ?? false

        lastVolume = state.volume
        lastMuted = state.muted
        guard volumeChanged || muteChanged else { return }
        onEvent(.volume(state.volume, muted: state.muted))
    }

    private func readVolumeState(
        for device: AudioDeviceID
    ) -> (volume: Double, muted: Bool)? {
        guard device != AudioDeviceID(kAudioObjectUnknown) else { return nil }

        let masterVolume = floatProperty(
            kAudioDevicePropertyVolumeScalar,
            device: device,
            element: kAudioObjectPropertyElementMain
        )
        let channelVolumes = [1, 2].compactMap {
            floatProperty(
                kAudioDevicePropertyVolumeScalar,
                device: device,
                element: AudioObjectPropertyElement($0)
            )
        }
        let volume: Double
        if let masterVolume {
            volume = Double(masterVolume)
        } else if !channelVolumes.isEmpty {
            volume = Double(channelVolumes.reduce(0, +)) / Double(channelVolumes.count)
        } else {
            return nil
        }

        let muted = uint32Property(
            kAudioDevicePropertyMute,
            device: device,
            element: kAudioObjectPropertyElementMain
        ).map { $0 != 0 } ?? false
        return (max(0, min(1, volume)), muted)
    }

    private func floatProperty(
        _ selector: AudioObjectPropertySelector,
        device: AudioDeviceID,
        element: AudioObjectPropertyElement
    ) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value
    }

    private func uint32Property(
        _ selector: AudioObjectPropertySelector,
        device: AudioDeviceID,
        element: AudioObjectPropertyElement
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            &size,
            &device
        ) == noErr,
        device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return device
    }

    private func audioDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            systemObject,
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = Array(
            repeating: AudioDeviceID(kAudioObjectUnknown),
            count: count
        )
        guard AudioObjectGetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            &size,
            &devices
        ) == noErr else { return [] }
        return devices
    }

    private func handleDeviceListChanged() {
        let devices = Set(audioDevices())
        let added = devices.subtracting(knownDevices)
        knownDevices = devices

        for device in added {
            guard let name = audioDeviceName(device),
                  isAirPods(device: device, name: name) else { continue }
            emitAirPods(name: name)
            break
        }
    }

    private func audioDeviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            &size,
            &name
        ) == noErr else { return nil }
        return name?.takeUnretainedValue() as String?
    }

    private func transportType(_ device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value
    }

    private func isAirPods(device: AudioDeviceID, name: String) -> Bool {
        guard name.localizedCaseInsensitiveContains("airpods") else { return false }
        guard let transport = transportType(device) else { return true }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private func emitAirPods(name: String) {
        if let lastAirPodsEvent,
           lastAirPodsEvent.name == name,
           Date().timeIntervalSince(lastAirPodsEvent.date) < 3 {
            return
        }
        lastAirPodsEvent = (name, Date())
        onEvent(.airPods(name: name))
    }

    private func loadDisplayServices() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let symbol = dlsym(handle, "DisplayServicesGetBrightness") else {
            return
        }
        displayServicesHandle = handle
        getDisplayBrightness = unsafeBitCast(
            symbol,
            to: DisplayServicesGetBrightness.self
        )
    }

    private func handleManualBrightnessEvent() {
        lastManualBrightnessEventUptime = ProcessInfo.processInfo.systemUptime
        pollBrightness(allowHUD: true)
    }

    private var isManualBrightnessEventRecent: Bool {
        guard let lastManualBrightnessEventUptime else { return false }
        return ProcessInfo.processInfo.systemUptime - lastManualBrightnessEventUptime < 1.0
    }

    private func pollBrightness(allowHUD: Bool = false) {
        guard let brightness = readBrightness() else { return }
        defer { lastBrightness = brightness }
        guard let previous = lastBrightness,
              abs(previous - brightness) > 0.004 else { return }
        if allowHUD, isManualBrightnessEventRecent {
            onEvent(.brightness(brightness))
        }
    }

    nonisolated private static func isBrightnessKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .systemDefined else { return false }

        // systemDefined media-key events store the NX key type in the high
        // 16 bits of data1. NX_KEYTYPE_BRIGHTNESS_UP/DOWN are 2 and 3.
        let keyType = (UInt32(truncatingIfNeeded: event.data1) >> 16) & 0xFFFF
        return keyType == 2 || keyType == 3
    }

    private func readBrightness() -> Double? {
        let display = builtInDisplayID()
        var value: Float = 0

        guard let getDisplayBrightness,
              getDisplayBrightness(display, &value) == 0,
              value.isFinite else { return nil }
        return Double(max(0, min(1, value)))
    }

    private func builtInDisplayID() -> CGDirectDisplayID {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success,
              count > 0 else { return CGMainDisplayID() }

        var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return CGMainDisplayID()
        }
        return displays.first(where: { CGDisplayIsBuiltin($0) != 0 })
            ?? CGMainDisplayID()
    }
}
