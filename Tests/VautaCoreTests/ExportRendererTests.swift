// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Golden outputs of the text export formats, including CJK and right-to-left
/// text and timestamps past one hour.
@Suite("Export · renderers")
struct ExportRendererTests {
    static let utc = TimeZone(identifier: "UTC")!

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    static let sample = MeetingExport(
        title: "Weekly sync: Q3 *launch*",
        startedAt: date(2026, 10, 6, 8),
        endedAt: date(2026, 10, 6, 9, 15),
        language: "en-US",
        attendees: ["Ana García", "李小龙", "مريم"],
        summary: "We agreed to ship.\nRisks remain.",
        topics: ["Launch", "日本語のトピック"],
        openQuestions: ["Who owns QA?"],
        decisions: [.init(text: "Ship on Friday", time: 65.2), .init(text: "ميزانية جديدة", time: 3725)],
        tasks: [.init(text: "Prepare release notes", owner: "Ana García", due: date(2026, 10, 10, 12), status: .open, time: 120),
                .init(text: "Old task", status: .done),
                .init(text: "Dropped idea", status: .dropped)],
        notes: [.init(text: "Call legal", time: 300, expansion: [
                    .init(text: "Ana asked legal to review the *contract*.", times: [295.4, 310], segmentIDs: [1, 2]),
                    .init(text: "The review is due Friday.", times: [312], segmentIDs: [3], unconfirmed: true),
                    .init(text: "Legal already reviewed it.", times: [330, 330.2], segmentIDs: [4], differs: true)]),
                .init(text: "Only my words", time: 400)],
        transcript: [.init(start: 5, end: 8.5, channel: .me, name: "Lucía", text: "Hello everyone"),
                     .init(start: 3725.25, end: 3730, channel: .others, name: "Ana García", text: "こんにちは、世界"),
                     .init(start: 4000, end: 3999, channel: .others, text: "مرحبا <بالعالم> & --> done")])

    static let options = MeetingExportOptions(locale: Locale(identifier: "en_US"), timeZone: utc)

    @Test func markdownGolden() {
        let o = Self.options
        let dateLine = MeetingExportRenderer.dateLine(Self.sample, options: o)
        let due = MeetingExportRenderer.dueDate(Self.date(2026, 10, 10, 12), options: o)
        let expected = """
            # Weekly sync: Q3 \\*launch\\*

            - **Date:** \(dateLine)
            - **Attendees:** Ana García, 李小龙, مريم

            ## Your notes

            *Expanded from the transcript*

            - (05:00) **Call legal**
              - Ana asked legal to review the \\*contract\\*. (04:55, 05:10)
              - The review is due Friday. (05:12) *Not confirmed in the transcript*
              - The transcript says: Legal already reviewed it. (05:30)
            - (06:40) **Only my words**

            ## Summary

            We agreed to ship.

            Risks remain.

            ## Topics

            - Launch
            - 日本語のトピック

            ## Decisions

            - Ship on Friday (01:05)
            - ميزانية جديدة (1:02:05)

            ## Tasks

            - [ ] Prepare release notes — Owner: Ana García · Due: \(due) (02:00)
            - [x] Old task
            - [ ] ~~Dropped idea~~

            ## Open questions

            - Who owns QA?

            ## Transcript

            **[00:05] Me:** Hello everyone

            **[1:02:05] Others:** こんにちは、世界

            **[1:06:40] Others:** مرحبا \\<بالعالم> & --> done

            """
        #expect(MeetingExportRenderer.markdown(Self.sample, options: o) == expected)
        #expect(dateLine.contains("2026") && dateLine.contains("(75 min)"))
    }

    @Test func markdownWithNamesAndWithoutTranscript() {
        var o = Self.options
        o.speakerLabels = .names
        let named = MeetingExportRenderer.markdown(Self.sample, options: o)
        #expect(named.contains("**[00:05] Lucía:** Hello everyone"))
        #expect(named.contains("**[1:02:05] Ana García:** こんにちは、世界"))
        #expect(named.contains("**[1:06:40] Others:**"), "a line without a known name keeps the channel")
        o.includeTranscript = false
        let short = MeetingExportRenderer.markdown(Self.sample, options: o)
        #expect(!short.contains("## Transcript") && short.hasSuffix("- (06:40) **Only my words**\n") == false && short.contains("- (06:40) **Only my words**"))
    }

    @Test func emptySectionsAreLeftOut() {
        let bare = MeetingExport(title: "Untitled", startedAt: Self.date(2026, 1, 1))
        let md = MeetingExportRenderer.markdown(bare, options: Self.options)
        #expect(!md.contains("##"))
        #expect(!bare.hasMinutes)
        #expect(md.hasPrefix("# Untitled\n\n- **Date:** "))
    }

