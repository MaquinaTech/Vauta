// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

/// Scenes of the live answers: the Answers card of the panel in every state, its settings, the Questions section of a meeting, the
/// Ask tab opened from a card and a search result for a kept question.
extension SnapshotScenes {
    /// The question that the past-meeting card answers, in the language being rendered.
    private static func pastQuestion(_ language: String) -> String {
        switch language {
        case "es": "¿En qué quiere centrarse Northwind en el piloto?"
        case "fr": "Sur quoi Northwind veut-il se concentrer pendant le pilote ?"
        case "de": "Worauf will sich Northwind im Pilotprojekt konzentrieren?"
        case "it": "Su cosa vuole concentrarsi Northwind nel pilota?"
        case "pt-BR": "Em que a Northwind quer se concentrar no piloto?"
        case "ja": "Northwind はパイロットで何に注目したいのですか？"
        case "ko": "노스윈드는 파일럿에서 무엇에 집중하려고 하나요?"
        case "zh-Hans": "Northwind 想在试点中重点关注什么？"
        default: "What does Northwind want to focus on in the pilot?"
        }
    }

    private static let featuredLineSpacing = 38.0

    /// Everything the scenes show, in the language being rendered.
    struct AnswerSamples {
        let thisMeeting: AutoAnswerContent
        let thisQuestion: String
        let past: AutoAnswerContent
        let pastQuestion: String
        var document: AutoAnswerContent
        let documentQuestion: String
        let unanswered: String
        let longThisMeeting: AutoAnswerContent
        /// The three kinds of source in one answer.
        var mixed: AutoAnswerContent

        @MainActor init(_ fixture: SnapshotFixture) {
            let content = fixture.content
            let thisCites = content.askClaims.map { claim in
                AutoAnswerContent.Claim(text: claim.0, cites: [.init(kind: .thisMeeting, segmentID: Int64(claim.1), meetingID: fixture.world.featuredMeetingID,
                                                                    t: Double(claim.1) * SnapshotScenes.featuredLineSpacing)])
            }
            // The app builds the prose from the claims, so a card never shows a fact that carries no citation.
            thisMeeting = AutoAnswerContent(answer: ClaimProse.join(thisCites.prefix(1).map(\.text)), claims: Array(thisCites.prefix(1)))
            longThisMeeting = AutoAnswerContent(answer: ClaimProse.join(thisCites.map(\.text)), claims: thisCites)
            thisQuestion = content.askQuestion
            let sample = content.pastMeetingSample
            // The date the sidebar shows for that meeting.
            let date = fixture.world.startDate(ofMeeting: 2).timeIntervalSince1970
            let pastCite = AutoAnswerContent.Cite(kind: .pastMeeting, segmentID: 900, meetingID: fixture.world.meetingIDs[2], t: Double(sample.lineIndex) * SnapshotScenes.featuredLineSpacing,
                                                  title: sample.title, date: date)
            past = AutoAnswerContent(answer: sample.line, claims: [.init(text: sample.line, cites: [pastCite])])
            pastQuestion = SnapshotScenes.pastQuestion(fixture.language)
            let doc = DocumentSample.forLanguage(fixture.language)
            let docCite = AutoAnswerContent.Cite(kind: .document, fileName: "Onboarding.pdf", locator: "p. 4", sourceID: 1, relPath: "Onboarding.pdf", passageID: 1, quote: doc.quote,
                                                  key: "onboarding-4", format: "pdf", place: .page(4))
            document = AutoAnswerContent(answer: doc.answer, claims: [.init(text: doc.claim, cites: [docCite])])
            documentQuestion = doc.question
            unanswered = content.unansweredQuestion
            let mixedClaims = [thisMeeting.claims[0], past.claims[0], document.claims[0]]
            mixed = AutoAnswerContent(answer: ClaimProse.join(mixedClaims.map(\.text)), claims: mixedClaims)
        }
    }

