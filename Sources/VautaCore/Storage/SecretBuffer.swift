// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Owned memory for plaintext: zeroed when released.
final class SecretBuffer: @unchecked Sendable {
    let base: UnsafeMutableRawPointer
    let capacity: Int
    var count = 0

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        base = UnsafeMutableRawPointer.allocate(byteCount: self.capacity, alignment: 16)
    }

    var bytes: UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: base, count: count) }

    deinit {
        memset_s(base, capacity, 0, capacity)
        base.deallocate()
    }
}

/// Overwrites a `Data`'s bytes with zeros (best effort: copies made by
/// Foundation or CryptoKit cannot be reached).
func wipe(_ data: inout Data) {
    data.withUnsafeMutableBytes { if let p = $0.baseAddress, $0.count > 0 { memset_s(p, $0.count, 0, $0.count) } }
}
