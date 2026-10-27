// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

/// The speaker scenes outside the Meetings window: the live panel with provisional labels, the captions with a speaker
/// label, Settings → Speakers and a person's card.
extension SnapshotScenes {
    static var liveSpeakers: [SnapshotScene] {
        panelSpeakerScenes + captionSpeakerScenes + otherSpeakerScenes
    }

    // MARK: Menu-bar panel

    /// Sets up a recording with voices told apart: the user and three others (one a guess, one said over somebody), with
    /// the first of the others named when `named` is true. `longName` gives that person the long sample name.
    private static func speakerRecording(_ recorder: RecorderModel, _ fixture: SnapshotFixture, named: Bool, longName: Bool = false,
                                         voices: Int = 3) async {
        try? await fixture.world.resetSpeakerSamples()
        recording(recorder, fixture)
        let text = fixture.world.speakerText
        // (channel, voice, confidence, overlap) for each line of the transcript so far.
        let plan: [(Channel, Int, Double, Bool)] = [
            (.me, 1, 0.99, false), (.others, 1, 0.93, false), (.others, min(2, voices), 0.9, false), (.me, 1, 0.99, false),
            (.others, min(3, voices), 0.42, false), (.others, 1, 0.88, true), (.others, min(2, voices), 0.91, false),
        ]
        recorder.segments = plan.enumerated().map { index, entry in
            let start = Double(index) * 14 + 40
            return LiveSegment(id: index, segment: Segment(channel: entry.0, start: start, end: start + 11, text: text.lines[index % text.lines.count],
                                                          isFinal: true, speaker: SpeakerTag(ordinal: entry.1, confidence: entry.2, overlap: entry.3)))
        }
        recorder.volatileSegments = []
        recorder.showTranscript = true
        recorder.liveSpeakers = Array(1...max(1, voices))
        recorder.latestLiveSpeaker = min(2, voices)
        let store = fixture.world.store
        let people = await people(fixture).filter { !$0.isSelf }
        recorder.attendees = Array(people.prefix(4))
        if named {
            var person = people.first
            if longName, let id = try? await store.saveEntity(EntityDraft(kind: .person, name: text.longName)) {
                person = (try? await store.entities(.person))?.first { $0.id == id }
            }
            if let person {
                recorder.othersNamed = [person]
                recorder.liveSpeakerPeople = [1: person]
            }
        }
    }

    private static var panelSpeakerScenes: [SnapshotScene] {
        [
            // Provisional labels on the finals, the hint under the transcript, one chip per voice (the first is named) and the
            // calendar's attendees as suggestions.
            storePanelScene("speakers-live") { recorder, fixture in
                await speakerRecording(recorder, fixture, named: true)
            },
            // A name that does not fit: the label and the chip are cut, the card keeps its width.
            storePanelScene("speakers-live-long-name") { recorder, fixture in
                await speakerRecording(recorder, fixture, named: true, longName: true)
            },
            // Nobody named yet; the second voice is the one the name field is for (the one heard last).
            storePanelScene("speakers-live-unnamed") { recorder, fixture in
                await speakerRecording(recorder, fixture, named: false)
            },
            // One other voice so far: a single chip, and the hint already says the label may change.
            storePanelScene("speakers-live-one-voice") { recorder, fixture in
                await speakerRecording(recorder, fixture, named: false, voices: 1)
            },
            // The user typed a name and the people of the context answer.
            storePanelScene("speakers-live-query", focusing: { $0.othersQuery }) { recorder, fixture in
                await speakerRecording(recorder, fixture, named: true)
                let people = await people(fixture).filter { !$0.isSelf }
                let query = String(people.last?.displayName.prefix(2) ?? "Ma")
                recorder.chosenLiveSpeaker = 2
                recorder.othersQuery = query
                recorder.othersHits = people.suffix(2).map { NameHit(target: .entity($0.id), text: $0.displayName) }
                recorder.othersHitsQuery = query
            },
            // A short screen: the transcript shows its newest line in the header, with the voice's label.
            SnapshotScene(name: "panel-speakers-live-short", size: panelSize, fitHeight: true, isPanel: true) { fixture in
                let recorder = await fixture.makeRecorder()
                await speakerRecording(recorder, fixture, named: true)
                let view = RecorderPanel(model: recorder)
                    .environment(\.panelMaxHeight, 520)
                    .background(Color(nsColor: .windowBackgroundColor))
                return .init(view: AnyView(view))
            },
            // After the meeting: the labels shown while recording may have changed.
            // The notice as a recording leaves it: with the meeting to open, so the Check Speakers button is there.
            panelScene("speakers-updated") { recorder, fixture in
                recorder.speakersUpdated = true
                recorder.speakersUpdatedMeetingID = fixture.world.featuredMeetingID
            },
            // And without a meeting to open (the notice alone).
            panelScene("speakers-updated-plain") { recorder, _ in recorder.speakersUpdated = true },
        ]
    }

    // MARK: Captions

    /// The captions as the others speak: three voices, the third sentence still being spoken (so it has no label yet).
    private static func spokenBy(_ sample: CaptionSample, voices: [Int], partialLast: Bool = true) -> [CaptionLine] {
        var lines = sample.lines(upTo: 3, partialLast: partialLast)
        for index in lines.indices where lines[index].state != .partial { lines[index].speaker = voices[index % voices.count] }
        return lines
    }