    private static func answersRecording(_ recorder: RecorderModel, _ fixture: SnapshotFixture, asker: Channel = .others) {
        let content = fixture.content
        recorder.phase = .recording
        recorder.startedAt = AppClock.now.addingTimeInterval(-754)
        recorder.elapsedSeconds = 754
        recorder.levels = [.me: 0.35, .others: 0.7]
        // The newest passages end where the clock is: the question the answer replies to was spoken at 12:03 (the time every row asks about),
        // right after the earlier lines, and the timer reads 12:34. The cited moment (2:32) is older, so it is simply not among the newest.
        let earlier = content.liveSegments
        let asked = Segment(channel: asker, start: 723, end: 731, text: content.askQuestion, isFinal: true)
        let shifted = earlier.enumerated().map { index, segment in
            Segment(channel: segment.channel, start: 723 - Double(earlier.count - index) * 12, end: 723 - Double(earlier.count - index) * 12 + 9,
                    text: segment.text, isFinal: true)
        }
        recorder.segments = (shifted + [asked]).enumerated().map { LiveSegment(id: $0.offset, segment: $0.element) }
        recorder.showTranscript = true
        recorder.livePoints = content.livePoints
        recorder.liveDecisions = content.liveDecisions
        recorder.liveTasks = content.liveTasks
        recorder.recordingLanguage = SnapshotMode.catalog?.language(matching: fixture.world.locale.identifier(.bcp47))
        recorder.recordingSource = .apps([.zoom])
        recorder.recordingApp = CallDescription(appName: content.callApp, family: .zoom, service: nil)
        recorder.answers.announce = { _ in }
    }

    private static func answerPanel(_ name: String, maxHeight: CGFloat? = 2_400, asker: Channel = .others, configure: @escaping @MainActor (LiveAnswersModel, AnswerSamples, SnapshotFixture) -> Void) -> SnapshotScene {
        panelScene("answers-\(name)", maxHeight: maxHeight) { recorder, fixture in
            answersRecording(recorder, fixture, asker: asker)
            configure(recorder.answers, AnswerSamples(fixture), fixture)
        }
    }

    private static func answerRow(_ question: String, _ content: AutoAnswerContent, t: Double = 723, channel: Channel = .others, id: UUID = UUID()) -> AnswerRow {
        AnswerRow(id: id, storedID: nil, question: question, channel: channel, t: t, content: content)
    }

    static var answerScenes: [SnapshotScene] {
        panelAnswerScenes + settingsAnswerScenes + meetingAnswerScenes
    }

    // MARK: Panel

