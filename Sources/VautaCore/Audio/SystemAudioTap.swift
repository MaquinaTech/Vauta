// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation
import CoreAudio

/// Captures the audio the Mac plays ("Others") with a Core Audio process tap.
/// No drivers or virtual devices: the tap and the aggregate device are private
/// to this process and are destroyed in `stop()`.
///
/// Scope (`SystemAudioScope`): with `.apps` the tap INCLUDES only the
/// processes of the chosen families, by bundle ID (followed across relaunches)
/// plus the object IDs of their other running processes (helpers), which are
/// updated in place on the live tap whenever processes appear or go away.
/// A browser family captures all of its tabs. `.allSystem` taps everything
/// except Vauta's own process.
///
/// The aggregate is clocked by the default output device. If that output
/// changes or disappears (Bluetooth headphones), the aggregate is rebuilt; a
/// watchdog also rebuilds it when the IOProc stops being called, and failed
/// rebuilds or a coreaudiod restart recreate the tap as well.
///
/// Bluetooth headsets: opening their microphone switches them from A2DP
/// (48 kHz) to HFP (16–24 kHz) and the device rate changes on the fly. Audio
/// reaches the IOProc at the aggregate CLOCK's rate while the tap and stream
/// formats may keep declaring 48 kHz (observed: declared 48000, real 16000).
/// So the rate comes from kAudioDevicePropertyNominalSampleRate, is re-read on
/// every change and, as a safety net, checked against the samples per second
/// that actually arrive.
///
/// Queues: the IOProc runs on `ioQueue`; Core Audio listeners only forward to
/// `controlQueue`, which owns all state (create, destroy, rebuild). Nothing is
/// stopped or destroyed from the IOProc.
final class SystemAudioTap: @unchecked Sendable {
    private typealias Listener = (AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)

    private let requestedScope: SystemAudioScope
    private let ownPID = getpid()
    private let ioQueue = DispatchQueue(label: "vauta.system-tap.io", qos: .userInitiated)
    private let listenerQueue = DispatchQueue(label: "vauta.system-tap.listeners")
    private let controlQueue = DispatchQueue(label: "vauta.system-tap.control", qos: .userInitiated)
    private let controlKey = DispatchSpecificKey<Bool>()

    // Only on controlQueue.
    private var scope: SystemAudioScope
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapDescription: CATapDescription?
    private var target: TapTarget?
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputUID: String?
    private var outputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var systemListeners: [Listener] = []
    private var tapListeners: [Listener] = []
    private var aggregateListeners: [Listener] = []
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var isRunning = false
    private var rebuildItem: DispatchWorkItem?
    private var retargetItem: DispatchWorkItem?
    private var rebuildAttempts = 0
    private var watchdog: DispatchSourceTimer?
    private var lastRebuild: UInt64 = 0
    private var stallRebuilds = 0
    private var rateOverride: (nominal: Float64, measured: Float64)?
    private let probe = RateProbe()

    // Shared with the IOProc.
    private let lock = NSLock()
    private var currentFormat: AVAudioFormat?
    private var lastCallback: UInt64 = 0
    var format: AVAudioFormat? { lock.withLock { currentFormat } }

    /// Diagnostic messages (formats, device changes). Never audio content.
    var onDiagnostic: (@Sendable (String) -> Void)?
    /// Channel state (reconnecting / lost / ok).
    var onHealth: (@Sendable (ChannelHealth) -> Void)?

    init(scope: SystemAudioScope) {
        requestedScope = scope
        self.scope = scope
        controlQueue.setSpecific(key: controlKey, value: true)
    }

