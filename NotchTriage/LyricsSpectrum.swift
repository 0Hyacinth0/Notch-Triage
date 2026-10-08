import AppKit
import Accelerate
import Combine
import CoreAudio

struct LyricsSpectrumFrame {
    var bands = [Double](repeating: 0, count: 14)
    var previous = [Double](repeating: 0, count: 14)
    var timestamp = ProcessInfo.processInfo.systemUptime
    static let silent = LyricsSpectrumFrame()
    func interpolated(at uptime: Double) -> [Double] {
        let t = min(1, max(0, (uptime - timestamp) * 30))
        return zip(previous, bands).map { $0 + ($1 - $0) * t }
    }
}

/// Only band energies leave this object. PCM stays in a bounded memory buffer.
@MainActor final class LyricsSpectrum: ObservableObject {
    @Published private(set) var frame = LyricsSpectrumFrame.silent
    @Published private(set) var status = "真实频谱未启用"
    private var engine: LyricsAudioTap?
    private var failed = false
    private var ticket = UUID()
    private var routeListener: AudioObjectPropertyListenerBlock?
    func setActive(_ active: Bool) {
        guard active else {
            stop()
            if !failed { status = "等待歌词显示和音乐播放" }
            return
        }
        guard engine == nil, !failed else { return }
        let generation = UUID(); ticket = generation
        do {
            let tap = try LyricsAudioTap { [weak self] bands in
                DispatchQueue.main.async {
                    guard let self, self.ticket == generation, self.engine != nil else { return }
                    let previous = self.frame.interpolated(at: ProcessInfo.processInfo.systemUptime)
                    self.frame = LyricsSpectrumFrame(bands: bands, previous: previous)
                    let status = (bands.max() ?? 0) > 0.015 ? "正在分析系统音频" : "等待音频信号；无信号时请检查系统音频权限"
                    if self.status != status { self.status = status }
                }
            }
            engine = tap; status = "等待系统音频信号"
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                DispatchQueue.main.async {
                    guard let self, self.engine != nil else { return }
                    self.stop(); self.failed = false; self.setActive(true)
                }
            }
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr { routeListener = listener }
        } catch {
            failed = true; status = "无法启动频谱，请检查系统音频权限后重试"
        }
    }
    func disable() { stop(); failed = false; status = "真实频谱未启用" }
    func stop() {
        ticket = UUID()
        if let listener = routeListener {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
            routeListener = nil
        }
        if engine != nil { status = "真实频谱已暂停" }
        engine?.stop(); engine = nil
        frame = .silent
    }
    func resetFailure() { failed = false }
}

private final class LyricsAudioTap: @unchecked Sendable {
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "NotchTriage.lyrics.spectrum", qos: .utility)
    private let ring = LyricsAudioRing()
    private let analyzer = LyricsSpectrumAnalyzer()
    private var sampleRate: Double = 48_000
    private var lastRead: UInt64 = 0
    private var levels = [Double](repeating: 0, count: 14)
    private var lastTime = ProcessInfo.processInfo.systemUptime
    private var samples = [Float](repeating: 0, count: 2048)

    init(deliver: @escaping @Sendable ([Double]) -> Void) throws {
        do {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.name = "Notch Triage Lyrics Spectrum"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap))
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format))
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32, format.mSampleRate > 0 else { throw TapError.unsupportedFormat }
            sampleRate = format.mSampleRate
            let configuration: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Notch Triage Private Spectrum",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &device))
            let ring = self.ring
            try check(AudioDeviceCreateIOProcIDWithBlock(&io, device, nil) { _, input, _, _, _ in
                ring.append(input)
            })
            try check(AudioDeviceStart(device, io))
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(3))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let count = self.ring.read(into: &self.samples)
                let fresh = count != self.lastRead
                self.lastRead = count
                let target = fresh ? self.analyzer.bands(samples: self.samples, sampleRate: self.sampleRate) : [Double](repeating: 0, count: 14)
                let now = ProcessInfo.processInfo.systemUptime
                let dt = min(0.2, max(0, now - self.lastTime)); self.lastTime = now
                for i in self.levels.indices {
                    let response = target[i] > self.levels[i] ? 22.0 : 5.5
                    self.levels[i] += (target[i] - self.levels[i]) * (1 - exp(-response * dt))
                    if self.levels[i] < 0.001 { self.levels[i] = 0 }
                }
                deliver(self.levels)
            }
            self.timer = timer; timer.resume()
        } catch { stop(); throw error }
    }
    func stop() {
        timer?.cancel(); timer = nil
        if let io, device != 0 { AudioDeviceStop(device, io); AudioDeviceDestroyIOProcID(device, io) }
        io = nil
        if device != 0 { AudioHardwareDestroyAggregateDevice(device); device = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }
    deinit { stop() }
    private enum TapError: Error { case status(OSStatus), unsupportedFormat }
    private func check(_ status: OSStatus) throws { if status != noErr { throw TapError.status(status) } }
}

