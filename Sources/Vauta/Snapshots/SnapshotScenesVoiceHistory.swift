// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

/// The scenes of looking for a confirmed voice in earlier meetings: the offer, the search, what it found, nothing found,
/// the review sheet with answers, and the Settings note. The people and meetings are invented.
extension SnapshotScenes {
    private static func historyRows(_ fixture: SnapshotFixture, decisions: [PastVoiceRow.Decision]) -> [PastVoiceRow] {
        let text = fixture.world.speakerText
        let title = text.meetingTitle
        // Like the sample meetings, relative to today and inside the 14 days a search can reach.
        let days = [1, 3, 6, 11]
        let today = Calendar.current.startOfDay(for: AppClock.now)
        return decisions.enumerated().map { index, decision in
            PastVoiceRow(match: PastVoiceMatch(speakerID: Int64(index + 1), meetingID: Int64(index + 1),
                                               meetingTitle: index == 2 ? nil : title,
                                               meetingDate: (Calendar.current.date(byAdding: .day, value: -days[index % days.count], to: today) ?? today).addingTimeInterval(10 * 3_600),
                                               speakerOrdinal: index % 3 + 1, talkSeconds: 95 + Double(index) * 170,
                                               excerpt: index == 1 ? text.lines[3...5].joined(separator: " ") : index == 3 ? nil : text.lines[(index * 2) % text.lines.count]),
                         decision: decision)
        }
    }

    private static func historyBannerScene(_ name: String, isSelf: Bool = false,
                                           state: @escaping @MainActor (VoiceHistoryPerson, SnapshotFixture) -> VoiceHistoryState) -> SnapshotScene {
        meetingsAfterScene("voices-history-\(name)", prefix: "", size: CGSize(width: 1040, height: 900), prepare: { history, fixture in
            try? await fixture.world.seedSuggestedSpeakers()
            fixture.preferences.recognizeVoices = true
            history.preferences = fixture.preferences
            await history.reload()
            history.selectedID = fixture.world.featuredMeetingID
            await history.loadDetail()
        }) { history, fixture in
            let person = VoiceHistoryPerson(entityID: 1, name: fixture.world.speakerText.names[0], isSelf: isSelf)
            history.voiceHistory = state(person, fixture)
        }
    }

    static var voiceHistory: [SnapshotScene] {
        [
            historyBannerScene("offer") { person, _ in .offer(person) },
            historyBannerScene("offer-self", isSelf: true) { person, _ in .offer(person) },
            historyBannerScene("searching") { person, _ in .searching(person) },
            historyBannerScene("found") { person, fixture in .found(person, historyRows(fixture, decisions: [.pending, .pending, .pending, .pending])) },
            historyBannerScene("found-one") { person, fixture in .found(person, historyRows(fixture, decisions: [.pending])) },
            historyBannerScene("found-answered") { person, fixture in .found(person, historyRows(fixture, decisions: [.accepted, .pending, .rejected])) },
            historyBannerScene("none") { person, _ in .none(person) },
            historyBannerScene("none-self", isSelf: true) { person, _ in .none(person) },
            historyBannerScene("found-long-name") { person, fixture in
                .found(VoiceHistoryPerson(entityID: person.entityID, name: fixture.world.speakerText.longName), historyRows(fixture, decisions: [.pending, .pending]))
            },
            bannerAlone("offer", .offer), bannerAlone("found", .found), bannerAlone("searching", .searching), bannerAlone("none", .none),
            reviewSheetScene("review", decisions: [.pending, .pending, .pending, .pending]),
            reviewSheetScene("review-answered", decisions: [.accepted, .rejected, .pending, .pending]),
            reviewSheetScene("review-self", decisions: [.pending, .accepted], isSelf: true),
            reviewSheetScene("review-long-name", decisions: [.pending, .pending], longName: true),
            learnMoreScene("learn-more-off", recognizing: false),
            learnMoreScene("learn-more-on", recognizing: true),
        ]
    }

    private enum BannerKind { case offer, found, searching, none }

    /// The banner on its own, at the width it has in the window.
    private static func bannerAlone(_ name: String, _ kind: BannerKind) -> SnapshotScene {
        SnapshotScene(name: "voices-history-banner-\(name)", size: CGSize(width: 800, height: 200), fitHeight: true, isSheet: true) { fixture in
            let person = VoiceHistoryPerson(entityID: 1, name: fixture.world.speakerText.names[0])
            let state: VoiceHistoryState = switch kind {
            case .offer: .offer(person)
            case .found: .found(person, historyRows(fixture, decisions: [.pending, .pending, .pending, .pending]))
            case .searching: .searching(person)
            case .none: .none(person)
            }
            return .init(view: AnyView(VoiceHistoryBanner(state: state, look: {}, review: {}, undo: {}, dismiss: {})
                .padding(20).frame(width: 800).background(Color(nsColor: .windowBackgroundColor))))
        }
    }

    /// The Learn More popover of Settings → Speakers on its own, at the width it has there: what is kept, for how long and
    /// what it is used for, readable with the switch off as well as on.
    private static func learnMoreScene(_ name: String, recognizing: Bool) -> SnapshotScene {
        SnapshotScene(name: "voices-history-\(name)", size: CGSize(width: 440, height: 600), fitHeight: true, isSheet: true) { _ in
            .init(view: AnyView(VStack(alignment: .leading, spacing: 10) { RecognizeVoicesDetails(recognizing: recognizing) }
                .padding(16).frame(width: 400).background(Color(nsColor: .windowBackgroundColor))))
        }
    }

    private static func reviewSheetScene(_ name: String, decisions: [PastVoiceRow.Decision], isSelf: Bool = false, longName: Bool = false) -> SnapshotScene {
        SnapshotScene(name: "voices-history-\(name)", size: CGSize(width: 500, height: 560), fitHeight: true, isSheet: true) { fixture in
            let person = VoiceHistoryPerson(entityID: 1, name: longName ? fixture.world.speakerText.longName : fixture.world.speakerText.names[0], isSelf: isSelf)
            return .init(view: AnyView(PastVoiceReviewSheet(person: person, rows: historyRows(fixture, decisions: decisions),
                                                            answer: { _, _ in }, undo: { _ in }, done: {})
                .background(Color(nsColor: .windowBackgroundColor))))
        }
    }
}
#endif
