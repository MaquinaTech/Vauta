// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The transcript as subtitles: one cue per segment, with the speaker.
public enum SubtitleRenderer {
    /// Shortest cue written when a segment has no usable end time.
    static let minimumCue = 1.0

    /// SubRip: numbered cues, "HH:MM:SS,mmm --> HH:MM:SS,mmm", "Speaker: text".
    public static func srt(_ lines: [MeetingExport.Line], options: MeetingExportOptions) -> String {
        var out = ""
        for (i, line) in lines.enumerated() {
            let (start, end) = times(line)
            out += "\(i + 1)\n"
            out += "\(ExportTimestamp.subtitle(start, separator: ",")) --> \(ExportTimestamp.subtitle(end, separator: ","))\n"
            out += "\(cueText(options.speaker(of: line))): \(cueText(line.text))\n"
            if let translation = line.translation(options) { out += "\(cueText(translation))\n" }
            out += "\n"
        }
        return out
    }

    /// WebVTT: "WEBVTT" header, numbered cues and the speaker as a voice span
    /// (`<v Name>`), so players can style or announce it.
    public static func webVTT(_ lines: [MeetingExport.Line], options: MeetingExportOptions) -> String {
        var out = "WEBVTT\n\n"
        for (i, line) in lines.enumerated() {
            let (start, end) = times(line)
            out += "\(i + 1)\n"
            out += "\(ExportTimestamp.subtitle(start, separator: ".")) --> \(ExportTimestamp.subtitle(end, separator: "."))\n"
            out += "<v \(voiceName(options.speaker(of: line)))>\(escapeVTT(cueText(line.text)))\n"
            if let translation = line.translation(options) { out += "\(escapeVTT(cueText(translation)))\n" }
            out += "\n"
        }
        return out
    }

    private static func times(_ line: MeetingExport.Line) -> (Double, Double) {
        let start = max(0, line.start)
        return (start, line.end > start ? line.end : start + minimumCue)
    }

    /// One line (a blank line would end the cue) without the cue separator.
    private static func cueText(_ text: String) -> String {
        SingleLineText.flatten(text).replacingOccurrences(of: "-->", with: "→")
    }

    private static func escapeVTT(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// A voice annotation ends at ">" and may not contain "<" or "&" unescaped.
    private static func voiceName(_ name: String) -> String {
        escapeVTT(cueText(name))
    }
}
