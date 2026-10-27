// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A small least-recently-used cache of translated sentences ("Yes.",
/// "Thank you", a partial that becomes final unchanged). It lives and dies
/// with one language pair, in memory only.
struct TranslationCache {
    private var entries: [String: (text: String, tick: Int)] = [:]
    private var tick = 0
    let capacity: Int

    init(capacity: Int = 128) { self.capacity = max(1, capacity) }

    var count: Int { entries.count }

    mutating func value(for source: String) -> String? {
        guard var entry = entries[source] else { return nil }
        tick += 1
        entry.tick = tick
        entries[source] = entry
        return entry.text
    }

    mutating func insert(_ translation: String, for source: String) {
        tick += 1
        entries[source] = (translation, tick)
        if entries.count > capacity, let oldest = entries.min(by: { $0.value.tick < $1.value.tick })?.key {
            entries[oldest] = nil
        }
    }

    mutating func removeAll() { entries.removeAll(keepingCapacity: true) }
}