    private static var panelAnswerScenes: [SnapshotScene] {
        [
            answerPanel("answering") { answers, s, _ in
                answers.apply(.answering(AnsweringRow(question: s.thisQuestion, channel: .others, t: 723)))
            },
            answerPanel("this-meeting") { answers, s, _ in answers.apply(.answer(answerRow(s.thisQuestion, s.thisMeeting))) },
            answerPanel("this-meeting-two-citations") { answers, s, _ in
                answers.apply(.answer(answerRow(s.thisQuestion, s.longThisMeeting)))
            },
            answerPanel("this-meeting-from-me", asker: .me) { answers, s, _ in
                answers.apply(.answer(answerRow(s.thisQuestion, s.thisMeeting, channel: .me)))
            },
            answerPanel("past-meeting") { answers, s, _ in answers.apply(.answer(answerRow(s.pastQuestion, s.past))) },
            answerPanel("mixed") { answers, s, _ in answers.apply(.answer(answerRow(s.thisQuestion, s.mixed))) },
            answerPanel("document") { answers, s, _ in answers.apply(.answer(answerRow(s.documentQuestion, s.document))) },
            answerPanel("three-rows") { answers, s, _ in
                answers.apply(.answer(answerRow(s.unanswered, s.document, t: 540)))
                answers.apply(.answer(answerRow(s.pastQuestion, s.past, t: 600)))
                answers.apply(.answer(answerRow(s.thisQuestion, s.thisMeeting, t: 723)))
            },
            answerPanel("fourth-arrives") { answers, s, _ in
                answers.apply(.answer(answerRow(s.unanswered, s.document, t: 300)))
                answers.apply(.answer(answerRow(s.documentQuestion, s.document, t: 540)))
                answers.apply(.answer(answerRow(s.pastQuestion, s.past, t: 600)))
                answers.apply(.answer(answerRow(s.thisQuestion, s.thisMeeting, t: 723)))
            },
            answerPanel("answering-and-answer") { answers, s, _ in
                answers.apply(.answer(answerRow(s.pastQuestion, s.past, t: 600)))
                answers.apply(.answering(AnsweringRow(question: s.thisQuestion, channel: .others, t: 723)))
            },
            answerPanel("late") { answers, s, _ in
                answers.apply(.answer(answerRow(s.thisQuestion, s.thisMeeting.marked(late: true))))
            },
            answerPanel("kept") { answers, s, _ in
                let row = answerRow(s.thisQuestion, s.thisMeeting)
                answers.apply(.answer(row))
                answers.toggleKeep(row.id)
            },
            answerPanel("dismissed") { answers, s, _ in
                answers.apply(.answer(answerRow(s.pastQuestion, s.past, t: 600)))
                let newest = answerRow(s.thisQuestion, s.thisMeeting, t: 723)
                answers.apply(.answer(newest))
                answers.dismiss(newest.id)
            },
            // A pause nothing else shows (no model, too warm, no source) is a card on its own, so a paused feature never looks like a working one.
            answerPanel("paused-alone") { answers, _, _ in answers.apply(.paused(.modelUnavailable)) },
            answerPanel("paused-with-answer") { answers, s, _ in
                answers.apply(.answer(answerRow(s.thisQuestion, s.thisMeeting)))
                answers.apply(.paused(.tooWarm))
            },
            answerPanel("paused-behind-with-answer") { answers, s, _ in
                answers.apply(.answer(answerRow(s.thisQuestion, s.thisMeeting)))
                answers.apply(.paused(.transcriptBehind))
            },
            // A recording whose model is Apple's, with the stored choice on: nothing of the feature is shown (decision D16). The card that
            // was there when Apple stood in for the integrated model goes through the same path the recorder uses.
            panelScene("answers-apple-recording", maxHeight: 2_400) { recorder, fixture in
                answersRecording(recorder, fixture)
                // The footer names Apple's on-device model, the one that answers in this state.
                recorder.llmStatus.chatProvider = .onDevice
                let s = AnswerSamples(fixture)
                recorder.preferences.liveAnswersBackend = { .integrated }
                recorder.preferences.liveAnswersEnabled = true
                recorder.answers.apply(.answer(answerRow(s.thisQuestion, s.thisMeeting)))
                recorder.preferences.liveAnswersBackend = { .apple }
                _ = LiveAnswersSync.settingChanged(running: recorder.preferences.liveAnswerSettings, preferences: recorder.preferences,
                                                   answers: recorder.answers) { _ in }
            },
            answerPanel("copied") { answers, s, _ in
                let row = answerRow(s.thisQuestion, s.thisMeeting)
                answers.apply(.answer(row))
                answers.copyProtected = { false }
                _ = answers.copyableText(row.id)
            },
            answerPanel("copy-protected") { answers, s, _ in
                let row = answerRow(s.thisQuestion, s.thisMeeting)
                answers.apply(.answer(row))
                answers.copyProtected = { true }
                _ = answers.copyableText(row.id)
            },
            answerPanel("long-answer") { answers, s, _ in answers.apply(.answer(answerRow(s.thisQuestion, s.longThisMeeting))) },
            answerPanel("first-run-hint") { answers, _, _ in answers.showsHint = true },
            // A 13-inch screen: the answer is the first card of the scrolling part, so it is in view on arrival; Mark a Moment and the quick note stay pinned.
            answerPanel("air-screen", maxHeight: airPanelHeight) { answers, s, _ in answers.apply(.answer(answerRow(s.thisQuestion, s.thisMeeting))) },
            answerPanel("short-screen", maxHeight: 740) { answers, s, _ in
                answers.apply(.answer(answerRow(s.pastQuestion, s.past, t: 600)))
                answers.apply(.answer(answerRow(s.thisQuestion, s.thisMeeting, t: 723)))
            },
            answerPanel("short-screen-hint", maxHeight: 740) { answers, _, _ in answers.showsHint = true },
            answerPanel("air-screen-hint", maxHeight: airPanelHeight) { answers, _, _ in answers.showsHint = true },
            // The person opened an older row to read it: a new answer waits folded at the top and does not close it.
            answerPanel("reading-older") { answers, s, _ in
                let older = answerRow(s.pastQuestion, s.past, t: 600)
                answers.apply(.answer(older))
                answers.apply(.answer(answerRow(s.unanswered, s.document, t: 650)))
                answers.toggleOpen(older.id)
                answers.apply(.answer(answerRow(s.thisQuestion, s.thisMeeting, t: 723)))
            },
            answerPanel("short-screen-mixed", maxHeight: 740) { answers, s, _ in answers.apply(.answer(answerRow(s.thisQuestion, s.mixed))) },
        ]
    }

    // MARK: Settings

    private static let answersSettingsSize = CGSize(width: 1020, height: 1180)

