// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import PDFKit
import Testing
import VautaCore
@testable import Vauta

/// The PDF export prints the speakers' names and the marks on what the transcript does not back, and a meeting without
/// speakers prints exactly as before.
@MainActor
@Suite("Export · PDF")
struct MinutesPDFExportTests {
    private static let options = MeetingExportOptions(speakerLabels: .names, locale: Locale(identifier: "en_US"),
                                                      timeZone: TimeZone(identifier: "UTC")!)
    private static let started = Date(timeIntervalSince1970: 1_791_273_600)

    private static func export(speakers: Bool) -> MeetingExport {
        let ana = speakers ? SpeakerTag(id: 11, ordinal: 2, name: "Ana", confidence: 0.92) : nil
        let guess = speakers ? SpeakerTag(id: 12, ordinal: 3, confidence: 0.3) : nil
        var e = MeetingExport(title: "Sync", startedAt: started, summary: "We agreed.",
                              decisions: [.init(text: "Ship on Friday", time: 10, unconfirmed: true)],
                              tasks: [.init(text: "Send the deck", owner: "Ana", status: .open, time: 20, unconfirmed: true, ownerUncertain: true)],
                              transcript: [.init(start: 3, end: 5, channel: .others, text: "Hi everyone", speaker: ana),
                                           .init(start: 7, end: 9, channel: .others, text: "Maybe", speaker: guess)])
        if speakers {
            e.speakers = [.init(id: 11, channel: .others, label: "Speaker 2", name: "Ana", talkSeconds: 2),
                          .init(id: 12, channel: .others, label: "Speaker 3", talkSeconds: 2)]
        }
        return e
    }

    /// The text of the PDF as a reader would select it.
    private static func pdfText(_ e: MeetingExport) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-pdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try MinutesPDFRenderer.write(e, options: options, to: url)
        return try #require(PDFDocument(url: url)?.string)
    }

    @Test func theSpeakersNamesAndTheMarksAreInThePDF() throws {
        let text = try Self.pdfText(Self.export(speakers: true))
        #expect(text.contains("Ana: Hi everyone"))
        #expect(text.contains(String(localized: "Speaker 3 (not sure)") + ": Maybe"))
        let e = Self.export(speakers: true)
        let note = MeetingExportRenderer.decisionNote(e.decisions[0]).trimmingCharacters(in: CharacterSet(charactersIn: " —"))
        #expect(!note.isEmpty && text.contains(note), "the decision says it is not confirmed")
        let details = MeetingExportRenderer.taskDetails(e.tasks[0], options: Self.options)
        #expect(details.count == 3, "owner, owner not confirmed, not confirmed")
        for detail in details { #expect(text.contains(detail), "\(detail)") }
    }

    @Test func aMeetingWithoutSpeakersPrintsThePlainChannels() throws {
        let attributed = MinutesPDFRenderer.attributed(Self.export(speakers: false), options: Self.options).string
        #expect(attributed.contains("Others: Hi everyone") && attributed.contains("Others: Maybe"))
        #expect(!attributed.contains("Ana: Hi") && !attributed.contains("(not sure)"))
        // Only the marks of the minutes remain, and they are in the file.
        #expect(try Self.pdfText(Self.export(speakers: false)).contains("Others: Hi everyone"))
    }

    @Test func aNameWithALineBreakStaysOnItsLine() {
        var e = Self.export(speakers: true)
        e.transcript[0].speaker?.name = "Ana\nBea"
        let text = MinutesPDFRenderer.attributed(e, options: Self.options).string
        #expect(text.contains("Ana Bea: Hi everyone"))
    }

    @Test func theUsersNotesComeFirstWithTheirExpansionUnderThem() throws {
        var e = Self.export(speakers: false)
        e.notes = [.init(text: "Q3 budget +10%", time: 312, expansion: [
            .init(text: "Ana proposed raising the Q3 budget by 10%.", times: [310]),
            .init(text: "Luis agreed if hiring waits.", times: [331], unconfirmed: true),
            .init(text: "Der Haushalt für das dritte Quartal wurde bereits von der Finanzabteilung freigegeben und alles Weitere folgt später.", times: [350], differs: true)])]
        let text = try Self.pdfText(e)
        let your = String(localized: "Your notes", comment: "Exported minutes: section title for the notes the user typed themselves; it comes first")
        let yours = try #require(text.range(of: your)), summary = try #require(text.range(of: String(localized: "Summary")))
        #expect(yours.lowerBound < summary.lowerBound, "the user's document comes first")
        #expect(text.contains("Q3 budget +10%") && text.contains("Ana proposed raising the Q3 budget by 10%. (05:10)"))
        #expect(text.contains(MeetingExportRenderer.unconfirmedLabel))
        #expect(text.contains(MeetingExportRenderer.sentenceText(e.notes[0].expansion[2]).prefix(40)), "a long sentence wraps, never clips")
        // The user's words are bold, the expansion is not.
        let attributed = MinutesPDFRenderer.attributed(e, options: Self.options)
        let wordsAt = (attributed.string as NSString).range(of: "Q3 budget +10%")
        let font = try #require(attributed.attribute(.font, at: wordsAt.location, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func aRewrittenExpansionSaysSoInThePDFAndKeepsNoTimeOnTheUsersLines() throws {
        var e = Self.export(speakers: false)
        e.notes = [.init(text: "Call legal", time: 300, expansion: [.init(text: "Rewritten by the user."),
                                                                      .init(text: "Kept from the model.", times: [295], segmentIDs: [1])],
                         editedByUser: true)]
        let text = try Self.pdfText(e)
        #expect(text.contains(MeetingExportRenderer.editedByYouLabel))
        #expect(text.contains("Rewritten by the user.") && !text.contains("Rewritten by the user. ("))
        #expect(!text.contains(String(localized: "Expanded from the transcript", comment: "Exported minutes: line under “Your notes” saying that the indented sentences under each note were written by the model from the transcript, while the note itself is the user’s own words")))
    }
}
