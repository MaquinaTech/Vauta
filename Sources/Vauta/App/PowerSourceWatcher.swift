// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import IOKit.ps

/// Calls `onChange` (on the main run loop) when the Mac moves between battery and the charger, or the battery's state changes.
/// Neither Low Power Mode nor the thermal state notifications cover that, so work that waits for the charger needs this one.
/// It reads nothing about the battery itself.
final class PowerSourceWatcher {
    private final class Box {
        let onChange: () -> Void
        init(_ onChange: @escaping () -> Void) { self.onChange = onChange }
    }

    private var source: CFRunLoopSource?
    private var box: Unmanaged<Box>?

    init(onChange: @escaping () -> Void) {
        let retained = Unmanaged.passRetained(Box(onChange))
        box = retained
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            Unmanaged<Box>.fromOpaque(context).takeUnretainedValue().onChange()
        }
        guard let created = IOPSNotificationCreateRunLoopSource(callback, retained.toOpaque())?.takeRetainedValue() else {
            retained.release()
            box = nil
            return
        }
        source = created
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        box?.release()
        box = nil
    }

    deinit { stop() }
}
