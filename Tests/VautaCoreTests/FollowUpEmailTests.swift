// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The follow-up email: a template filled from stored fields, in the meeting's language, with nothing generated.
@Suite("Actions: the follow-up email")
struct FollowUpEmailTests {
    static let madrid = TimeZone(identifier: "Europe/Madrid")!
    static let start = DueDay(year: 2026, month: 10, day: 12)!.startOfDay(in: madrid).addingTimeInterval(10 * 3600)
    static let en = Locale(identifier: "en_US")

    static func input(summary: String = "", transcript: [String] = [], next: FollowUpEmailInput.NextMeeting? = nil) -> FollowUpEmailInput {
        FollowUpEmailInput(
            meetingTitle: "Weekly sync", meetingStart: start, timeZone: madrid,
            decisions: [.init(text: "Keep the C-shaped shell"), .init(text: "Budget capped at 48.200 euros", unconfirmed: true)],
            tasks: [
                .init(id: 1, text: "Send the revised budget", ownerID: 7, ownerName: "Ana", ownerEmail: "ana@example.com", dueDay: DueDay("2026-10-16")),
                .init(id: 2, text: "Book the supplier visit", ownerID: 8, ownerName: "Luis", ownerEmail: "luis@example.com"),
                .init(id: 3, text: "Share the slides", ownerID: 1, ownerName: "Maya"),
                .init(id: 4, text: "Review the contract", ownerID: 9, ownerName: "Zoe", ownerEmail: "zoe@example.com", ownerUncertain: true),
                .init(id: 5, text: "Order 400 laptops", ownerID: 7, ownerName: "Ana", ownerEmail: "ana@example.com", unconfirmed: true),
                .init(id: 6, text: "Old thing", ownerID: 8, ownerName: "Luis", status: .done),
                .init(id: 7, text: "Think about pricing"),
                .init(id: 8, text: "Dropped thing", ownerID: 8, ownerName: "Luis", status: .dropped),
            ],
            openQuestions: ["Who signs off the supplier change?"], summary: summary, transcript: transcript,
            people: [CandidateEntity(id: 7, kind: .person, name: "Ana", aliases: []), CandidateEntity(id: 8, kind: .person, name: "Luis", aliases: [])], nextMeeting: next)
    }

    static func one(_ input: FollowUpEmailInput = input(), _ options: FollowUpEmailOptions? = nil) -> FollowUpEmailDraft {
        FollowUpEmail.drafts(input, options: options ?? FollowUpEmailOptions(locale: en))[0]
    }

    // MARK: One email

