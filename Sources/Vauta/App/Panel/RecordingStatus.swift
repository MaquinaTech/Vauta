// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// While recording: what is captured (source app, language) and the level meters.
struct RecordingStatus: View {
    let model: RecorderModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                if let source = sourceName {
                    Chip(text: source, systemImage: "speaker.wave.2")
                        .accessibilityLabel(Text("Audio source: \(source)"))
                }
                if let language = model.recordingLanguage {
                    Chip(text: model.shortLanguageName(language), systemImage: "globe")
                        .accessibilityLabel(Text("Language: \(language.displayName.standaloneCapitalized)"))
                }
            }
            // While saving nothing is captured any more: no meters frozen at their last level.
            if model.isRecording {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    LevelRow(channel: .me, level: model.levels[.me] ?? 0, tint: Channel.me.tint)
                    LevelRow(channel: .others, level: model.levels[.others] ?? 0, tint: Channel.others.tint)
                }
            }
        }
    }

    private var sourceName: String? {
        if let app = model.recordingApp?.shortName { return app }
        return model.recordingSource?.summary
    }
}

/// A small capsule with an icon and a short text. Only what opens a menu is drawn as a capsule:
/// a plain `Chip` (what is being recorded) is just the icon and the text, in the secondary colour.
struct Chip: View {
    let text: String
    let systemImage: String?
    /// A menu's label: a small chevron says it opens, and the capsule says it can be pressed.
    var showsChevron = false
    /// Menu chips give way, in the middle of the text, when the row is too narrow.
    var truncatesInMiddle = false
    /// A menu that asks for a choice before anything works is drawn in the accent colour.
    var tint: Color?
    /// A menu that cannot be opened is drawn dimmed, like the Live Translation row.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if showsChevron { capsule } else { plain }
    }

    /// The text with its icon; a chip without an icon is only the text.
    @ViewBuilder private func label(truncation: Text.TruncationMode) -> some View {
        if let systemImage {
            Label {
                Text(verbatim: text).lineLimit(1).truncationMode(truncation)
            } icon: {
                Image(systemName: systemImage)
            }
        } else {
            Text(verbatim: text).lineLimit(1).truncationMode(truncation)
        }
    }

    private var plain: some View {
        label(truncation: .middle)
        .font(.callout)
        .foregroundStyle(.secondary)
        // Same height as the menu chips, so the panel keeps its rhythm.
        .padding(.vertical, 4)
    }

    private var capsule: some View {
        HStack(spacing: 4) {
            label(truncation: truncatesInMiddle ? .middle : .tail)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .font(.callout)
        .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(tint.map { AnyShapeStyle($0.opacity(0.16)) } ?? AnyShapeStyle(.quinary), in: Capsule())
        .opacity(isEnabled ? 1 : 0.5)
    }
}

/// A channel's level meter.
struct LevelRow: View {
    let channel: Channel
    let level: Double
    let tint: Color

    var body: some View {
        GridRow {
            Text(verbatim: channel.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .gridColumnAlignment(.leading)
                .accessibilityHidden(true)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    // No sound, no fill: a stub at zero would read as "a little sound".
                    Capsule().fill(tint.gradient)
                        .frame(width: level <= 0.001 ? 0 : max(4, geo.size.width * level))
                        .animation(.easeOut(duration: 0.15), value: level)
                }
            }
            .frame(height: 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(channel.displayName) level", comment: "Accessibility label of a channel’s audio meter; the argument is Me or Others"))
            .accessibilityValue(Text(level.formatted(.percent.precision(.fractionLength(0)))))
        }
    }
}
