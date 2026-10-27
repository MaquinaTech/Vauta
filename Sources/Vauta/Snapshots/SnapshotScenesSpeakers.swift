// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

/// The speaker scenes: the transcript and the Summary of a meeting with separated speakers (and the stress cases),
/// a meeting with separation off, search and Ask results with names, and each page of the speaker popover.
/// A popover is a window of its own in the app, so it is drawn here as a card, like a sheet.
extension SnapshotScenes {
    private static let tallMeetings = CGSize(width: 1040, height: 900)

    private static func openTranscript(_ history: MeetingsModel, _ meeting: Int64) async {
        history.selectedID = meeting
        await history.loadDetail()
        history.tab = .transcript
    }

    static var speakers: [SnapshotScene] {
        windowScenes + popoverScenes + [switchConfirmation]
    }

    /// The confirmation of "Don't separate speakers in this meeting". The system draws it in a window of its own, so the scene
    /// draws the same words (`SpeakerSeparationConfirmation`) in a card shaped like it, to review the copy and how it wraps.
    private static var switchConfirmation: SnapshotScene {
        SnapshotScene(name: "speaker-switch-confirm", size: CGSize(width: 420, height: 220), fitHeight: true, isSheet: true) { _ in
            .init(view: AnyView(ConfirmationPreview().background(Color(nsColor: .windowBackgroundColor))))
        }
    }

    private struct ConfirmationPreview: View {
        var body: some View {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 8) {
                    SpeakerSeparationConfirmation.title.font(.headline).fixedSize(horizontal: false, vertical: true)
                    SpeakerSeparationConfirmation.message(speakers: 4).font(.callout).fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 6) {
                        SpeakerSeparationConfirmation.action
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.white)
                        Text("Cancel")
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(.top, 8)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
    }

    // MARK: In the Meetings window