    @Test func plainTextGolden() {
        let o = Self.options
        let dateLine = MeetingExportRenderer.dateLine(Self.sample, options: o)
        let due = MeetingExportRenderer.dueDate(Self.date(2026, 10, 10, 12), options: o)
        let expected = """
            Weekly sync: Q3 *launch*
            Date: \(dateLine)
            Attendees: Ana García, 李小龙, مريم

            Your notes
            Expanded from the transcript
            - (05:00) Call legal
                Ana asked legal to review the *contract*. (04:55, 05:10)
                The review is due Friday. (05:12) — Not confirmed in the transcript
                The transcript says: Legal already reviewed it. (05:30)
            - (06:40) Only my words

            Summary
            We agreed to ship.
            Risks remain.

            Topics
            - Launch
            - 日本語のトピック

            Decisions
            - Ship on Friday (01:05)
            - ميزانية جديدة (1:02:05)

            Tasks
            - [ ] Prepare release notes · Owner: Ana García · Due: \(due) (02:00)
            - [x] Old task
            - [ ] Dropped idea · Dropped

            Open questions
            - Who owns QA?

            Transcript
            [00:05] Me: Hello everyone
            [1:02:05] Others: こんにちは、世界
            [1:06:40] Others: مرحبا <بالعالم> & --> done

            """
        #expect(MeetingExportRenderer.plainText(Self.sample, options: o) == expected)
    }

    @Test func srtGolden() {
        var o = Self.options
        o.speakerLabels = .names
        let expected = """
            1
            00:00:05,000 --> 00:00:08,500
            Lucía: Hello everyone

            2
            01:02:05,250 --> 01:02:10,000
            Ana García: こんにちは、世界

            3
            01:06:40,000 --> 01:06:41,000
            Others: مرحبا <بالعالم> & → done


            """
        #expect(SubtitleRenderer.srt(Self.sample.transcript, options: o) == expected)
    }

    @Test func webVTTGolden() {
        var o = Self.options
        o.speakerLabels = .names
        let expected = """
            WEBVTT

            1
            00:00:05.000 --> 00:00:08.500
            <v Lucía>Hello everyone

            2
            01:02:05.250 --> 01:02:10.000
            <v Ana García>こんにちは、世界

            3
            01:06:40.000 --> 01:06:41.000
            <v Others>مرحبا &lt;بالعالم&gt; &amp; → done


            """
        #expect(SubtitleRenderer.webVTT(Self.sample.transcript, options: o) == expected)
    }

    @Test func subtitlesKeepEachCueOnOneLine() {
        let lines = [MeetingExport.Line(start: 1, end: 2, channel: .me, text: "first\r\nsecond\u{2028}third\u{2029}fourth")]
        #expect(SubtitleRenderer.srt(lines, options: Self.options).contains("Me: first second third fourth\n\n"))
        #expect(SubtitleRenderer.webVTT(lines, options: Self.options).contains("<v Me>first second third fourth\n\n"))
    }

    @Test func timestamps() {
        #expect(ExportTimestamp.clock(0) == "00:00")
        #expect(ExportTimestamp.clock(59.9) == "00:59")
        #expect(ExportTimestamp.clock(3599) == "59:59")
        #expect(ExportTimestamp.clock(3600) == "1:00:00")
        #expect(ExportTimestamp.clock(36_000 + 61) == "10:01:01")
        #expect(ExportTimestamp.clock(-3) == "00:00")
        #expect(ExportTimestamp.subtitle(3725.2504, separator: ",") == "01:02:05,250")
        #expect(ExportTimestamp.subtitle(0.0005, separator: ".") == "00:00:00.001")
        #expect(ExportTimestamp.subtitle(100 * 3600, separator: ".") == "100:00:00.000")
    }

    @Test func markdownEscaping() {
        #expect(Markdown.inline("# not a heading") == "\\# not a heading")
        #expect(Markdown.inline("- not a list") == "\\- not a list")
        #expect(Markdown.inline("1. not ordered") == "1\\. not ordered")
        #expect(Markdown.inline("Q3-Q4 plan") == "Q3-Q4 plan")
        #expect(Markdown.inline("snake_case and _emph_") == "snake_case and \\_emph\\_")
        #expect(Markdown.inline("[link](x) `code` <b>") == "\\[link\\](x) \\`code\\` \\<b>")
        #expect(Markdown.inline("two\nlines") == "two lines")
    }

    @Test func formatMetadata() {
        #expect(MeetingExportFormat.allCases.map(\.fileExtension) == ["md", "txt", "pdf", "srt", "vtt", "json"])
        #expect(MeetingExportFormat.pdf.render(Self.sample, options: Self.options) == nil)
        #expect(MeetingExportFormat.srt.isTranscriptOnly && !MeetingExportFormat.markdown.isTranscriptOnly)
        #expect(MeetingExportFormat.webVTT.render(Self.sample, options: Self.options)?.hasPrefix("WEBVTT\n") == true)
    }

    @Test func anExpansionTheUserRewroteIsLabelledAndOnlyLinesTheyKeptShowATime() {
        var e = Self.sample
        e.notes = [.init(text: "Call legal", time: 300, expansion: [
                       .init(text: "Ana asked legal to review the contract.", times: [295.4], segmentIDs: [1]),
                       .init(text: "My own line, no time.")], editedByUser: true)]
        let label = MeetingExportRenderer.editedByYouLabel
        let md = MeetingExportRenderer.markdown(e, options: Self.options)
        #expect(md.contains("  - Ana asked legal to review the contract. (04:55)\n  - My own line, no time. *\(label)*"), "the label sits on the text, not as an item of its own")
        #expect(!md.contains("- *\(label)*"))
        #expect(!md.contains("Expanded from the transcript"), "nothing there was only expanded by the model")
        let text = MeetingExportRenderer.plainText(e, options: Self.options)
        #expect(text.contains("    My own line, no time.\n    \(label)") && !text.contains("My own line, no time. ("))
    }
}
