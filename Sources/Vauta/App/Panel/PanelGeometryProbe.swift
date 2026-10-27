// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI

/// A check that the panel's visible area never ends through a note of the live notes card. The snapshot renders (diagnostics
/// build only) read where each note and the two viewports are, in window coordinates, and fail the scene when the bottom of a
/// viewport falls inside a note. In the release build every modifier here does nothing.
enum PanelGeometryProbe {
    /// Where a rectangle of the probe is: a note, the notes' viewport, or the panel's scrolling viewport.
    struct Item: Equatable {
        enum Kind { case note, notesViewport, panelViewport }
        var kind: Kind
        var frame: CGRect
    }

    struct Key: PreferenceKey {
        static let defaultValue: [Item] = []
        static func reduce(value: inout [Item], nextValue: () -> [Item]) { value += nextValue() }
    }

    /// The rectangles reported by the panel on screen (the last pass).
    @MainActor static var items: [Item] = []

    /// Why the layout cuts through a note, or nil when it does not. A note is a whole Text (all its lines).
    /// `requiringNotesOnScreen`: a scene made to show where the notes end is wrong when no note is in view.
    @MainActor static func problem(tolerance: CGFloat = 0.5, requiringNotesOnScreen: Bool = false) -> String? {
        let notes = items.filter { $0.kind == .note }.map(\.frame)
        let clip = items.first { $0.kind == .notesViewport }?.frame
        guard let panel = items.first(where: { $0.kind == .panelViewport })?.frame else { return "the panel's scrolling viewport was not reported" }
        guard !notes.isEmpty else { return "no note was reported" }
        // A note that is hidden by the notes' own viewport does not count; one that is cut by either bottom does.
        var anyShown = false
        for note in notes {
            // Only what the person can see: inside the panel's viewport and inside the notes' own.
            var shown = note.intersection(panel)
            if let clip { shown = shown.intersection(clip) }
            if shown.isNull || shown.height <= 0 { continue }
            anyShown = true
            for (name, bottom) in [("the panel's viewport", panel.maxY), ("the notes' viewport", clip?.maxY)] {
                guard let bottom else { continue }
                if note.minY < bottom - tolerance, note.maxY > bottom + tolerance {
                    return "a note (\(Int(note.minY))–\(Int(note.maxY))) is cut by the bottom of \(name) (\(Int(bottom)))"
                }
            }
        }
        // A scene that proves where the notes end proves nothing when no note is on screen (the card is scrolled out of view).
        return anyShown || !requiringNotesOnScreen ? nil : "the live notes are not on screen (no note is inside the panel's viewport)"
    }
}

extension View {
    /// Reports this view's frame to the geometry probe (diagnostics build only).
    @ViewBuilder func panelProbe(_ kind: PanelGeometryProbe.Item.Kind?) -> some View {
        #if VAUTA_DIAGNOSTICS
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: PanelGeometryProbe.Key.self, value: kind.map { [.init(kind: $0, frame: proxy.frame(in: .global))] } ?? [])
            }
        }
        #else
        self
        #endif
    }

    /// Collects what the probe's views reported (diagnostics build only).
    @ViewBuilder func panelProbeCollects() -> some View {
        #if VAUTA_DIAGNOSTICS
        onPreferenceChange(PanelGeometryProbe.Key.self) { items in
            MainActor.assumeIsolated { PanelGeometryProbe.items = items }
        }
        #else
        self
        #endif
    }
}