    private static var windowScenes: [SnapshotScene] {
        [
            // Four speakers: the user, Speaker 1 (not named, one line said over somebody), Daniel (named, one line the
            // diarizer is unsure about) and Priya (named). Maya is on the calendar and in nobody's place.
            meetingsAfterScene("speakers-transcript", size: tallMeetings, prepare: { history, fixture in
                try? await fixture.world.seedFeaturedSpeakers()
                await history.reload()
                await openTranscript(history, fixture.world.featuredMeetingID)
            }) { _, _ in },
            meetingsAfterScene("speakers-transcript-highlight", size: tallMeetings, prepare: { history, fixture in
                try? await fixture.world.seedFeaturedSpeakers()
                await history.reload()
                await openTranscript(history, fixture.world.featuredMeetingID)
                history.highlighted = fixture.world.featuredSegmentIDs[8]
            }) { _, _ in },
            meetingsAfterScene("speakers-summary", size: CGSize(width: 1040, height: 760), prepare: { history, fixture in
                try? await fixture.world.seedFeaturedSpeakers()
                await history.reload()
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
            }) { _, _ in },
            // Nine voices and a name that does not fit the column.
            meetingsAfterScene("speakers-stress-transcript", size: tallMeetings, prepare: { history, fixture in
                let id = (try? await fixture.world.seedSpeakerStress()) ?? fixture.world.featuredMeetingID
                await history.reload()
                await openTranscript(history, id)
            }) { _, _ in },
            meetingsAfterScene("speakers-stress-summary", size: CGSize(width: 1040, height: 900), prepare: { history, fixture in
                let id = (try? await fixture.world.seedSpeakerStress()) ?? fixture.world.featuredMeetingID
                await history.reload()
                history.selectedID = id
                await history.loadDetail()
            }) { _, _ in },
            // Separate speakers in this meeting was off from the start: the transcript reads as before speakers,
            // and the note under the switch says why and that checking it cannot separate them later.
            meetingsAfterScene("speakers-off", prepare: { history, fixture in
                let id = (try? await fixture.world.seedSpeakersOffMeeting()) ?? fixture.world.featuredMeetingID
                await history.reload()
                await openTranscript(history, id)
            }) { _, _ in },
            // Right after the user removed the speakers: the note adds that Undo brings them back.
            meetingsAfterScene("speakers-off-now", prepare: { history, fixture in
                try? await fixture.world.seedFeaturedSpeakers()
                await history.reload()
                await openTranscript(history, fixture.world.featuredMeetingID)
                await history.setSpeakerSeparation(off: true)
            }) { _, _ in },
            // The switch unchecked (or Bring Back Speakers pressed) right after: the speakers are back and the switch is off.
            meetingsAfterScene("speakers-off-undone", prepare: { history, fixture in
                try? await fixture.world.seedFeaturedSpeakers()
                await history.reload()
                await openTranscript(history, fixture.world.featuredMeetingID)
                await history.setSpeakerSeparation(off: true)
                await history.bringBackSpeakers()
            }) { _, _ in },
            // Speakers with a stored translation under each line of the others.
            meetingsAfterScene("speakers-translated", size: tallMeetings, prepare: { history, fixture in
                try? await fixture.world.seedFeaturedSpeakersTranslated(into: fixture.language)
                await history.reload()
                await openTranscript(history, fixture.world.featuredMeetingID)
            }) { _, _ in },
            // A search result and its snippet carry the speaker's name.
            meetingsScene("speakers-search", prepare: { history, fixture in
                try? await fixture.world.seedFeaturedSpeakers()
                await history.reload()
                history.query = fixture.content.searchQuery
                try? await Task.sleep(for: .milliseconds(900))
            }, after: { history, fixture in
                if history.hits.isEmpty { try? await Task.sleep(for: .milliseconds(900)) }
                if let hit = history.hits.first(where: { $0.meeting.id == fixture.world.featuredMeetingID }) ?? history.hits.first {
                    history.openedHit = "t\(hit.id)"
                }
                try? await Task.sleep(for: .milliseconds(400))
            }),
            // An answer's quoted passages name who said them.
            meetingsScene("speakers-ask", prepare: { history, fixture in
                try? await fixture.world.seedFeaturedSpeakers()
                await history.reload()
                history.mode = .ask
                await prepareAsk(history.ask, fixture)
            }),
            // One claim that cites a named speaker, a sure unnamed one (Speaker 1), an unnamed one in crosstalk, a named one the app is
            // not sure about, the user's own voice and another named speaker: the labels chain and wrap in the citation row.
            meetingsScene("ask-speakers-citations", prepare: { history, fixture in
                try? await fixture.world.seedFeaturedSpeakers()
                await history.reload()
                history.mode = .ask
                await prepareAsk(history.ask, fixture)
                let world = fixture.world
                let ids = [1, 0, 4, 8, 2, 3].map { world.featuredSegmentIDs[$0] }
                for segment in (try? await world.store.segmentsByIDs(ids)) ?? [] {
                    history.ask.segments[segment.id] = segment
                    history.ask.segmentMeeting[segment.id] = world.featuredMeetingID
                }
                history.ask.answer = VerifiedAnswer(answer: fixture.content.askAnswer, claims: [
                    .init(id: "claim-0", text: fixture.content.askClaims[0].0, citations: ids, verified: true),
                ])
            }),
        ]
    }

    // MARK: The popover

    /// Where the popover is opened from.
    private enum Origin {
        case line(Int)
        case speaker(ordinal: Int, named: Bool)
        case stress(ordinal: Int)
    }

    /// Which person the typed name of an assign scene stands for.
    private enum Typed {
        case text(String)
        /// The alias of one person ("Daniel"): the popover lists that person and offers no new one.
        case alias
        /// The same alias, after a second person got it too: the popover asks which one.
        case sharedAlias
    }

