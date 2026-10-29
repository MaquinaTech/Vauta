// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreAudio
import Foundation

/// Where the Mac's sound comes out, as far as the microphone is concerned: speakers it hears, headphones, or a device that
/// can be either. Read from the default output device's metadata only (its transport and, for the Mac's own output, the data
/// source); it opens no device.
public enum OutputRoute: Sendable, Equatable {
    /// The Mac's own speakers, a display or TV (HDMI, DisplayPort) or AirPlay: the microphone hears the other participants.
    case speakers
    /// Headphones in the Mac's own jack.
    case headphones
    /// Bluetooth, USB and the rest can be headphones or speakers: never taken for speakers.
    case unknown

    /// The default output device's route; `unknown` when it can't be read.
    public static func current() -> OutputRoute {
        guard let device = defaultOutputDevice(), let transport = value(device, kAudioDevicePropertyTransportType) else { return .unknown }
        return route(transport: transport, dataSource: value(device, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput))
    }

    static func route(transport: UInt32, dataSource: UInt32?) -> OutputRoute {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            switch dataSource {
            case internalSpeakers: .speakers
            case headphoneJack: .headphones
            default: .unknown
            }
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay: .speakers
        default: .unknown
        }
    }

    /// The data sources of the Mac's own output ('ispk', 'hdpn').
    static let internalSpeakers: UInt32 = 0x6973_706B
    static let headphoneJack: UInt32 = 0x6864_706E

    static func defaultOutputDevice() -> AudioObjectID? {
        value(AudioProcesses.system, kAudioHardwarePropertyDefaultOutputDevice).flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    private static func value(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(object, &address), AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}

/// Tells when the output route changes: another default output device, or headphones in or out of the Mac's own jack
/// (the same device, another data source). Metadata only, like `MeetingPresence`.
public final class OutputRouteWatcher: @unchecked Sendable {
    private typealias Listener = (AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)

    private let queue = DispatchQueue(label: "vauta.output-route")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let onChange: @Sendable (OutputRoute) -> Void

    // Only on `queue`.
    private var systemListeners: [Listener] = []
    private var deviceListeners: [Listener] = []
    private var current: OutputRoute?

    /// `onChange` runs on the main queue, with the route at the start and after every change.
    public init(onChange: @escaping @Sendable (OutputRoute) -> Void) {
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: true)
        queue.async { self.start() }
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            removeAll()
        } else {
            queue.sync { removeAll() }
        }
    }

    private func start() {
        listen(AudioProcesses.system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, into: &systemListeners) { $0.deviceChanged() }
        listen(AudioProcesses.system, kAudioHardwarePropertyServiceRestarted, kAudioObjectPropertyScopeGlobal, into: &systemListeners) {
            $0.removeAll()
            $0.start()
        }
        deviceChanged()
    }

    private func deviceChanged() {
        remove(deviceListeners)
        deviceListeners = []
        if let device = OutputRoute.defaultOutputDevice() {
            listen(device, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput, into: &deviceListeners) { $0.publish() }
        }
        publish()
    }

    private func publish() {
        let route = OutputRoute.current()
        guard route != current else { return }
        current = route
        let notify = onChange
        DispatchQueue.main.async { notify(route) }
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
                        into list: inout [Listener], _ action: @escaping @Sendable (OutputRouteWatcher) -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            if let self { action(self) }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            list.append((object, address, block))
        }
    }

    private func remove(_ listeners: [Listener]) {
        for (id, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(id, &address, queue, block)
        }
    }

    private func removeAll() {
        remove(systemListeners)
        remove(deviceListeners)
        systemListeners = []
        deviceListeners = []
        current = nil
    }
}
