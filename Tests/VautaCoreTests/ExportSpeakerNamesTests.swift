// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Speaker names in the exports, the JSON document, and that no voice fingerprint or embedding ever leaves.
@Suite("Export with speakers")
struct ExportSpeakerNamesTests {
    private static let namesOptions = MeetingExportOptions(speakerLabels: .names, locale: Locale(identifier: "en_US"), timeZone: ExportRendererTests.utc)

    private static func export() -> MeetingExport {
        let ana = SpeakerTag(id: 11, ordinal: 2, name: "Ana", confidence: 0.92)
        let unnamed = SpeakerTag(id: 12, ordinal: 3, confidence: 0.9)
        let guess = SpeakerTag(id: 11, ordinal: 2, name: "Ana", confidence: 0.4)
        let me = SpeakerTag(id: 10, ordinal: 1, confidence: 0.99)
        var e = MeetingExport(title: "Sync", startedAt: ExportRendererTests.date(2026, 10, 6, 8), transcript: [
            .init(start: 1, end: 3, channel: .me, name: "Lucía", text: "Hello", speaker: me),
            .init(start: 3, end: 5, channel: .others, name: "Ana, Bea", text: "Hi <all> & welcome", speaker: ana),
            .init(start: 5, end: 7, channel: .others, name: "Ana, Bea", text: "Morning", speaker: unnamed),
            .init(start: 7, end: 9, channel: .others, name: "Ana, Bea", text: "Maybe", speaker: guess)])
        e.speakers = [.init(id: 10, channel: .me, label: "Me", talkSeconds: 2), .init(id: 11, channel: .others, label: "Speaker 2", name: "Ana", talkSeconds: 4),
                      .init(id: 12, channel: .others, label: "Speaker 3", talkSeconds: 2)]
        return e
    }