    /// The scope in use (`.auto` is resolved when capture starts).
    var activeScope: SystemAudioScope { onControl { scope } }

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        try onControl {
            do {
                try startLocked(onBuffer)
            } catch {
                stopLocked()
                throw error
            }
        }
    }

    func stop() { onControl { stopLocked() } }

    deinit { onControl { stopLocked() } }

    // MARK: Lifecycle (controlQueue)

    private func startLocked(_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        scope = requestedScope == .auto ? requestedScope.resolved(with: MeetingPresence.currentState()) : requestedScope
        self.onBuffer = onBuffer
        isRunning = true
        try createTap()
        try buildAggregate()
        installSystemListeners()
        startWatchdog()
    }

    private func stopLocked() {
        isRunning = false
        rebuildItem?.cancel()
        rebuildItem = nil
        retargetItem?.cancel()
        retargetItem = nil
        watchdog?.cancel()
        watchdog = nil
        removeListeners(&systemListeners)
        teardownAggregate()
        destroyTap()
        onBuffer = nil
    }

    private func installSystemListeners() {
        let system = AudioProcesses.system
        listen(system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, into: &systemListeners) {
            $0.scheduleRebuild(reason: "default output changed")
        }
        listen(system, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, into: &systemListeners) {
            $0.scheduleRebuild(reason: "device list changed")
        }
        listen(system, kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal, into: &systemListeners) {
            $0.scheduleRetarget()
        }
        listen(system, kAudioHardwarePropertyServiceRestarted, kAudioObjectPropertyScopeGlobal, into: &systemListeners) {
            $0.serviceRestarted()
        }
    }

    // MARK: Tap (controlQueue)

    private func createTap() throws {
        let target = scope.tapTarget(processes: AudioProcesses.all(), ownPID: ownPID)
        let description: CATapDescription
        if target.excludes {
            description = CATapDescription(monoGlobalTapButExcludeProcesses: target.processes)
        } else {
            description = CATapDescription(monoMixdownOfProcesses: target.processes)
            description.bundleIDs = target.bundleIDs
            description.isProcessRestoreEnabled = true   // re-attach when a listed process relaunches
        }
        description.uuid = UUID()
        description.name = "Vauta"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var id = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &id), .systemAudioTapFailed)
        tapID = id
        tapDescription = description
        self.target = target
        onDiagnostic?("system tap: \(scope.storageValue), \(target.bundleIDs.count) bundle IDs, "
                      + "\(target.processes.count) process(es) \(target.excludes ? "excluded" : "included")")
        listen(tapID, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, into: &tapListeners) {
            $0.refreshFormat(reason: "tap format changed")
        }
    }

    private func destroyTap() {
        removeListeners(&tapListeners)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        tapDescription = nil
        target = nil
    }

    /// Processes appeared or went away: coalesce, then update the live tap.
    private func scheduleRetarget() {
        guard isRunning else { return }
        retargetItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.retarget() }
        retargetItem = item
        controlQueue.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// Updates the process list of the running tap in place
    /// (kAudioTapPropertyDescription), without rebuilding the aggregate.
    private func retarget() {
        retargetItem = nil
        guard isRunning, tapID != kAudioObjectUnknown, let description = tapDescription else { return }
        let newTarget = scope.tapTarget(processes: AudioProcesses.all(), ownPID: ownPID)
        guard newTarget != target else { return }
        description.processes = newTarget.processes
        var address = AudioProcesses.globalAddress(kAudioTapPropertyDescription)
        // The property's data is the description object reference.
        var reference = Unmanaged.passUnretained(description).toOpaque()
        let status = AudioObjectSetPropertyData(tapID, &address, 0, nil,
                                                UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &reference)
        if status == noErr {
            target = newTarget
            onDiagnostic?("system tap: now \(newTarget.processes.count) process(es) \(newTarget.excludes ? "excluded" : "included")")
        } else if !newTarget.excludes, Set(newTarget.processes).isSubset(of: target?.processes ?? []) {
            // Only processes that went away: the tap still covers everything wanted.
            target = newTarget
        } else {
            onDiagnostic?("system tap: live update failed (OSStatus \(status)), recreating the tap")
            scheduleRebuild(reason: "tap update failed", force: true, recreateTap: true, delay: 0)
        }
    }

    private func serviceRestarted() {
        onDiagnostic?("coreaudiod restarted: recreating the tap and its listeners")
        // Every object and listener belonged to the old service instance.
        removeListeners(&systemListeners)
        installSystemListeners()
        scheduleRebuild(reason: "audio service restarted", force: true, recreateTap: true, delay: 0.5)
    }

    // MARK: Aggregate (controlQueue)

    /// Private aggregate: the default output as clock and only subdevice, plus the tap.
    private func buildAggregate() throws {
        guard let onBuffer else { throw CaptureError(.systemAudioStartFailed) }
        let (deviceID, uid) = try Self.defaultOutputDevice()
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Vauta",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: (tapDescription?.uuid ?? UUID()).uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID), .systemAudioDeviceFailed)
        outputUID = uid
        outputDeviceID = deviceID
        onDiagnostic?("tapped output: \(uid)")

        rateOverride = nil
        refreshFormat(reason: "start")
        guard format != nil else { throw CaptureError(.systemAudioFormatUnavailable) }
        listen(aggregateID, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, into: &aggregateListeners) {
            $0.refreshFormat(reason: "device rate changed")
        }
        listen(aggregateID, kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput, into: &aggregateListeners) {
            $0.refreshFormat(reason: "device format changed")
        }
        listen(deviceID, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, into: &aggregateListeners) {
            $0.scheduleRebuild(reason: "output went away")
        }

        // If the clock device has inputs of its own (USB or Bluetooth headsets),
        // the aggregate delivers them before the tap's stream: pick the tap's.
        let streams = TapStream.inputStreamChannels(aggregateID)
        let tapStream = TapStream(preferredIndex: streams.isEmpty ? nil : streams.count - 1)
        if streams.count > 1 { onDiagnostic?("aggregate has \(streams.count) input streams; tap is #\(streams.count - 1)") }

        probe.reset()
        lock.withLock { lastCallback = mach_absolute_time() }
        lastRebuild = mach_absolute_time()
        let probe = probe
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, inputData, _, _, _ in
            guard let self else { return }
            let format = self.lock.withLock {
                self.lastCallback = mach_absolute_time()
                return self.currentFormat
            }
            guard let format, let list = tapStream.list(from: inputData, channels: format.channelCount) else { return }
            let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
            if bytesPerFrame > 0, let measured = probe.add(frames: Int(list.pointee.mBuffers.mDataByteSize / bytesPerFrame)) {
                self.controlQueue.async { self.correctRate(measured: measured) }
            }
            // Memory lent by Core Audio: valid only during this callback.
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil) else { return }
            onBuffer(buffer)
        }, .systemAudioStartFailed)
        if streams.count > 1, let procID { TapStream.enableOnlyInputStream(streams.count - 1, of: streams.count, aggregateID, procID) }
        try check(AudioDeviceStart(aggregateID, procID), .systemAudioStartFailed)
    }

    private func teardownAggregate() {
        removeListeners(&aggregateListeners)
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
        outputUID = nil
        outputDeviceID = AudioObjectID(kAudioObjectUnknown)
        rateOverride = nil
    }

    // MARK: Rebuild (controlQueue)

    /// Coalesces bursts of notifications (~300 ms) and rebuilds only if needed.
    private func scheduleRebuild(reason: String, force: Bool = false, recreateTap: Bool = false, delay: Double = 0.3) {
        guard isRunning else { return }
        rebuildItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.rebuildIfNeeded(reason: reason, force: force, recreateTap: recreateTap)
        }
        rebuildItem = item
        controlQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func rebuildIfNeeded(reason: String, force: Bool, recreateTap: Bool) {
        rebuildItem = nil
        guard isRunning else { return }
        let current = try? Self.defaultOutputDevice()
        let alive = outputDeviceID != kAudioObjectUnknown && Self.isAlive(outputDeviceID)
        guard force || current?.uid != outputUID || !alive || aggregateID == kAudioObjectUnknown else { return }

        onHealth?(.reconnecting)
        onDiagnostic?("system audio (\(reason)): reconnecting to \(current?.uid ?? "?")\(recreateTap ? " with a new tap" : "")")
        teardownAggregate()
        do {
            if recreateTap || tapID == kAudioObjectUnknown {
                destroyTap()
                try createTap()
            }
            try buildAggregate()
            rebuildAttempts = 0
            onHealth?(.ok)
        } catch {
            teardownAggregate()
            rebuildAttempts += 1
            onDiagnostic?("system audio: reconnect failed: \(error)")
            if rebuildAttempts >= 5 {
                onHealth?(.lost(CaptureError(.systemAudioLost, status: (error as? CaptureError)?.status)))
            }
            let backoff = [0.5, 1, 2][min(rebuildAttempts - 1, 2)]
            // A failed rebuild may come from a dead tap: the next try starts from scratch.
            scheduleRebuild(reason: "retry", force: true, recreateTap: true, delay: backoff)
        }
    }

    /// If the IOProc gets no calls for >2 s (waiting longer each time a rebuild
    /// doesn't fix it), forces a rebuild; from the second one on, with a new tap.
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning, self.aggregateID != kAudioObjectUnknown else { return }
            let last = self.lock.withLock { self.lastCallback }
            if last > self.lastRebuild { self.stallRebuilds = 0 }
            let limit = 2.0 * Double(1 << min(self.stallRebuilds, 4))
            guard Self.seconds(since: last) > limit, self.rebuildItem == nil else { return }
            self.stallRebuilds += 1
            self.rebuildIfNeeded(reason: "no system audio for \(Int(limit)) s", force: true,
                                 recreateTap: self.stallRebuilds > 1)
        }
        timer.resume()
        watchdog = timer
    }

    // MARK: Format (controlQueue)

    /// The buffers' real format: the tap's (channels, sample type) at the
    /// aggregate clock's rate, or the measured rate if the device misreports it.
    private func refreshFormat(reason: String) {
        guard tapID != kAudioObjectUnknown else { return }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioProcesses.globalAddress(kAudioTapPropertyFormat)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd) == noErr else { return }
        if let nominal = nominalRate() {
            if let o = rateOverride, o.nominal == nominal {
                asbd.mSampleRate = o.measured   // the device still declares the same rate: keep the correction
            } else {
                rateOverride = nil              // a real device or profile change
                asbd.mSampleRate = nominal
            }
        }
        if setFormat(asbd, reason: reason) { probe.reset() }
    }

    private func correctRate(measured: Double) {
        guard isRunning, let assumed = format,
              let corrected = Self.correctedRate(measured: measured, assumed: assumed.sampleRate) else { return }
        if let nominal = nominalRate() { rateOverride = (nominal, corrected) }
        var asbd = assumed.streamDescription.pointee
        asbd.mSampleRate = corrected
        setFormat(asbd, reason: "measured \(Int(measured)) samples/s, corrected")
        probe.reset()
    }

    /// If the samples per second that arrive differ from the assumed rate by
    /// more than 5 %, the nearest standard rate to the measurement; else nil.
    static func correctedRate(measured: Double, assumed: Double) -> Double? {
        guard assumed > 0, abs(measured - assumed) / assumed > 0.05 else { return nil }
        let standard: [Double] = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000]
        return standard.min { abs($0 - measured) < abs($1 - measured) }
    }

    private func nominalRate() -> Float64? {
        guard aggregateID != kAudioObjectUnknown else { return nil }
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioProcesses.globalAddress(kAudioDevicePropertyNominalSampleRate)
        guard AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    @discardableResult
    private func setFormat(_ asbd: AudioStreamBasicDescription, reason: String) -> Bool {
        var asbd = asbd
        guard let newFormat = AVAudioFormat(streamDescription: &asbd) else { return false }
        let changed = lock.withLock {
            defer { currentFormat = newFormat }
            return currentFormat != newFormat
        }
        if changed {
            onDiagnostic?("system audio (\(reason)): \(Int(newFormat.sampleRate)) Hz, \(newFormat.channelCount) channel(s)")
        }
        return changed
    }

    // MARK: Utilities

    /// Listeners only forward to controlQueue, so removing one from
    /// controlQueue never waits for a callback that waits for controlQueue.
    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
                        into list: inout [Listener], _ action: @escaping @Sendable (SystemAudioTap) -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.controlQueue.async { if self.isRunning { action(self) } }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block) == noErr {
            list.append((object, address, block))
        }
    }

    private func removeListeners(_ list: inout [Listener]) {
        for (object, address, block) in list {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, listenerQueue, block)
        }
        list.removeAll()
    }

    private func onControl<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: controlKey) == true { return try body() }
        return try controlQueue.sync(execute: body)
    }

    private static func seconds(since ticks: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let now = mach_absolute_time()
        guard now > ticks else { return 0 }
        return Double(now - ticks) * Double(info.numer) / Double(info.denom) / 1e9
    }

    private static func isAlive(_ device: AudioObjectID) -> Bool {
        var alive = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioProcesses.globalAddress(kAudioDevicePropertyDeviceIsAlive)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    private static func defaultOutputDevice() throws -> (id: AudioObjectID, uid: String) {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioProcesses.globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        try check(AudioObjectGetPropertyData(AudioProcesses.system, &address, 0, nil, &size, &deviceID), .audioDeviceQueryFailed)
        guard deviceID != kAudioObjectUnknown else { throw CaptureError(.noOutputDevice) }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid), .audioDeviceQueryFailed)
        guard let uid else { throw CaptureError(.noOutputDevice) }
        return (deviceID, uid.takeRetainedValue() as String)
    }
}