    private static func popoverScene(_ name: String, from origin: Origin, mode: SpeakerPopoverContent.Mode = .main, typed: Typed = .text(""),
                                     failure: ((SnapshotFixture) -> String)? = nil, gone: Bool = false, separationOff: Bool = false, canBringBack: Bool = false,
                                     mergeInto: Int? = nil) -> SnapshotScene {
        SnapshotScene(name: "speaker-popover-\(name)", size: CGSize(width: SpeakerPopoverContent.width, height: 380), fitHeight: true, isSheet: true) { fixture in
            let recorder = await fixture.makeRecorder()
            guard let history = recorder.history else { return .init(view: AnyView(EmptyView())) }
            history.llm = nil
            let world = fixture.world
            let meeting: Int64
            if case .stress = origin { meeting = (try? await world.seedSpeakerStress()) ?? world.featuredMeetingID } else {
                try? await world.seedFeaturedSpeakers()
                meeting = world.featuredMeetingID
            }
            // People who are not on the calendar, so the list shows both groups.
            try? await world.seedExtraPeople()
            var typedText = ""
            switch typed {
            case .text(let text): typedText = text
            case .alias: typedText = (try? await world.firstPersonAlias()) ?? ""
            case .sharedAlias: typedText = (try? await world.seedSecondPersonWithSameAlias()) ?? ""
            }
            await history.reload()
            history.selectedID = meeting
            await history.loadDetail()
            let roster = history.roster
            var line: MeetingStore.StoredSegment?
            var entry: SpeakerRoster.Entry?
            switch origin {
            case .line(let index):
                line = history.transcript.indices.contains(index) ? history.transcript[index] : nil
                entry = line?.speaker?.id.flatMap(roster.entry)
            case .speaker(let ordinal, _):
                entry = roster.entries.first { $0.channel == .others && $0.speaker.ordinal == ordinal }
            case .stress(let ordinal):
                entry = roster.entries.first { $0.channel == .others && $0.speaker.ordinal == ordinal }
            }
            guard let entry else { return .init(view: AnyView(EmptyView())) }
            var page = mode
            if case .confirmMerge = mode, let mergeInto, let target = roster.alternatives(to: entry.id).first(where: { $0.speaker.ordinal == mergeInto }) {
                page = .confirmMerge(target.id)
            }
            let people = history.speakerCandidates(for: entry.speaker)
            let view = SpeakerPopoverContent(roster: roster, speakerID: entry.id, line: line, meetingID: meeting,
                                             suggested: people.suggested, people: people.people, mode: page,
                                             typed: typedText, failure: failure?(fixture), gone: gone, separationOff: separationOff,
                                             perform: { _ in }, bringBack: canBringBack ? {} : nil, close: {})
                .background(Color(nsColor: .windowBackgroundColor))
            return .init(view: AnyView(view))
        }
    }

    private static var popoverScenes: [SnapshotScene] {
        [
            // From a line of a speaker nobody named: every action.
            popoverScene("line", from: .line(0)),
            // From a named speaker in "Who spoke": no line actions, and a way to clear the name.
            popoverScene("speaker", from: .speaker(ordinal: 2, named: true)),
            // The calendar's attendees on top, then the people of the context.
            popoverScene("assign", from: .line(0), mode: .assign),
            // A name that nobody has: it would be added as a new person.
            popoverScene("assign-new", from: .line(0), mode: .assign, typed: .text("Sam Okoro")),
            // A name that is somebody's alias is that person: they are listed and no new person is offered.
            popoverScene("assign-alias", from: .line(0), mode: .assign, typed: .alias),
            // Two people answer to the name: both are listed under the warning, and the user picks one.
            popoverScene("assign-ambiguous", from: .line(0), mode: .assign, typed: .sharedAlias),
            // The edit failed because the speaker was removed meanwhile: the popover says so, what to do, and closes.
            popoverScene("assign-failed", from: .line(0), mode: .assign, typed: .text("Sam Okoro"),
                         failure: { _ in StoreError(.speakerGone).localizedDescription }, gone: true),
            // Separation was turned off meanwhile: the popover says so, that names can't be given, and offers to bring the
            // speakers back (the removal can still be undone) or to close.
            popoverScene("assign-error", from: .line(0), mode: .assign, typed: .text("Sam Okoro"),
                         failure: { _ in StoreError(.speakersOff).localizedDescription }, separationOff: true, canBringBack: true),
            // The same when the speakers can't come back (separation was off from the start): only Close.
            popoverScene("assign-error-final", from: .line(0), mode: .assign, typed: .text("Sam Okoro"),
                         failure: { _ in StoreError(.speakersOff).localizedDescription }, separationOff: true),
            popoverScene("merge", from: .line(0), mode: .merge),
            popoverScene("merge-confirm", from: .line(0), mode: .confirmMerge(0), mergeInto: 2),
            // The speaker chosen to merge into disappeared meanwhile: the list to choose again, with a line that says why.
            popoverScene("merge-target-gone", from: .line(0), mode: .confirmMerge(-1)),
            popoverScene("move-line", from: .line(4), mode: .moveLine),
            // A name too long for the column, in the speaker's own popover.
            popoverScene("long-name", from: .stress(ordinal: 1)),
        ]
    }
}
#endif
