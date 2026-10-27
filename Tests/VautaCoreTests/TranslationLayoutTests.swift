// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreGraphics
import Foundation
import Testing
@testable import VautaCore

@Suite("Live Translation: captions layout and display")
struct TranslationLayoutTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func textSizesGrowAndTheOriginalLineAddsHeight() {
        let heights = CaptionTextSize.allCases.map { $0.panelHeight(showOriginal: false) }
        #expect(heights == heights.sorted() && Set(heights).count == 4)
        for size in CaptionTextSize.allCases {
            #expect(size.panelHeight(showOriginal: true) > size.panelHeight(showOriginal: false))
            #expect(size.originalPoints < size.points)
        }
        #expect(CaptionTextSize.medium.points == 22, "medium is the default and readable at a glance")
    }

    @Test func theHeightHoldsThreeCaptionsTheirGapsOriginalLinesAndEqualPadding() {
        for size in CaptionTextSize.allCases {
            let captions = size.lineHeight * 3 + CaptionTextSize.rowSpacing * 2
            let padding = CaptionTextSize.verticalPadding * 2
            #expect(size.panelHeight(showOriginal: false) == captions + padding)
            let originals = (size.originalLineHeight + CaptionTextSize.originalSpacing) * 3
            let spacedCaptions = size.lineHeight * 3 + CaptionTextSize.rowSpacing(showOriginal: true) * 2
            #expect(size.panelHeight(showOriginal: true) == spacedCaptions + originals + padding,
                    "three captions with an original line each must not need more room than the panel has")
            #expect(size.originalPoints >= 13, "the original line stays readable")
        }
    }

    @Test func theDefaultFrameIsCenteredNearTheBottom() {
        let frame = CaptionFrameStore.defaultFrame(in: screen, height: 120)
        #expect(frame.midX == screen.midX)
        #expect(frame.minY == 72 && frame.height == 120)
        let narrow = CaptionFrameStore.defaultFrame(in: CGRect(x: 0, y: 0, width: 500, height: 600), height: 120)
        #expect(narrow.width <= 460)
    }

    @Test func aRememberedFrameIsKeptInsideTheScreenWithLimitsOnTheWidth() {
        let off = CGRect(x: 2000, y: -300, width: 5000, height: 50)
        let fitted = CaptionFrameStore.fit(off, height: 130, in: screen)
        #expect(screen.contains(fitted))
        #expect(fitted.width == CaptionTextSize.maximumWidth && fitted.height == 130)
        let tiny = CaptionFrameStore.fit(CGRect(x: 100, y: 100, width: 50, height: 130), height: 130, in: screen)
        #expect(tiny.width == CaptionTextSize.minimumWidth)
        let ok = CGRect(x: 200, y: 300, width: 700, height: 130)
        #expect(CaptionFrameStore.fit(ok, height: 130, in: screen) == ok)
    }

    @Test func framesAreRememberedPerScreen() {
        let suite = "local.vauta.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CaptionFrameStore(defaults: defaults)
        #expect(store.frame(forScreen: "A") == nil && store.lastScreen == nil)
        store.save(CGRect(x: 10, y: 20, width: 600, height: 120), forScreen: "A")
        store.save(CGRect(x: 30, y: 40, width: 800, height: 120), forScreen: "B")
        #expect(store.frame(forScreen: "A") == CGRect(x: 10, y: 20, width: 600, height: 120))
        #expect(store.frame(forScreen: "B")?.width == 800)
        #expect(store.lastScreen == "B")
    }

    @Test func theTranscriptShowsOneLanguagePerMeeting() {
        func stored(_ id: Int64, _ lang: String) -> MeetingStore.StoredTranslation {
            .init(segmentID: id, language: lang, text: "\(lang)\(id)")
        }
        let items = [stored(1, "es"), stored(2, "es"), stored(2, "fr"), stored(3, "fr")]
        #expect(TranslationDisplay.chooseLanguage(from: items, preferred: nil) != nil)
        #expect(TranslationDisplay.chooseLanguage(from: items, preferred: "fr") == "fr", "a tie goes to the preferred language")
        #expect(TranslationDisplay.chooseLanguage(from: items, preferred: "es") == "es")
        #expect(TranslationDisplay.texts(from: items + [stored(4, "es")], preferred: "fr") == [1: "es1", 2: "es2", 4: "es4"],
                "the language with the most passages wins over the preference")
        #expect(TranslationDisplay.texts(from: [], preferred: "es").isEmpty)
    }

    @Test func theCommandLineAcceptsTheBenchOptionsOnlyInTheDiagnosticsBuild() throws {
        #if VAUTA_DIAGNOSTICS
        let parsed = try CommandInvocation(parsing: ["translate-bench", "--from", "en", "--to", "es", "--count", "4"])
        #expect(parsed.values["--to"] == "es")
        #else
        #expect(throws: CommandInvocation.ParseError.self) { try CommandInvocation(parsing: ["translate-bench", "--from", "en"]) }
        #endif
    }
}
