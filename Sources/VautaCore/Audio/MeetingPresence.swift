// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreAudio
import Foundation

/// Watches which app is using the microphone, from Core Audio metadata only:
/// `IsRunningInput`/`IsRunningOutput` of every client process. It opens no
/// device, reads no samples, window titles or URLs, and needs no permission.
///
/// It drives the "transcribe this meeting?" suggestion and the "did the
/// meeting end?" notice. It never starts or stops a recording by itself.
public final class MeetingPresence: @unchecked Sendable {
    /// A one-off snapshot (for diagnostics and for resolving `.auto`).
    public static func currentState() -> PresenceState {
        PresenceState(processes: AudioProcesses.all(), ownPID: getpid())
    }

    private typealias Listener = (AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)

    private let queue = DispatchQueue(label: "vauta.presence")
    private let onChange: @Sendable (PresenceState) -> Void
    private let ownPID = getpid()

    // Only on `queue`.
    private var systemListeners: [Listener] = []
    private var processListeners: [AudioObjectID: [Listener]] = [:]
    /// Static attributes of each watched process.
    private var known: [AudioObjectID: (pid: pid_t, bundleID: String)] = [:]
    private var current: PresenceState?
    private var pending: DispatchWorkItem?
    private var pendingState: PresenceState?

    /// `onChange` runs on the main queue, after 2 s of stability (apps release
    /// and reopen the microphone when the audio device changes).
    public init(onChange: @escaping @Sendable (PresenceState) -> Void) {
        self.onChange = onChange
        queue.async { self.start() }
    }

    deinit {
        removeAll()
    }

    private func start() {
        listen(AudioProcesses.system, kAudioHardwarePropertyProcessObjectList, into: &systemListeners) { $0.refresh() }
        listen(AudioProcesses.system, kAudioHardwarePropertyServiceRestarted, into: &systemListeners) { $0.serviceRestarted() }
        refresh()
    }

    /// coreaudiod restarted: every object ID and listener is gone. Start over.
    private func serviceRestarted() {
        removeAll()
        start()
    }

    /// Subscribes to new processes, drops gone ones and recomputes the state.
    private func refresh() {
        let ids = AudioProcesses.objectIDs()
        let alive = Set(ids)
        for (id, listeners) in processListeners where !alive.contains(id) {
            remove(listeners)
            processListeners[id] = nil
            known[id] = nil
        }
        var processes: [AudioProcess] = []
        for id in ids {
            if known[id] == nil {
                known[id] = (AudioProcesses.pid(id), AudioProcesses.bundleID(id))
                var listeners: [Listener] = []
                listen(id, kAudioProcessPropertyIsRunningInput, into: &listeners) { $0.refresh() }
                listen(id, kAudioProcessPropertyIsRunningOutput, into: &listeners) { $0.refresh() }
                processListeners[id] = listeners
            }
            guard let info = known[id] else { continue }
            processes.append(AudioProcess(objectID: id, pid: info.pid, bundleID: info.bundleID,
                                          isRunningOutput: AudioProcesses.isRunning(id, input: false),
                                          isRunningInput: AudioProcesses.isRunning(id, input: true)))
        }
        publish(PresenceState(processes: processes, ownPID: ownPID))
    }

    private func publish(_ state: PresenceState) {
        // Every process's activity triggers a refresh: an unrelated one must
        // not restart the stability wait of a change already pending.
        if pending != nil, state == pendingState { return }
        pending?.cancel()
        pending = nil
        pendingState = nil
        guard let delay = PresenceState.publishDelay(current: current, new: state) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.current = state
            self.pending = nil
            self.pendingState = nil
            let notify = self.onChange
            DispatchQueue.main.async { notify(state) }
        }
        pending = work
        pendingState = state
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Listeners

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into list: inout [Listener],
                        _ action: @escaping @Sendable (MeetingPresence) -> Void) {
        var address = AudioProcesses.globalAddress(selector)
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
        systemListeners = []
        for listeners in processListeners.values { remove(listeners) }
        processListeners = [:]
        known = [:]
    }
}
