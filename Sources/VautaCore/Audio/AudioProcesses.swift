// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreAudio
import Foundation

/// A client process of Core Audio and whether it is using audio right now.
/// Metadata only: reading it opens no device and needs no permission.
public struct AudioProcess: Sendable, Equatable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    /// Empty when Core Audio reports none (some daemons).
    public let bundleID: String
    public let isRunningOutput: Bool
    public let isRunningInput: Bool

    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String, isRunningOutput: Bool, isRunningInput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
        self.isRunningInput = isRunningInput
    }

    /// The meeting-app family this process belongs to, if any.
    public var family: MeetingAppFamily? { MeetingAppCatalog.family(forBundleID: bundleID) }
}

/// Diagnostics: the processes Core Audio knows about (used by `Vauta status`
/// to find which process really plays or records a meeting's audio).
public enum AudioProcessDiagnostics {
    public typealias Process = AudioProcess

    public static func processes() -> [AudioProcess] { AudioProcesses.all() }
}

/// Core Audio process-object queries.
enum AudioProcesses {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func objectIDs() -> [AudioObjectID] {
        var address = globalAddress(kAudioHardwarePropertyProcessObjectList)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func all() -> [AudioProcess] { objectIDs().map(process) }

    static func process(_ id: AudioObjectID) -> AudioProcess {
        AudioProcess(objectID: id, pid: pid(id), bundleID: bundleID(id),
                     isRunningOutput: isRunning(id, input: false), isRunningInput: isRunning(id, input: true))
    }

    static func pid(_ id: AudioObjectID) -> pid_t {
        var pid = pid_t(-1)
        var size = UInt32(MemoryLayout<pid_t>.size)
        var address = globalAddress(kAudioProcessPropertyPID)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &pid)
        return pid
    }

    static func bundleID(_ id: AudioObjectID) -> String {
        var bundle: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = globalAddress(kAudioProcessPropertyBundleID)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &bundle) == noErr else { return "" }
        return (bundle?.takeRetainedValue() as String?) ?? ""
    }

    static func isRunning(_ id: AudioObjectID, input: Bool) -> Bool {
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = globalAddress(input ? kAudioProcessPropertyIsRunningInput : kAudioProcessPropertyIsRunningOutput)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    /// The process object of `pid`, or nil if that process has not opened audio.
    static func objectID(forPID pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = globalAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        let status = AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