    private static func answersSettings(_ name: String, backend: ModelProviderSettings.Chat, lowPower: Bool = false, recording: Bool = false,
                                        configure: @escaping @MainActor (Preferences) -> Void = { _ in }) -> SnapshotScene {
        settingsScene("recording-live-answers-\(name)", .recording, size: answersSettingsSize) { recorder, fixture in
            LiveAnswersSection.lowPowerOverride = lowPower
            if recording { recorder.phase = .recording }
            var status = recorder.llmStatus
            status.chatProvider = backend
            recorder.llmStatus = status
            // The backend is pinned: the render Mac's own "While recording" setting must not decide which state is drawn.
            let kind = LiveAnswerBackendKind.current(chat: backend, liveTasks: .integrated)
            fixture.preferences.liveAnswersBackend = { kind }
            fixture.preferences.liveAnswersEnabled = true
            fixture.preferences.liveAnswersSources = .all
            fixture.preferences.liveAnswersSensitivity = .standard
            fixture.preferences.liveAnswersSpeakers = .everyone
            fixture.preferences.liveAnswersHideAnsweredAloud = true
            fixture.preferences.liveAnswersKeepQuestions = true
            configure(fixture.preferences)
        }
    }

    private static var settingsAnswerScenes: [SnapshotScene] {
        [
            answersSettings("on", backend: .integrated),
            answersSettings("on-server", backend: .server),
            answersSettings("off", backend: .integrated) { $0.liveAnswersEnabled = false },
            answersSettings("low-power", backend: .integrated, lowPower: true),
            answersSettings("while-recording", backend: .integrated, recording: true),
            answersSettings("while-recording-low-power", backend: .integrated, lowPower: true, recording: true),
            // Apple's on-device model: not offered (decision D16). The stored choice is on, and stays so.
            answersSettings("apple-not-offered", backend: .onDevice),
            answersSettings("apple-not-offered-recording", backend: .onDevice, recording: true),
            answersSettings("some-sources", backend: .integrated) { $0.liveAnswersSources = [.thisMeeting]; $0.liveAnswersSensitivity = .high; $0.liveAnswersSpeakers = .othersOnly },
        ]
    }

    // MARK: Meetings

    /// The sample answer with its document citation pointing at a real source of the store.
    private static func rebased(_ content: AutoAnswerContent, onSource source: Int64) -> AutoAnswerContent {
        AutoAnswerContent(answer: content.answer, claims: content.claims.map { claim in
            AutoAnswerContent.Claim(text: claim.text, cites: claim.cites.map { cite in
                var real = cite
                if real.kind == .document { real.sourceID = source }
                return real
            })
        }, late: content.late)
    }

    private static func seedQuestions(_ fixture: SnapshotFixture, kept: Bool = false) async -> [DetectedQuestion] {
        var s = AnswerSamples(fixture)
        let world = fixture.world
        // The document the answers cite is a source of the store, so its citation survives the check for removed sources.
        if let source = try? await world.store.addDocumentSource(kind: .file, displayName: SampleWorld.questionDocumentName,
                                                                path: "/Users/maya/Documents/\(SampleWorld.questionDocumentName)", bookmark: Data(), volumeUUID: nil) {
            s.document = rebased(s.document, onSource: source.id)
            s.mixed = rebased(s.mixed, onSource: source.id)
        }
        let ids = world.featuredSegmentIDs
        func seg(_ i: Int) -> Int64? { ids.indices.contains(i) ? ids[i] : nil }
        let meeting = world.featuredMeetingID
        let specs: [DetectedQuestion] = [
            DetectedQuestion(meetingID: meeting, segmentID: seg(4), t: 150, channel: .others, text: s.thisQuestion, rewrite: s.thisQuestion, outcome: .answered,
                             answer: s.thisMeeting, shown: true, kept: true),
            DetectedQuestion(meetingID: meeting, segmentID: seg(6), t: 230, channel: .me, text: s.pastQuestion, rewrite: s.pastQuestion, outcome: .answered,
                             answer: s.past, shown: true),
            DetectedQuestion(meetingID: meeting, segmentID: seg(7), t: 310, channel: .others, text: s.documentQuestion, rewrite: s.documentQuestion, outcome: .answered,
                             answer: s.document, shown: true, dismissed: true),
            DetectedQuestion(meetingID: meeting, segmentID: seg(9), t: 390, channel: .others, text: s.unanswered, rewrite: s.unanswered, outcome: .noAnswer),
            DetectedQuestion(meetingID: meeting, segmentID: seg(10), t: 440, channel: .others, text: s.pastQuestion, rewrite: s.pastQuestion, outcome: .rateLimited,
                             answer: s.past, shown: false),
        ]
        var out: [DetectedQuestion] = []
        for var q in specs {
            if let id = try? await world.store.addDetectedQuestion(q) { q.id = id; out.append(q) }
        }
        _ = kept
        return out
    }