    @Test func namesAreWrittenInEveryTextFormat() {
        let e = Self.export(), o = Self.namesOptions
        let who = e.transcript.map(o.speaker(of:))
        #expect(who == ["Lucía", "Ana", MeetingSpeaker.defaultLabel(channel: .others, ordinal: 3),
                        String(localized: "Ana (not sure)")])
        let srt = SubtitleRenderer.srt(e.transcript, options: o)
        #expect(srt.contains("\nAna: Hi <all> & welcome\n") && srt.contains("\nSpeaker 3: Morning\n"))
        let vtt = SubtitleRenderer.webVTT(e.transcript, options: o)
        #expect(vtt.contains("<v Ana>Hi &lt;all&gt; &amp; welcome") && vtt.contains("<v Speaker 3>Morning"))
        let md = MeetingExportRenderer.markdown(e, options: o)
        #expect(md.contains("**[00:03] Ana:** Hi") && md.contains("**[00:07] Ana (not sure):**"))
        #expect(MeetingExportRenderer.plainText(e, options: o).contains("[00:05] Speaker 3: Morning"))
    }

    @Test func aNameCannotBreakACueOrAVoiceSpan() {
        var e = Self.export()
        e.transcript[1].speaker?.name = "Ana>\n<b>Bea</b>"
        let vtt = SubtitleRenderer.webVTT(e.transcript, options: Self.namesOptions)
        #expect(!vtt.contains("<b>") && vtt.contains("<v Ana&gt; &lt;b&gt;Bea&lt;/b&gt;>"))
    }

    @Test func aNameCannotBreakAnSRTCueOrAPlainTextLine() {
        var e = Self.export()
        e.transcript[1].speaker?.name = "Ana\nBea --> 00:00:09"
        let srt = SubtitleRenderer.srt(e.transcript, options: Self.namesOptions)
        #expect(srt.contains("Ana Bea → 00:00:09: Hi <all> & welcome\n"))
        #expect(srt.components(separatedBy: "-->").count == e.transcript.count + 1, "one arrow per cue")
        let text = MeetingExportRenderer.plainText(e, options: Self.namesOptions)
        #expect(text.contains("[00:03] Ana Bea --> 00:00:09: Hi <all> & welcome\n"), "a name stays on its line in plain text")
    }

    @Test func aCrosstalkLineIsNotPrintedAsFact() throws {
        var e = Self.export()
        e.transcript[1].speaker?.overlap = true
        let o = Self.namesOptions
        #expect(o.speaker(of: e.transcript[1]) == String(localized: "Ana (not sure)"))
        #expect(MeetingExportRenderer.markdown(e, options: o).contains("**[00:03] Ana (not sure):**"))
        #expect(SubtitleRenderer.srt(e.transcript, options: o).contains("\nAna (not sure): Hi"))
        // The JSON keeps the name clean and says it with data.
        let doc = try #require(JSONSerialization.jsonObject(with: Data(try MeetingExportJSON.encode(e, options: o).utf8)) as? [String: Any])
        let line = try #require((doc["transcript"] as? [[String: Any]])?[1])
        #expect(line["speaker"] as? String == "Ana" && line["overlap"] as? Bool == true)
    }

    @Test func theChannelOptionAndMeetingsWithoutSpeakersAreUnchanged() {
        let e = Self.export()
        var channels = Self.namesOptions
        channels.speakerLabels = .channels
        #expect(e.transcript.map(channels.speaker(of:)) == [Channel.me.displayName] + Array(repeating: Channel.others.displayName, count: 3))
        // Without speaker data, "names" is what it always was: the channel-level name.
        var plain = e
        plain.speakers = []
        for i in plain.transcript.indices { plain.transcript[i].speaker = nil }
        #expect(plain.transcript.map(Self.namesOptions.speaker(of:)) == ["Lucía", "Ana, Bea", "Ana, Bea", "Ana, Bea"])
        let srt = SubtitleRenderer.srt(plain.transcript, options: Self.namesOptions)
        #expect(srt.contains("Ana, Bea: Hi <all> & welcome"))
    }

    /// The v1 document: every key the header comment promises, with its type, and nothing that is not in it.
    @Test func theJSONDocumentMatchesItsDescription() throws {
        let e = Self.export()
        let json = try MeetingExportJSON.encode(e, options: Self.namesOptions)
        let doc = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(doc["format"] as? String == "vauta.meeting" && doc["version"] as? Int == 1)
        let topKeys: Set = ["format", "version", "title", "startedAt", "endedAt", "durationSeconds", "language", "participantsInformedAt", "attendees",
                            "summary", "topics", "openQuestions", "decisions", "tasks", "notes", "transcript", "speakers"]
        #expect(Set(doc.keys) == topKeys)
        let speakers = try #require(doc["speakers"] as? [[String: Any]])
        for s in speakers {
            #expect(Set(s.keys) == ["id", "label", "name", "channel", "talkSeconds"])
            #expect(s["id"] is Int && s["label"] is String && (s["name"] is String || s["name"] is NSNull))
            #expect(["me", "others"].contains(s["channel"] as? String ?? "") && s["talkSeconds"] is Double || s["talkSeconds"] is Int)
        }
        #expect(speakers.map { $0["label"] as? String } == ["Me", "Speaker 2", "Speaker 3"], "labels are English whatever the UI language")
        let lines = try #require(doc["transcript"] as? [[String: Any]])
        let ids = Set(speakers.compactMap { $0["id"] as? Int })
        let lineKeys: Set = ["start", "end", "channel", "speaker", "name", "text", "speakerId", "confidence", "overlap"]
        for line in lines {
            #expect(Set(line.keys).isSubset(of: lineKeys.union(["translation"])) && lineKeys.isSubset(of: Set(line.keys)))
            #expect(ids.contains(line["speakerId"] as? Int ?? -1), "every line points at a listed speaker")
            let confidence = try #require(line["confidence"] as? Double)
            #expect((0...1).contains(confidence))
        }
        #expect(lines[1]["speaker"] as? String == "Ana")
        // Without the transcript no speaker leaves.
        var noTranscript = Self.namesOptions
        noTranscript.includeTranscript = false
        let bare = try #require(JSONSerialization.jsonObject(with: Data(try MeetingExportJSON.encode(e, options: noTranscript).utf8)) as? [String: Any])
        #expect(bare["speakers"] == nil && bare["transcript"] is NSNull)
    }

    @Test func nothingElseIsInTheExportValue() {
        // The export carries text, names, numbers and dates: no Data, no vectors.
        func scan(_ value: Any, _ path: String = "") -> [String] {
            if ["Data", "Array<Float>", "Array<UInt8>", "Array<Float16>", "Array<Double>"].contains(String(describing: type(of: value))) { return ["\(path): \(type(of: value))"] }
            return Mirror(reflecting: value).children.flatMap { scan($0.value, path + "." + ($0.label ?? "?")) }
        }
        let found = scan(Self.export())
        #expect(found.isEmpty, "\(found)")
    }

    // MARK: From the store

    @Test func noFormatCarriesAVoiceFingerprintOrAChunkVector() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let ana = try await store.saveEntity(EntityDraft(kind: .person, name: "Ana"))
        _ = try await store.assignSpeaker(try await m.speaker(.others, 1).id, toEntity: ana)
        let voice = Data((0..<96).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        try await store.addVoiceProfile(entityID: ana, modelID: "wespeaker-x", embedding: voice, consentRecordedAt: .now, sourceMeetingID: m.meeting)
        let chunk = Data((0..<48).map { UInt8(truncatingIfNeeded: $0 &* 5 &+ 9) })
        try await store.replaceChunks(m.meeting, [(0, 10, chunk, 0.5, "k")], space: EmbeddingSpace(model: "embed-model-z", dimensions: 48))

        let export = try #require(try await store.meetingExport(m.meeting))
        var outputs: [String] = []
        for format in MeetingExportFormat.allCases {
            for options in [Self.namesOptions, MeetingExportOptions(speakerLabels: .channels)] {
                if let text = format.render(export, options: options) { outputs.append(text) }
            }
        }
        #expect(outputs.count == 10)
        let needles = [voice.base64EncodedString(), chunk.base64EncodedString(), voice.map { String(format: "%02x", $0) }.joined(),
                       chunk.map { String(format: "%02x", $0) }.joined(), "wespeaker-x", "embed-model-z", "embedding", "text_key"]
        for text in outputs { for needle in needles { #expect(!text.contains(needle), "\(needle.prefix(10))") } }
        // The names of a named speaker are in the subtitles.
        #expect(outputs.contains { $0.contains("Ana: Thanks for joining") })
    }

    @Test func aMeetingWithoutSpeakersExportsByteForByteAsBefore() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await store.startMeeting(at: ExportRendererTests.date(2026, 10, 6, 8))
        try await store.append(segment(.me, 0, "Good morning"), to: id)
        try await store.append(segment(.others, 3, "Hello, shall we start"), to: id)
        try await store.endMeeting(id, at: ExportRendererTests.date(2026, 10, 6, 8, 1))
        var export = try #require(try await store.meetingExport(id))
        export.title = "Weekly sync"   // the default title depends on the time zone of the machine
        #expect(export.speakers.isEmpty && export.transcript.allSatisfy { $0.speaker == nil })
        let o = Self.namesOptions
        let dateLine = "Tuesday, October 6, 2026 at 8:00\u{202F}AM – 8:01\u{202F}AM (1 min)"
        #expect(SubtitleRenderer.srt(export.transcript, options: o) == """
            1
            00:00:00,000 --> 00:00:01,000
            Me: Good morning

            2
            00:00:03,000 --> 00:00:04,000
            Others: Hello, shall we start


            """)
        let json = try MeetingExportJSON.encode(export, options: o)
        for key in ["speakers", "speakerId", "confidence", "overlap", "unconfirmed", "ownerUncertain"] { #expect(!json.contains(key)) }
        #expect(MeetingExportRenderer.markdown(export, options: o) == """
            # Weekly sync

            - **Date:** \(dateLine)

            ## Transcript

            **[00:00] Me:** Good morning

            **[00:03] Others:** Hello, shall we start

            """)
        #expect(MeetingExportRenderer.plainText(export, options: o) == """
            Weekly sync
            Date: \(dateLine)

            Transcript
            [00:00] Me: Good morning
            [00:03] Others: Hello, shall we start

            """)
        #expect(SubtitleRenderer.webVTT(export.transcript, options: o) == """
            WEBVTT

            1
            00:00:00.000 --> 00:00:01.000
            <v Me>Good morning

            2
            00:00:03.000 --> 00:00:04.000
            <v Others>Hello, shall we start


            """)
        let expectedJSON = """
            {
              "attendees" : [

              ],
              "decisions" : [

              ],
              "durationSeconds" : 60,
              "endedAt" : "2026-10-06T08:01:00Z",
              "format" : "vauta.meeting",
              "language" : null,
              "notes" : [

              ],
              "openQuestions" : [

              ],
              "participantsInformedAt" : null,
              "startedAt" : "2026-10-06T08:00:00Z",
              "summary" : "",
              "tasks" : [

              ],
              "title" : "Weekly sync",
              "topics" : [

              ],
              "transcript" : [
                {
                  "channel" : "me",
                  "end" : 1,
                  "name" : null,
                  "speaker" : "Me",
                  "start" : 0,
                  "text" : "Good morning"
                },
                {
                  "channel" : "others",
                  "end" : 4,
                  "name" : null,
                  "speaker" : "Others",
                  "start" : 3,
                  "text" : "Hello, shall we start"
                }
              ],
              "version" : 1
            }

            """
        #expect(json == expectedJSON)
    }

    @Test func decisionsAndTasksWithoutMarksExportByteForByteAsBefore() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await store.startMeeting(at: ExportRendererTests.date(2026, 10, 6, 8))
        try await store.append(segment(.me, 0, "Good morning"), to: id)
        try await store.endMeeting(id, at: ExportRendererTests.date(2026, 10, 6, 8, 1))
        let ana = try await store.saveEntity(EntityDraft(kind: .person, name: "Ana"))
        try await store.addDecision(id, text: "Ship on Thursday", t: 5, source: "llm")
        try await store.addDecision(id, text: "Keep the plan", t: nil)
        try await store.addTask(id, text: "Send the report", ownerID: ana, due: ExportRendererTests.date(2026, 10, 9, 12), t: 12, source: "llm")
        try await store.addTask(id, text: "Book the room", t: 20, source: "llm")
        try await store.addTask(id, text: "Call the client", ownerID: ana)
        var export = try #require(try await store.meetingExport(id))
        export.title = "Weekly sync"
        let o = Self.namesOptions
        let dateLine = "Tuesday, October 6, 2026 at 8:00\u{202F}AM – 8:01\u{202F}AM (1 min)"
        #expect(MeetingExportRenderer.markdown(export, options: o) == """
            # Weekly sync

            - **Date:** \(dateLine)

            ## Decisions

            - Ship on Thursday (00:05)
            - Keep the plan

            ## Tasks

            - [ ] Send the report — Owner: Ana · Due: Oct 9, 2026 (00:12)
            - [ ] Book the room (00:20)
            - [ ] Call the client — Owner: Ana

            ## Transcript

            **[00:00] Me:** Good morning

            """)
        #expect(MeetingExportRenderer.plainText(export, options: o) == """
            Weekly sync
            Date: \(dateLine)

            Decisions
            - Ship on Thursday (00:05)
            - Keep the plan

            Tasks
            - [ ] Send the report · Owner: Ana · Due: Oct 9, 2026 (00:12)
            - [ ] Book the room (00:20)
            - [ ] Call the client · Owner: Ana

            Transcript
            [00:00] Me: Good morning

            """)
        let json = try MeetingExportJSON.encode(export, options: o)
        for key in ["unconfirmed", "ownerUncertain", "speakers", "speakerId"] { #expect(!json.contains(key)) }
        #expect(json.contains(#""text" : "Send the report""#) && json.contains(#""due" : "2026-10-09""#))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let tasks = try #require(object["tasks"] as? [[String: Any]])
        #expect(tasks.allSatisfy { Set($0.keys) == ["text", "owner", "due", "status", "time"] }, "an unmarked task has the keys of version 1")
        let decisions = try #require(object["decisions"] as? [[String: Any]])
        #expect(decisions.allSatisfy { Set($0.keys) == ["text", "time"] })
    }

    // MARK: What the transcript does not back

    @Test func unconfirmedItemsAreMarkedInTheExportsAndOthersAreUntouched() throws {
        let o = Self.namesOptions
        var e = MeetingExport(title: "Sync", startedAt: ExportRendererTests.date(2026, 10, 6, 8))
        e.decisions = [.init(text: "Raise the budget", time: 5, unconfirmed: true), .init(text: "Ship Thursday", time: 9)]
        e.tasks = [.init(text: "Send the report", owner: "Ana", time: 12, unconfirmed: true, ownerUncertain: true),
                   .init(text: "Book the room", owner: "Bea", time: 20)]
        let note = "Not confirmed in the transcript"
        let md = MeetingExportRenderer.markdown(e, options: o)
        #expect(md.contains("- Raise the budget — \(note) (00:05)") && md.contains("- Ship Thursday (00:09)"))
        #expect(md.contains("Send the report — Owner: Ana · Owner not confirmed · \(note) (00:12)"))
        #expect(md.contains("- [ ] Book the room — Owner: Bea (00:20)"))
        let text = MeetingExportRenderer.plainText(e, options: o)
        #expect(text.contains("- Raise the budget — \(note) (00:05)") && text.contains("Owner not confirmed"))
        let json = try MeetingExportJSON.encode(e, options: o)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let decisions = try #require(object["decisions"] as? [[String: Any]])
        #expect(decisions[0]["unconfirmed"] as? Bool == true && decisions[1]["unconfirmed"] == nil)
        let tasks = try #require(object["tasks"] as? [[String: Any]])
        #expect(tasks[0]["unconfirmed"] as? Bool == true && tasks[0]["ownerUncertain"] as? Bool == true)
        #expect(tasks[1]["unconfirmed"] == nil && tasks[1]["ownerUncertain"] == nil)
    }

    @Test func theJSONSpeakerStringNeverCarriesTheLocalizedDoubtNote() throws {
        let e = Self.export()
        let json = try MeetingExportJSON.encode(e, options: Self.namesOptions)
        #expect(!json.contains(String(localized: "Ana (not sure)")))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let lines = try #require(object["transcript"] as? [[String: Any]])
        #expect(lines[3]["speaker"] as? String == "Ana" && lines[3]["confidence"] as? Double == 0.4)
        // The text formats still say it.
        #expect(MeetingExportRenderer.markdown(e, options: Self.namesOptions).contains("Ana (not sure)"))
    }
}