/// The audio callback never waits for the analyzer, allocates, or dispatches work.
private final class LyricsAudioRing: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [Float](repeating: 0, count: 2048)
    private var cursor = 0
    private var written: UInt64 = 0
    func append(_ input: UnsafePointer<AudioBufferList>) {
        guard lock.try() else { return }
        defer { lock.unlock() }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mNumberChannels > 0 else { return }
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
        // Average all stereo channels rather than confusing interleaved samples with frames.
        for frame in max(0, frames - storage.count)..<frames {
            var value: Float = 0; var channels: Float = 0
            for buffer in buffers {
                guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
                let count = Int(buffer.mNumberChannels)
                guard (frame + 1) * count * MemoryLayout<Float>.size <= Int(buffer.mDataByteSize) else { continue }
                let source = data.assumingMemoryBound(to: Float.self)
                for channel in 0..<count { value += source[frame * count + channel]; channels += 1 }
            }
            storage[cursor] = channels > 0 && value.isFinite ? value / channels : 0
            cursor = (cursor + 1) % storage.count; written &+= 1
        }
    }
    func read(into samples: inout [Float]) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        for i in samples.indices { samples[i] = storage[(cursor + i) % storage.count] }
        return written
    }
}

private final class LyricsSpectrumAnalyzer {
    private let setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))
    private var window = [Float](repeating: 0, count: 2048)
    private var input = [Float](repeating: 0, count: 2048)
    private var real = [Float](repeating: 0, count: 1024)
    private var imaginary = [Float](repeating: 0, count: 1024)
    private var power = [Float](repeating: 0, count: 1024)
    init() { vDSP_hann_window(&window, 2048, Int32(vDSP_HANN_NORM)) }
    deinit { if let setup { vDSP_destroy_fftsetup(setup) } }
    func bands(samples: [Float], sampleRate: Double) -> [Double] {
        guard let setup else { return [Double](repeating: 0, count: 14) }
        vDSP_vmul(samples, 1, window, 1, &input, 1, 2048)
        real.withUnsafeMutableBufferPointer { r in
            imaginary.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                input.withUnsafeBufferPointer { values in
                    values.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: 1024) { vDSP_ctoz($0, 2, &split, 1, 1024) }
                }
                vDSP_fft_zrip(setup, &split, 1, 11, FFTDirection(FFT_FORWARD))
                split.imagp[0] = 0 // packed Nyquist value is not part of the DC bin
                vDSP_zvmags(&split, 1, &power, 1, 1024)
            }
        }
        let upper = min(14_000, sampleRate * 0.48)
        return (0..<14).map { band in
            let low = 50 * pow(upper / 50, Double(band) / 14)
            let high = 50 * pow(upper / 50, Double(band + 1) / 14)
            let start = max(1, min(1023, Int(low * 2048 / sampleRate)))
            let end = max(start + 1, min(1024, Int(high * 2048 / sampleRate)))
            let rms = sqrt(power[start..<end].reduce(0, +) / Float(end - start)) / 2048
            let db = 20 * log10(max(0.000_001, Double(rms)))
            return pow(max(0, min(1, (db + 65) / 55)), 0.75)
        }
    }
}