    private static var meetingAnswerScenes: [SnapshotScene] {
        [
            meetingsScene("questions-collapsed") { history, fixture in
                _ = await seedQuestions(fixture)
                await featured(history, fixture)
                history.questionsExpanded = false
                history.revealQuestions = true
            },
            meetingsScene("questions") { history, fixture in
                _ = await seedQuestions(fixture)
                await featured(history, fixture)
                history.questionsExpanded = true
                history.revealQuestions = true
            },
            // A cited meeting was deleted after the answer was stored: its citation is gone and the row says so.
            meetingsScene("questions-source-removed") { history, fixture in
                let s = AnswerSamples(fixture)
                let gone = AutoAnswerContent(answer: s.past.answer, claims: [.init(text: s.past.claims[0].text, cites: [.init(kind: .pastMeeting, segmentID: 9, meetingID: 9_999, t: 38, title: "x", date: 0)])])
                _ = try? await fixture.world.store.addDetectedQuestion(DetectedQuestion(
                    meetingID: fixture.world.featuredMeetingID, segmentID: nil, t: 230, channel: .others, text: s.pastQuestion, rewrite: s.pastQuestion, outcome: .answered, answer: gone, shown: true))
                // And a document source that was removed.
                let goneDocument = AutoAnswerContent(answer: s.document.answer, claims: [.init(text: s.document.claims[0].text, cites: [.init(
                    kind: .document, fileName: "Onboarding.pdf", locator: "p. 4", sourceID: 9_999, relPath: "Onboarding.pdf", passageID: 1)])])
                _ = try? await fixture.world.store.addDetectedQuestion(DetectedQuestion(
                    meetingID: fixture.world.featuredMeetingID, segmentID: nil, t: 310, channel: .others, text: s.documentQuestion, rewrite: s.documentQuestion, outcome: .answered, answer: goneDocument, shown: true))
                await featured(history, fixture)
                history.questionsExpanded = true
                history.revealQuestions = true
            },
            // "Open in Ask" from a card: the Ask tab with the stored answer for the meeting (see `askFromCard`).
            meetingsScene("ask-from-card", prepare: askFromCard),
            // The same at the narrowest window: a long translation of the scope control must not widen the pane.
            meetingsScene("ask-from-card-narrow", size: CGSize(width: MeetingsWindow.minimumSize.width, height: 640), prepare: askFromCard),
            // A kept question in the sidebar search, and the meeting it belongs to with its Questions section open.
            meetingsScene("search-question") { history, fixture in
                let s = AnswerSamples(fixture)
                let ids = fixture.world.featuredSegmentIDs
                _ = try? await fixture.world.store.addDetectedQuestion(DetectedQuestion(
                    meetingID: fixture.world.featuredMeetingID, segmentID: ids.indices.contains(4) ? ids[4] : nil, t: 150, channel: .others, text: s.thisQuestion,
                    rewrite: s.thisQuestion, outcome: .answered, answer: s.thisMeeting, shown: true, kept: true))
                history.query = fixture.content.searchQuery
                try? await Task.sleep(for: .milliseconds(900))
            } after: { history, fixture in
                if history.knowledgeHits.isEmpty { try? await Task.sleep(for: .milliseconds(900)) }
                if let hit = history.knowledgeHits.first(where: { $0.kind == .question }) { history.openedHit = "k\(hit.id)" }
                try? await Task.sleep(for: .milliseconds(500))
            },
        ]
    }

    /// "Open in Ask" from a card: the Ask tab with the stored answer for the featured meeting, which is selected.
    @MainActor private static func askFromCard(_ history: MeetingsModel, _ fixture: SnapshotFixture) async {
        let s = AnswerSamples(fixture)
        let ids = fixture.world.featuredSegmentIDs
        // The cites point at real lines of the meeting, as the card's do.
        let claims = s.longThisMeeting.claims.map { claim in
            AutoAnswerContent.Claim(text: claim.text, cites: claim.cites.map { cite in
                var real = cite
                if let i = cite.segmentID.map(Int.init), ids.indices.contains(i) { real.segmentID = ids[i] }
                return real
            })
        }
        // What the app does: the meeting is selected and the Ask tab is open on it.
        history.selectedID = fixture.world.featuredMeetingID
        history.mode = .ask
        await history.ask.show(stored: AutoAnswerContent(answer: s.longThisMeeting.answer, claims: claims), question: s.thisQuestion,
                               thisMeeting: fixture.world.featuredMeetingID)
    }
}
#endif
