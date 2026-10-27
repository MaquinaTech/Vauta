// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Synchronization

/// Whether the system reported memory pressure and has not reported it over. The brief reads it so that it never loads the integrated
/// model while memory is short (`BriefPolicy`). It starts watching on first use and reads nothing else.
public final class BriefMemoryPressure: Sendable {
    public static let shared = BriefMemoryPressure()

    private let high = Mutex(false)
    private let source = Mutex<DispatchSourceMemoryPressure?>(nil)

    public init() {}

    /// Memory is under pressure (warning or critical) right now.
    public var isHigh: Bool {
        startWatching()
        return high.withLock { $0 }
    }

    /// What a pressure event means: `normal` clears the flag, `warning` and `critical` set it.
    func apply(_ event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.normal) { high.withLock { $0 = false } }
        if event.contains(.warning) || event.contains(.critical) { high.withLock { $0 = true } }
    }

    private func startWatching() {
        source.withLock { current in
            guard current == nil else { return }
            let watcher = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: DispatchQueue(label: "vauta.brief.memory-pressure"))
            watcher.setEventHandler { [weak self, weak watcher] in
                if let data = watcher?.data { self?.apply(data) }
            }
            watcher.resume()
            current = watcher
        }
    }
}