    @Test func theDefaultEmailIsTheTemplateFilledFromStoredFields() {
        let draft = Self.one()
        #expect(draft.subject == "Weekly sync, Oct 12: decisions and next steps")
        #expect(draft.plainText == """
            Hello,

            Here are the decisions and next steps from our meeting on Monday, October 12.

            Decisions
            - Keep the C-shaped shell

            Next steps
            - Ana: Send the revised budget, by Friday, October 16
            - Luis: Book the supplier visit
            - Maya: Share the slides
            - Review the contract — owner to be agreed
            - Think about pricing — owner to be agreed

            Open questions
            - Who signs off the supplier change?

            Best regards,

            """)
    }

    @Test func unconfirmedItemsAreLeftOutByDefaultAndMarkedWhenIncluded() {
        let plain = Self.one().plainText
        #expect(!plain.contains("48.200") && !plain.contains("400 laptops"))
        let all = Self.one(Self.input(), FollowUpEmailOptions(locale: Self.en, includeUnconfirmed: true)).plainText
        #expect(all.contains("- Budget capped at 48.200 euros (to be confirmed)"))
        #expect(all.contains("- Ana: Order 400 laptops (to be confirmed)"))
    }

    @Test func anUncertainOwnerIsNeverWrittenAndTheTaskSaysSo() {
        let text = Self.one().plainText
        #expect(!text.contains("Zoe") && text.contains("Review the contract — owner to be agreed"))
        #expect(Self.one(Self.input(), FollowUpEmailOptions(locale: Self.en, includeUnconfirmed: true)).plainText.contains("Zoe") == false)
    }

    /// The people who receive the email cannot tell the sender's own tasks from tasks nobody owns if both are bare lines.
    @Test func theSendersOwnTasksAndTasksNobodyOwnsAreToldApart() {
        var input = Self.input()
        input.tasks = [.init(id: 1, text: "Write the release notes", ownerID: 1, ownerIsSender: true, dueDay: DueDay("2026-10-16")),
                       .init(id: 2, text: "Approve the recovery plan"),
                       .init(id: 3, text: "Call the supplier", ownerID: 9, ownerName: "Zoe", ownerUncertain: true)]
        let text = Self.one(input).plainText
        #expect(text.contains("- Me: Write the release notes, by Friday, October 16"))
        #expect(!text.contains("Me: Write the release notes — owner"))
        #expect(text.contains("- Approve the recovery plan — owner to be agreed"))
        #expect(text.contains("- Call the supplier — owner to be agreed") && !text.contains("Zoe"))
        let es = Self.one(input, FollowUpEmailOptions(locale: Locale(identifier: "es"))).plainText
        #expect(es.contains("- Yo: Write the release notes") && es.contains("- Approve the recovery plan — responsable por acordar"))
        for locale in FollowUpEmailWords.supported.map(Locale.init(identifier:)) {
            let draft = Self.one(input, FollowUpEmailOptions(locale: locale))
            #expect(FollowUpEmailTracer.violations(draft, input: input).isEmpty, "\(locale.identifier)")
        }
    }

    @Test func doneAndDroppedTasksAndSpeakerLabelsNeverAppear() {
        var input = Self.input()
        input.tasks.append(.init(id: 9, text: "Speaker task", ownerID: nil, ownerName: nil))
        let text = Self.one(input).plainText
        #expect(!text.contains("Old thing") && !text.contains("Dropped thing") && !text.contains("Speaker 2"))
        #expect(text.contains("- Speaker task — owner to be agreed\n"), "a task nobody named has no owner prefix and says so")
    }

    @Test func theSectionsAreOptionalAndEmptyOnesAreLeftOut() {
        var options = FollowUpEmailOptions(locale: Self.en, includeOpenQuestions: false)
        #expect(!Self.one(Self.input(), options).plainText.contains("Open questions"))
        options.includeOpenQuestions = true
        var input = Self.input()
        input.decisions = []
        input.openQuestions = []
        let text = Self.one(input, options).plainText
        #expect(!text.contains("Decisions") && !text.contains("Open questions") && text.contains("Next steps"))
        input.tasks = []
        #expect(Self.one(input, options).hasContent == false)
    }

    @Test func nextMeetingOnlyWhenOneWasConfirmed() {
        #expect(!Self.one().plainText.contains("Next meeting"))
        let withNext = Self.one(Self.input(next: .init(day: DueDay("2026-10-21")!, minuteOfDay: 600)), FollowUpEmailOptions(locale: Locale(identifier: "en_GB")))
        #expect(withNext.plainText.contains("Next meeting: Wednesday, 21 October, 10:00") || withNext.plainText.contains("Next meeting: Wednesday 21 October, 10:00"))
    }

    @Test func theMeetingsDateIsWrittenNeverToday() {
        var input = Self.input()
        input.meetingStart = Date.now.addingTimeInterval(-40 * 86_400)
        let text = Self.one(input).plainText.lowercased()
        #expect(!text.contains("today") && !text.contains("yesterday") && !text.contains("tomorrow") && !text.contains("last "))
        // The date is the meeting's own day in the meeting's zone: 23:30 in Madrid is still the 12th when the Mac is elsewhere.
        var late = Self.input()
        late.meetingStart = DueDay(year: 2026, month: 10, day: 12)!.startOfDay(in: Self.madrid).addingTimeInterval(23.5 * 3600)
        #expect(Self.one(late).plainText.contains("Monday, October 12"))
    }

    // MARK: One per owner

    @Test func perOwnerDraftsCarryOnlyThatOwnersTasksAndTheDecisions() {
        let drafts = FollowUpEmail.drafts(Self.input(), options: FollowUpEmailOptions(locale: Self.en, mode: .perOwner))
        #expect(drafts.map(\.ownerName) == ["Ana", "Luis", "Maya"], "named, certain owners with open confirmed tasks")
        let ana = drafts[0]
        #expect(ana.ownerEmail == "ana@example.com" && drafts[2].ownerEmail == nil)
        #expect(ana.plainText.hasPrefix("Hello Ana,\n\nHere are your next steps from our meeting on Monday, October 12:"))
        #expect(ana.plainText.contains("- Send the revised budget, by Friday, October 16"), "no owner prefix: every task is theirs")
        #expect(!ana.plainText.contains("Book the supplier visit") && !ana.plainText.contains("Think about pricing") && !ana.plainText.contains("Review the contract"))
        #expect(!ana.plainText.contains("Keep the C-shaped shell") && !ana.plainText.contains("Decisions"), "decisions are in the one-email draft, not repeated in every draft")
        #expect(Set(drafts.map(\.id)).count == 3)
        #expect(ana.subject == "Weekly sync, Oct 12: your next steps", "the subject promises no decisions")
    }

    @Test func perOwnerWithNobodyNamedGivesNoDraft() {
        var input = Self.input()
        input.tasks = [.init(id: 1, text: "Something")]
        #expect(FollowUpEmail.drafts(input, options: FollowUpEmailOptions(locale: Self.en, mode: .perOwner)).isEmpty)
    }

    // MARK: The tracer

    @Test func everyContentLineIsAStoredFieldCopiedUnchanged() {
        let input = Self.input(summary: "The team compared two suppliers.", transcript: ["We compared the two suppliers today."])
        for mode in [FollowUpEmailOptions.Mode.one, .perOwner] {
            for unconfirmed in [false, true] {
                for locale in FollowUpEmailWords.supported.map(Locale.init(identifier:)) {
                    let options = FollowUpEmailOptions(locale: locale, mode: mode, includeSummary: true, includeOpenQuestions: true, includeUnconfirmed: unconfirmed)
                    for draft in FollowUpEmail.drafts(input, options: options) {
                        #expect(FollowUpEmailTracer.violations(draft, input: input).isEmpty, "\(mode) \(locale.identifier) \(draft.id)")
                        #expect(draft.lines.contains { $0.field != nil })
                    }
                }
            }
        }
    }

    @Test func theTracerCatchesALineThatIsNotAStoredField() {
        let input = Self.input()
        var draft = Self.one(input)
        var lines = draft.lines
        let i = lines.firstIndex { $0.kind == .decision }!
        lines[i].text = "- Keep the C-shaped shell and double the budget"
        lines[i].field = "Keep the C-shaped shell and double the budget"
        draft = FollowUpEmailDraft(id: draft.id, ownerName: nil, ownerEmail: nil, subject: draft.subject, lines: lines)
        #expect(FollowUpEmailTracer.violations(draft, input: input).count == 1)
    }

    @Test func nothingFromNotesTranscriptOrAnswersReachesTheEmail() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["SECRET-TRANSCRIPT-77b we agreed on the budget", "Ana will send the budget"], at: Self.start)
        _ = try await s.addNote(m, at: 1, text: "SECRET-NOTE-9a1 call the lawyer")
        try await s.saveCard(MeetingCard(summary: "SECRET-SUMMARY-5c2 is not included by default.", topics: ["SECRET-TOPIC-3d4"], openQuestions: ["Who pays?"]), of: m)
        _ = try await s.addDecision(m, text: "Ship in June")
        let ana = try await s.saveEntity(EntityDraft(kind: .person, name: "Ana", email: "ana@example.com"))
        _ = try await s.addTask(m, text: "Send the budget", ownerID: ana)
        _ = try await s.addTask(nil, text: "A task of no meeting")
        let input = try #require(try await s.followUpEmailInput(m))
        #expect(input.tasks.map(\.text) == ["Send the budget"], "tasks with no meeting never appear")
        let draft = Self.one(input)
        for secret in ["SECRET-TRANSCRIPT-77b", "SECRET-NOTE-9a1", "SECRET-SUMMARY-5c2", "SECRET-TOPIC-3d4", "A task of no meeting"] {
            #expect(!draft.plainText.contains(secret) && !draft.subject.contains(secret), "\(secret)")
        }
        #expect(draft.plainText.contains("Ship in June") && draft.plainText.contains("Ana: Send the budget") && draft.plainText.contains("Who pays?"))
    }

    @Test func theSelfOwnerKeepsItsNameAndTheDefaultStandInGetsNoPrefix() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["We agreed on the plan"], at: Self.start)
        let selfID = try await s.selfEntity()
        _ = try await s.addTask(m, text: "Share the slides", ownerID: selfID)
        var input = try #require(try await s.followUpEmailInput(m))
        #expect(input.tasks.first?.ownerName == nil && input.tasks.first?.ownerIsSender == true, "still the default stand-in: no name, but the sender's own")
        try await s.executeForTest("UPDATE entities SET name = 'Maya' WHERE id = ?", [.integer(selfID)])
        input = try #require(try await s.followUpEmailInput(m))
        #expect(input.tasks.first?.ownerName == "Maya" && input.tasks.first?.ownerIsSender == false)
    }

    // MARK: The summary

    @Test func onlySummarySentencesThatTheTranscriptBacksAreIncluded() {
        let summary = "The team compared two suppliers. The budget is 90000 euros. The order is 400 units. Bruno owns the rollout. On Tuesday they met again. Ana leads the migration."
        let transcript = ["We compared two suppliers.", "The budget is 90000 euros.", "Ana leads the migration."]
        let input = Self.input(summary: summary, transcript: transcript)
        var people = input.people
        people.append(CandidateEntity(id: 9, kind: .person, name: "Bruno", aliases: []))
        var withPeople = input
        withPeople.people = people
        let kept = FollowUpEmailSummary.sentences(of: withPeople)
        #expect(kept == ["The team compared two suppliers.", "The budget is 90000 euros.", "Ana leads the migration."],
                "an unbacked figure, an unbacked name and a dated sentence are dropped, at most three kept")
        let options = FollowUpEmailOptions(locale: Self.en, includeSummary: true)
        #expect(Self.one(withPeople, options).plainText.contains("Summary\nThe team compared two suppliers."))
        #expect(!Self.one(withPeople).plainText.contains("Summary\n"), "off by default")
        #expect(FollowUpEmailSummary.sentences(of: Self.input(summary: summary, transcript: [])).isEmpty, "nothing to check against: nothing")
    }

    // MARK: The nine languages

    @Test func theTemplateExistsInTheNineLanguagesWithTheSamePlaceholders() throws {
        let english = FollowUpEmailWords.table["en"]!
        func placeholders(_ s: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: #"%(\d\$)?@"#)
            return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }.sorted()
        }
        #expect(Set(FollowUpEmailWords.table.keys) == Set(FollowUpEmailWords.supported))
        for (code, words) in FollowUpEmailWords.table {
            for (name, value, base) in [("subject", words.subject, english.subject), ("subjectOwner", words.subjectOwner, english.subjectOwner), ("intro", words.intro, english.intro), ("introOwner", words.introOwner, english.introOwner), ("helloOwner", words.helloOwner, english.helloOwner),
                                        ("nextMeeting", words.nextMeeting, english.nextMeeting), ("by", words.by, english.by)] {
                #expect(placeholders(value) == placeholders(base), "\(code).\(name)")
            }
            for value in [words.hello, words.summary, words.decisions, words.nextSteps, words.openQuestions, words.toConfirm, words.ownerToAgree, words.me, words.regards] {
                #expect(!value.isEmpty && !value.contains("%"), "\(code)")
            }
            #expect(words.subject != english.subject || code == "en")
            #expect(words.subjectOwner != words.subject, "\(code): a per-owner subject does not promise decisions")
        }
    }

    @Test func eachLanguageWritesItsOwnTemplateAndLeavesItemTextAlone() {
        let input = Self.input()
        for code in FollowUpEmailWords.supported {
            let locale = Locale(identifier: code)
            let draft = Self.one(input, FollowUpEmailOptions(locale: locale))
            let words = FollowUpEmailWords.table[code]!
            #expect(draft.plainText.contains(words.hello) && draft.plainText.contains(words.regards) && draft.plainText.contains(words.decisions), "\(code)")
            #expect(draft.plainText.contains("Keep the C-shaped shell") && draft.plainText.contains("Send the revised budget"), "\(code): item text is never translated")
            #expect(draft.subject.contains("Weekly sync"), "\(code)")
            if code != "en" { #expect(!draft.plainText.contains("Best regards"), "\(code)") }
        }
        let ja = Self.one(input, FollowUpEmailOptions(locale: Locale(identifier: "ja_JP"))).plainText
        #expect(ja.contains("- Ana：Send the revised budget、") && ja.contains("まで"), "Japanese punctuation")
    }

    @Test func aPlaceholderInsideItemTextIsNeverExpanded() {
        var input = Self.input()
        input.meetingTitle = "Plan %@ %1$@ 100%"
        input.decisions = [.init(text: "Spend 100% of %@ and %2$@")]
        let draft = Self.one(input)
        #expect(draft.subject.contains("Plan %@ %1$@ 100%") && draft.plainText.contains("Spend 100% of %@ and %2$@"))
    }

    @Test func theEmailLanguageIsTheMinutesThenTheTranscriptionThenTheApps() {
        let app = Locale(identifier: "fr_FR")
        #expect(FollowUpEmail.language(minutes: "de-DE", transcription: "es-ES", app: app).identifier.hasPrefix("de"))
        #expect(FollowUpEmail.language(minutes: nil, transcription: "es-ES", app: app).identifier.hasPrefix("es"))
        #expect(FollowUpEmail.language(minutes: "nl-NL", transcription: nil, app: app).identifier == "fr_FR", "a language that is not one of the nine falls to the app's")
        #expect(FollowUpEmailWords.code(of: Locale(identifier: "pt_BR")) == "pt" && FollowUpEmailWords.code(of: Locale(identifier: "zh_Hans_CN")) == "zh")
        #expect(FollowUpEmailWords.code(of: Locale(identifier: "nl_NL")) == "en")
    }

    // MARK: Judged-evaluation fixes

    @Test func aPerOwnerDraftRepeatsNeitherDecisionsNorQuestions() {
        let drafts = FollowUpEmail.drafts(Self.input(), options: FollowUpEmailOptions(locale: Self.en, mode: .perOwner))
        for draft in drafts {
            #expect(!draft.plainText.contains("Who signs off") && !draft.plainText.contains("Budget capped"))
        }
    }

    @Test func aDueDayAfterASentenceEndIsJoinedWithADash() {
        var input = Self.input()
        input.tasks = [.init(id: 1, text: "Share it.", ownerID: 7, ownerName: "Ana", dueDay: DueDay("2026-10-16"))]
        let line = Self.one(input).plainText
        #expect(line.contains("Share it. — by Friday, October 16") && !line.contains("., by"))
    }

    @Test func aDueDayYearsOffIsNotPlausible() {
        let meeting = DueDay(year: 2026, month: 10, day: 12)!
        #expect(DueDay("2026-10-12")!.isPlausible(meetingDay: meeting) && DueDay("2027-10-13")!.isPlausible(meetingDay: meeting))
        #expect(!DueDay("2005-01-03")!.isPlausible(meetingDay: meeting) && !DueDay("2026-10-11")!.isPlausible(meetingDay: meeting))
        #expect(!DueDay("2027-10-14")!.isPlausible(meetingDay: meeting) && !DueDay("2030-01-01")!.isPlausible(meetingDay: meeting))
    }

    @Test func theEmailAndItsSummaryAreHeldAndTheDetectorIsOnInThisRelease() {
        #expect(!ActionsRelease.emailDraft && ActionsRelease.followUpDetection && ActionsRelease.emailSummaryBackends.isEmpty)
    }
}