    private static func speakerNames(_ fixture: SnapshotFixture, long: Bool = false) -> CaptionSpeakers {
        let text = fixture.world.speakerText
        return CaptionSpeakers(count: 3, names: long ? [1: text.longName, 2: text.names[1]] : [1: text.names[0], 2: text.names[1]])
    }

    private static var captionSpeakerScenes: [SnapshotScene] {
        [
            // Two voices named and a third not: each finished caption says who said it; the one still being spoken has no label yet.
            captionScene("speakers", width: 720, speakers: { speakerNames($0) }) { CaptionSnapshot(pair: $0.pair, status: .listening, lines: spokenBy($0, voices: [1, 2, 3])) },
            captionScene("speakers-original", original: true, width: 720, speakers: { speakerNames($0) }) {
                CaptionSnapshot(pair: $0.pair, status: .listening, lines: spokenBy($0, voices: [1, 2, 3]))
            },
            // The default width: the oldest caption is longer than a line with its name, so it keeps its last words under
            // an ellipsis, led by its name.
            captionScene("speakers-cut", speakers: { speakerNames($0) }) { CaptionSnapshot(pair: $0.pair, status: .listening, lines: spokenBy($0, voices: [1, 2, 3])) },
            // A name too long for a caption is cut at a character, in the narrowest panel and the large text.
            captionScene("speakers-long-name", size: .large, width: CaptionTextSize.minimumWidth, speakers: { speakerNames($0, long: true) }) {
                CaptionSnapshot(pair: $0.pair, status: .listening, lines: spokenBy($0, voices: [1, 2, 1], partialLast: false))
            },
            captionScene("speakers-long-name-wide", speakers: { speakerNames($0, long: true) }) {
                CaptionSnapshot(pair: $0.pair, status: .listening, lines: spokenBy($0, voices: [1, 2, 1], partialLast: false))
            },
            // The largest text in the narrowest panel: every caption is cut under an ellipsis and keeps its label.
            captionScene("speakers-extra-large-narrow", original: true, size: .extraLarge, width: CaptionTextSize.minimumWidth,
                         speakers: { speakerNames($0) }) { sample in
                var lines = spokenBy(sample, voices: [1, 2, 3], partialLast: false)
                lines[2].translation = CaptionSample.joined(lines[2].translation, sample.translations[0], language: sample.pair.target)
                lines[2].original = CaptionSample.joined(lines[2].original, sample.originals[0], language: sample.pair.source)
                return CaptionSnapshot(pair: sample.pair, status: .listening, lines: lines)
            },
            // Paused with labelled captions on screen: dimmed, with the badge.
            captionScene("speakers-paused", speakers: { speakerNames($0) }) { CaptionSnapshot(pair: $0.pair, status: .paused, lines: spokenBy($0, voices: [1, 2, 3], partialLast: false)) },
            // A right-to-left target: the name leads the line on the right and the full stop stays at the left end.
            captionScene("speakers-rtl", speakers: { speakerNames($0) }) { sample in
                let pair = TranslationPair(source: sample.pair.source, target: Locale.Language(identifier: "ar"))
                let lines = [
                    CaptionLine(id: 0, original: sample.originals[0], translation: "لننقل الإطلاق إلى الأسبوع الثاني من مارس.", state: .final, speaker: 1),
                    CaptionLine(id: 1, original: sample.originals[1], translation: "ما زال على الفريق القانوني مراجعة العقد الجديد.", state: .final, speaker: 2),
                    CaptionLine(id: 2, original: sample.originals[2], translation: "هل يمكن للجميع أن يرسلوا", state: .partial),
                ]
                return CaptionSnapshot(pair: pair, status: .listening, lines: lines)
            },
        ]
    }

    // MARK: Settings and the person's card

    private static var otherSpeakerScenes: [SnapshotScene] {
        [
            settingsScene("speakers", .speakers, size: CGSize(width: 1020, height: 620)) { _, fixture in
                fixture.preferences.separateSpeakers = true
            },
            settingsScene("speakers-off", .speakers, size: CGSize(width: 1020, height: 620)) { _, fixture in
                fixture.preferences.separateSpeakers = false
            },
            // The narrowest Settings window.
            settingsScene("speakers-narrow", .speakers, size: CGSize(width: SettingsWindow.minimumWidth, height: 700)) { _, fixture in
                fixture.preferences.separateSpeakers = true
            },
            // A person named as a speaker in three meetings, all of them listed.
            meetingsAfterScene("speakers-person", size: CGSize(width: 1040, height: 800), prepare: { history, fixture in
                try? await fixture.world.seedSpeakerAcrossMeetings()
                await history.reload()
                history.mode = .people
                history.selectedEntityID = fixture.world.peopleIDs[2]
                await history.loadEntity()
            }) { _, _ in },
            // The same card in one meeting (the singular).
            meetingsAfterScene("speakers-person-one", size: CGSize(width: 1040, height: 800), prepare: { history, fixture in
                try? await fixture.world.seedFeaturedSpeakers()
                await history.reload()
                history.mode = .people
                history.selectedEntityID = fixture.world.peopleIDs[2]
                await history.loadEntity()
            }) { _, _ in },
        ]
    }
}
#endif
