// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Chooses the calendar event a recording belongs to.
public enum CalendarEventPicker {
    /// The index of the event that overlaps most with `now ± window`.
    ///
    /// With back-to-back events this picks the one that is mostly ahead of
    /// `now` once it has started and the one ending soon before that; on a
    /// tie, the event that started later (the newer meeting). Events outside
    /// the window are ignored.
    public static func best(_ events: [(start: Date, end: Date)], now: Date, window: TimeInterval) -> Int? {
        let lower = now - window, upper = now + window
        var best: (index: Int, overlap: TimeInterval, start: Date)?
        for (index, event) in events.enumerated() {
            let end = max(event.end, event.start)
            let overlap = min(end, upper).timeIntervalSince(max(event.start, lower))
            // A zero-length event exactly inside the window still counts.
            guard overlap > 0 || (overlap == 0 && event.start >= lower && event.start <= upper) else { continue }
            if let current = best, overlap < current.overlap || (overlap == current.overlap && event.start <= current.start) { continue }
            best = (index, overlap, event.start)
        }
        return best?.index
    }
}
