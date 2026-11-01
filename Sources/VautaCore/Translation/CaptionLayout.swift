// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreGraphics
import Foundation

/// The caption text sizes. Medium is readable at a glance from a normal
/// viewing distance.
public enum CaptionTextSize: String, CaseIterable, Sendable, Identifiable {
    case small, medium, large, extraLarge

    public var id: String { rawValue }

    /// Point size of the translated text.
    public var points: CGFloat {
        switch self {
        case .small: 17
        case .medium: 22
        case .large: 28
        case .extraLarge: 36
        }
    }

    /// Point size of the small original-language line.
    public var originalPoints: CGFloat { max(13, (points * 0.68).rounded()) }

    public var title: String {
        switch self {
        case .small: String(localized: "Small", comment: "Caption text size")
        case .medium: String(localized: "Medium", comment: "Caption text size")
        case .large: String(localized: "Large", comment: "Caption text size")
        case .extraLarge: String(localized: "Extra Large", comment: "Caption text size")
        }
    }

    /// Fixed line height: the panel never changes height while captions change.
    var lineHeight: CGFloat { (points * 1.3).rounded() }

    var originalLineHeight: CGFloat { (originalPoints * 1.3).rounded() }

    /// Space between two captions, and between a caption and its original line.
    public static let rowSpacing: CGFloat = 6
    /// With the originals shown, each translation and its original are one block: the gap to the next block is
    /// clearly larger than the one inside it.
    public static func rowSpacing(showOriginal: Bool) -> CGFloat { showOriginal ? rowSpacing * 2 : rowSpacing }
    public static let originalSpacing: CGFloat = 2

    /// The height of the captions panel: three captions of one line each, the gaps between them,
    /// and one original line under each when they are shown, plus the padding. The hover bar floats
    /// over the top padding instead of taking room of its own, so the captions never move when the
    /// pointer arrives. Longer captions that wrap push the oldest one up under a fade.
    public func panelHeight(showOriginal: Bool) -> CGFloat {
        var text = lineHeight * 3 + Self.rowSpacing(showOriginal: showOriginal) * 2
        if showOriginal { text += (originalLineHeight + Self.originalSpacing) * 3 }
        return text + Self.verticalPadding * 2
    }

    /// The same room above and below the captions. The hover bar (28 pt, 6 pt from the edge) ends above the first line
    /// and floats over the padding, so it never takes room of its own.
    public static let verticalPadding: CGFloat = 38
    /// The padding is not split evenly: under the hover bar (it ends 36 pt from the top) the captions keep a fixed 8 pt gap,
    /// whatever the language or the number of lines, and the captions are centred in the room below it. The two add up to
    /// `verticalPadding * 2`, so the panel's height does not change.
    public static let topPadding: CGFloat = 44
    public static let bottomPadding: CGFloat = verticalPadding * 2 - topPadding
    public static let horizontalPadding: CGFloat = 24
    public static let defaultWidth: CGFloat = 640
    public static let minimumWidth: CGFloat = 380
    public static let maximumWidth: CGFloat = 1100
}

/// Where the captions panel sits. One frame is remembered per screen, so a
/// laptop and an external display each keep their own place.
public struct CaptionFrameStore {
    private let defaults: UserDefaults
    private static let framesKey = "captionFrames"
    private static let lastScreenKey = "captionLastScreen"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func frame(forScreen id: String) -> CGRect? {
        guard let stored = (defaults.dictionary(forKey: Self.framesKey) as? [String: [Double]])?[id], stored.count == 4 else { return nil }
        return CGRect(x: stored[0], y: stored[1], width: stored[2], height: stored[3])
    }

    public func save(_ frame: CGRect, forScreen id: String) {
        var frames = (defaults.dictionary(forKey: Self.framesKey) as? [String: [Double]]) ?? [:]
        frames[id] = [frame.origin.x, frame.origin.y, frame.width, frame.height].map(Double.init)
        defaults.set(frames, forKey: Self.framesKey)
        defaults.set(id, forKey: Self.lastScreenKey)
    }

    /// The screen the panel was on last.
    public var lastScreen: String? { defaults.string(forKey: Self.lastScreenKey) }

    /// The first time: centered near the bottom, where subtitles are expected.
    public static func defaultFrame(in visible: CGRect, height: CGFloat, width: CGFloat = CaptionTextSize.defaultWidth) -> CGRect {
        let width = min(width, visible.width - 40)
        return CGRect(x: visible.midX - width / 2, y: visible.minY + 72, width: width, height: height)
    }

    /// Keeps a remembered frame usable: the width within limits, the height as
    /// asked, and the whole panel on the screen (the layout may have changed).
    public static func fit(_ frame: CGRect, height: CGFloat, in visible: CGRect) -> CGRect {
        let maxWidth = min(CaptionTextSize.maximumWidth, visible.width)
        let width = min(max(frame.width, CaptionTextSize.minimumWidth), maxWidth)
        // The bottom edge stays where the user put it when the height changes.
        var result = CGRect(x: frame.minX, y: frame.minY, width: width, height: height)
        result.origin.x = min(max(result.minX, visible.minX), visible.maxX - width)
        result.origin.y = min(max(result.minY, visible.minY), visible.maxY - height)
        return result
    }
}

/// Chooses which stored translation to show under a transcript: one language
/// per meeting, so a meeting translated into two languages stays readable.
public enum TranslationDisplay {
    /// The language to show: `chosen` (the one the person picked for the meeting) when there is one, even before its first
    /// translated passage; else the language with the most translated passages (the preferred one wins a tie).
    public static func chooseLanguage(from stored: [MeetingStore.StoredTranslation], preferred: String?, chosen: String? = nil) -> String? {
        if let chosen { return chosen }
        return languages(in: stored, preferred: preferred).first
    }

    /// Segment ID → translated text, in the language `chooseLanguage` picks.
    public static func texts(from stored: [MeetingStore.StoredTranslation], preferred: String?, chosen: String? = nil) -> [Int64: String] {
        guard let language = chooseLanguage(from: stored, preferred: preferred, chosen: chosen) else { return [:] }
        return Dictionary(stored.filter { $0.language == language }.map { ($0.segmentID, $0.text) }, uniquingKeysWith: { first, _ in first })
    }

    /// The languages with translated passages, the most first (the preferred one wins a tie, then by code).
    public static func languages(in stored: [MeetingStore.StoredTranslation], preferred: String? = nil) -> [String] {
        var counts: [String: Int] = [:]
        for item in stored { counts[item.language, default: 0] += 1 }
        return counts.sorted { a, b in
            if a.value != b.value { return a.value > b.value }
            if (a.key == preferred) != (b.key == preferred) { return a.key == preferred }
            return a.key < b.key
        }.map(\.key)
    }
}
