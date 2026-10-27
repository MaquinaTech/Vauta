// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

/// The pre-meeting brief: the card and the recording row in the menu-bar panel, Upcoming and the Brief tab in the Meetings window.
/// The briefs are made by the real `BriefComposer` from the sample store (its meetings, people, tasks and decisions); the reminders,
/// the invitation, the documents and the agenda are invented (`BriefSample`). EventKit is never touched.
@MainActor
extension SnapshotScenes {
    // MARK: Sample reminders

    private struct SampleReminders: BriefReminderSource {
        let items: [BriefReminder]
        let access: BriefReminderAccess
        func lists() async -> [BriefReminderList] { [] }
        func incompleteReminders(in listIDs: Set<String>, limit: Int) async -> [BriefReminder] { items }
    }

    // MARK: Sample brief

    /// The next time the weekly sync repeats, at its usual hour (the same weekday as the featured meeting, so "Last time" and the agenda agree
    /// with it on any render day).
    static func briefStart(_ fixture: SnapshotFixture) -> Date { fixture.world.nextWeeklyStart() }

    private static func firstMeetingTitle(_ language: String) -> String {
        switch language {
        case "es": "Llamada de presentación con Contoso"
        case "fr": "Appel de présentation avec Contoso"
        case "de": "Kennenlerngespräch mit Contoso"
        case "it": "Chiamata di presentazione con Contoso"
        case "pt-BR": "Chamada de apresentação com a Contoso"
        case "ja": "Contosoとの初回打ち合わせ"
        case "ko": "콘토소와의 첫 미팅"
        case "zh-Hans": "与 Contoso 的初次沟通"
        default: "Intro call with Contoso"
        }
    }

    private static let strangers = ["Jordan Lee", "Sam Patel", "Alex Rivera", "Robin Clarke", "Kim Novak"]

    enum BriefSampleKind { case regular, first, longNames, longPeople, manyPeople, inPerson, tab }

    static func sampleBriefEvent(_ fixture: SnapshotFixture, kind: BriefSampleKind = .regular, notes: Bool = true, start: Date? = nil,
                                 service: ConferencingService? = .zoom, title named: String? = nil) async -> BriefEvent {
        let sample = BriefSample.forLanguage(fixture.language)
        let known = await people(fixture)
        let me = known.first { $0.isSelf }?.displayName ?? "Me"
        let others = known.filter { !$0.isSelf }.prefix(3).map(\.displayName)
        let title = (try? await fixture.world.store.meeting(fixture.world.featuredMeetingID))?.displayTitle ?? sample.longTitle
        var names: [String]
        var eventTitle = title
        switch kind {
        case .regular: names = others + [strangers[0]]
        case .first:
            names = Array(strangers.prefix(2))
            eventTitle = firstMeetingTitle(fixture.language)
        case .longNames:
            names = others + strangers + ["Alexandria Konstantinopoulos-Hernández"]
            eventTitle = sample.longTitle
        case .longPeople:
            // Two names too long for a row, after the first known person: the People section draws them all.
            names = Array(others.prefix(1)) + ["Alexandria Konstantinopoulos-Hernández", "Maximiliano Bartholomew Fitzgerald-Montenegro de la Vega Castellanos"]
            eventTitle = sample.longTitle
        case .tab:
            // One known person and one invited stranger: the recorded meeting that person was at is "Last time".
            names = Array(others.prefix(1)) + [strangers[0]]
        case .manyPeople: names = others + Array(strangers.prefix(3))
        case .inPerson: names = others
        }
        if let named { eventTitle = named }
        let attendees = [BriefAttendee(name: me, email: nil, isCurrentUser: true)] + names.map { BriefAttendee(name: $0, email: nil) }
        let begins = start ?? briefStart(fixture)
        let agenda = "- " + sample.invitation.joined(separator: "\n- ")
        return BriefEvent(identifier: "sample-\(kind)", title: eventTitle, start: begins, end: begins.addingTimeInterval(1800), calendarID: "work",
                          attendees: attendees, isRecurring: kind == .regular, service: kind == .inPerson ? nil : service,
                          invitationNotes: notes && kind != .first ? agenda : nil, calendarColor: BriefColor(red: 0.10, green: 0.47, blue: 0.96))
    }

    private static func sampleReminders(_ fixture: SnapshotFixture, event: BriefEvent) -> [BriefReminder] {
        let sample = BriefSample.forLanguage(fixture.language)
        let names = event.otherAttendees.map(\.name)
        let dues: [Date?] = [event.start.addingTimeInterval(-86_400), event.start.addingTimeInterval(2 * 86_400), nil]
        return sample.reminders.enumerated().map { index, text in
            BriefReminder(id: "r\(index)", title: "\(names[min(index, max(0, names.count - 1))]) – \(text)", due: dues[index], listID: "work",
                          listName: sample.lists[0], priority: index == 0 ? 1 : 0)
        }
    }

    /// The brief of `event` from the real composer and the sample store; related meetings, documents and notes are added by hand (they
    /// need the search model or an indexed library).
    static func sampleBrief(_ fixture: SnapshotFixture, event: BriefEvent, reminders: Bool = true, related: Bool = true,
                            agenda: BriefAgendaState = .none) async -> BriefSnapshot {
        let source = SampleReminders(items: sampleReminders(fixture, event: event), access: .granted)
        let composer = BriefComposer(store: fixture.world.store, retriever: nil, reminders: reminders ? source : nil)
        let settings = BriefSettings(remindersEnabled: reminders, reminderListIDs: ["work"], useInvitationNotes: true)
        guard var snapshot = (await composer.build(event, settings: settings, environment: BriefEnvironment())).snapshot else {
            return BriefSnapshot(occurrence: event.occurrence, title: event.title, start: event.start, end: event.end, service: event.service,
                                 seriesName: nil, mode: .keyword, relatedSkipped: false, sections: [])
        }
        if related { snapshot = await addingRelated(snapshot, fixture) }
        snapshot.agenda = agenda
        return snapshot
    }

    private static func addingRelated(_ snapshot: BriefSnapshot, _ fixture: SnapshotFixture) async -> BriefSnapshot {
        let sample = BriefSample.forLanguage(fixture.language)
        let world = fixture.world
        var out = snapshot
        let meetingID = world.meetingIDs[2]
        let title = (try? await world.store.meeting(meetingID))?.displayTitle ?? ""
        var meeting = BriefItem(kind: .relatedMeeting, text: title, link: .meeting(meetingID: meetingID, t: nil))
        meeting.meetingID = meetingID
        meeting.meetingDate = world.startDate(ofMeeting: 2)
        meeting.detail = sample.relatedText
        var material = BriefItem(kind: .material, text: sample.materialFile, link: .file(sourceID: 3, relPath: sample.materialFile))
        material.meetingID = world.featuredMeetingID
        var document = BriefItem(kind: .document, text: sample.documentFile, link: .passage(key: "a1", sourceID: 2, relPath: sample.documentFile))
        document.detail = sample.documentText
        var note = BriefItem(kind: .note, text: sample.noteFile, link: .passage(key: "a4", sourceID: 4, relPath: sample.noteFile))
        note.detail = sample.noteText
        var sections = out.sections.filter { $0.kind != .relatedMeetings && $0.kind != .documents }
        let extra = [BriefSection(kind: .relatedMeetings, items: [meeting]), BriefSection(kind: .documents, items: [material, document, note])]
        let order = BriefSectionKind.allCases
        sections += extra
        sections.sort { (order.firstIndex(of: $0.kind) ?? 0) < (order.firstIndex(of: $1.kind) ?? 0) }
        var n = 0
        for s in sections.indices {
            for i in sections[s].items.indices {
                n += 1
                sections[s].items[i].id = "b\(n)"
            }
        }
        out.sections = sections
        return out
    }

    /// A suggested agenda that cites lines of the brief. `keptOnly` cites nothing that a recorded meeting does not keep (no invitation line).
    static func sampleAgenda(_ fixture: SnapshotFixture, in snapshot: BriefSnapshot, keptOnly: Bool = false) -> BriefAgendaState {
        let sample = BriefSample.forLanguage(fixture.language)
        func id(_ kind: BriefItem.Kind) -> String? { snapshot.items.first { $0.kind == kind }?.id }
        let lines = [
            BriefAgendaLine(kind: .followUp, text: sample.followUp, cites: [id(.task)].compactMap { $0 }),
            BriefAgendaLine(kind: .decide, text: sample.decide, cites: [id(.openQuestion)].compactMap { $0 }),
            BriefAgendaLine(kind: .ask, text: sample.ask, cites: [id(.decision) ?? id(.task), keptOnly ? nil : id(.invitationLine)].compactMap { $0 }),
        ].filter { !$0.cites.isEmpty }
        return .lines(lines)
    }

    /// A first meeting or a meeting of people met before with nothing open, made by hand.
    private static func peopleOnly(_ event: BriefEvent, metBefore: Bool) -> BriefSnapshot {
        var items: [BriefItem] = []
        for (index, attendee) in event.otherAttendees.enumerated() {
            var item = BriefItem(id: "b\(index + 1)", kind: .person, text: attendee.name)
            item.meetingsTogether = metBefore ? 2 : 0
            item.lastMet = metBefore ? event.start.addingTimeInterval(-9 * 86_400) : nil
            items.append(item)
        }
        return BriefSnapshot(occurrence: event.occurrence, title: event.title, start: event.start, end: event.end, service: event.service,
                             seriesName: nil, mode: .keyword, relatedSkipped: true, sections: [BriefSection(kind: .people, items: items)])
    }

    // MARK: Panel scenes

    private enum CardState { case ready, locked, first, nothing, building, hot, hint, longNames, unconfirmed, armed }

    private static func briefPanelScene(_ name: String, _ state: CardState) -> SnapshotScene {
        SnapshotScene(name: "panel-\(name)", size: panelSize, fitHeight: true, isPanel: true) { fixture in
            let recorder = await fixture.makeRecorder()
            let kind: BriefSampleKind = state == .first ? .first : state == .longNames ? .longNames : .regular
            let event = await sampleBriefEvent(fixture, kind: kind)
            var entry = BriefController.Entry(event: event)
            switch state {
            case .ready, .longNames, .armed:
                entry.snapshot = await sampleBrief(fixture, event: event, reminders: false)
            case .unconfirmed:
                // The top task of the card is overdue, not confirmed by the minutes and has an owner nothing confirms.
                var snapshot = await sampleBrief(fixture, event: event, reminders: false)
                if let index = snapshot.sections.firstIndex(where: { $0.kind == .openTasks }), !snapshot.sections[index].items.isEmpty {
                    snapshot.sections[index].items[0].unconfirmed = true
                    snapshot.sections[index].items[0].ownerUncertain = true
                    snapshot.sections[index].items[0].overdue = true
                    // An overdue task is never also "due before this meeting" (BriefBuilder.isDueBeforeMeeting).
                    snapshot.sections[index].items[0].dueBeforeMeeting = false
                    if snapshot.sections[index].items[0].owner == nil { snapshot.sections[index].items[0].owner = event.otherAttendees.first?.name }
                }
                entry.snapshot = snapshot
            case .locked, .hint: entry.event = BriefController.stripped(event)
            case .first: entry.snapshot = peopleOnly(event, metBefore: false)
            case .nothing: entry.snapshot = peopleOnly(event, metBefore: true)
            case .building: break
            case .hot: entry.hot = true
            }
            recorder.brief.installSnapshotState(next: entry, upcoming: .off, locked: state == .locked)
            if state == .armed { recorder.brief.armed = event.occurrence }
            // The offer is for the brief while it is off and was never set up; every other card is of the brief switched on.
            recorder.brief.prefs.installSnapshotDefaults(enabled: state != .hint, hintSeen: state != .hint)
            let view = RecorderPanel(model: recorder).environment(\.panelMaxHeight, airPanelHeight).background(Color(nsColor: .windowBackgroundColor))
            return .init(view: AnyView(view))
        }
    }

    private static func briefRecordingScene(_ name: String, expanded: Bool, locked: Bool = false) -> SnapshotScene {
        SnapshotScene(name: "panel-\(name)", size: panelSize, fitHeight: true, isPanel: true) { fixture in
            let recorder = await fixture.makeRecorder()
            let content = fixture.content
            recorder.phase = .recording
            recorder.startedAt = AppClock.now.addingTimeInterval(-754)
            recorder.elapsedSeconds = 754
            recorder.levels = [.me: 0.35, .others: 0.7]
            recorder.segments = content.liveSegments.enumerated().map { LiveSegment(id: $0.offset, segment: $0.element) }
            recorder.showTranscript = false
            recorder.livePoints = content.livePoints
            recorder.recordingLanguage = SnapshotMode.catalog?.language(matching: fixture.world.locale.identifier(.bcp47))
            recorder.recordingSource = .apps([.zoom])
            recorder.recordingApp = CallDescription(appName: content.callApp, family: .zoom, service: nil)
            // The meeting being recorded began when the recording did, so its due-date marks are judged against now.
            let event = await sampleBriefEvent(fixture, start: recorder.startedAt)
            var brief = await sampleBrief(fixture, event: event, reminders: false)
            brief.agenda = sampleAgenda(fixture, in: brief)
            recorder.brief.installSnapshotState(next: nil, upcoming: .off, recordingBrief: brief, locked: locked)
            recorder.brief.prefs.installSnapshotDefaults()
            let view = RecorderPanel(model: recorder)
                .environment(\.panelMaxHeight, airPanelHeight)
                .environment(\.briefViewOptions, BriefViewOptions(startsExpanded: expanded))
                .background(Color(nsColor: .windowBackgroundColor))
            var prepared = SnapshotScene.Prepared(view: AnyView(view))
            // The visible area of the panel never ends through a row of the brief (see `PanelGeometryProbe`).
            if expanded { prepared.verify = { PanelGeometryProbe.problem() } }
            return prepared
        }
    }

    /// "Record at Start" was pressed: the meeting is starting and Vauta asks (it does not record by itself).
    private static var scheduledSuggestionScene: SnapshotScene {
        SnapshotScene(name: "panel-suggestion-scheduled", size: panelSize, fitHeight: true, isPanel: true) { fixture in
            let recorder = await fixture.makeRecorder()
            let event = await sampleBriefEvent(fixture, kind: .inPerson)
            recorder.suggestion = RecordingSuggestion(event: CalendarEventMatch(meeting: event.calendarMeeting, service: nil),
                                                      call: CallDescription(appName: nil, family: nil, service: nil), scheduled: true)
            let view = RecorderPanel(model: recorder).environment(\.panelMaxHeight, airPanelHeight).background(Color(nsColor: .windowBackgroundColor))
            return .init(view: AnyView(view))
        }
    }

    // MARK: Meetings scenes

    private enum UpcomingSample { case full, keyword, noAgendaModel, noSuggestions, unconfirmed, showAll, empty, denied, off, loading, loadingSlow, hot, first, remindersHint, remindersNoLists, two, longNames, inReminders, chain }

    private static func upcomingScene(_ name: String, _ sample: UpcomingSample) -> SnapshotScene {
        meetingsScene(name, size: CGSize(width: 1040, height: sample == .empty || sample == .denied || sample == .off || sample == .loading || sample == .loadingSlow || sample == .hot ? 660 : 1500), prepare: { history, fixture in
            history.selectedID = nil
            history.mode = .meetings
            history.showingUpcoming = true
            var upcoming = BriefController.UpcomingState.off
            switch sample {
            case .empty: upcoming = .none
            case .denied: upcoming = .calendarDenied
            case .off: upcoming = .off
            case .loading, .loadingSlow: upcoming = .loading
            case .hot: upcoming = .entries([BriefController.Entry(event: await sampleBriefEvent(fixture), hot: true)])
            case .first:
                let event = await sampleBriefEvent(fixture, kind: .first, notes: false)
                upcoming = .entries([BriefController.Entry(event: event, snapshot: peopleOnly(event, metBefore: false))])
            case .two:
                let first = await sampleBriefEvent(fixture)
                let second = await sampleBriefEvent(fixture, kind: .inPerson, notes: false, start: briefStart(fixture).addingTimeInterval(3 * 3600),
                                                    title: BriefSample.forLanguage(fixture.language).invitation[2])
                var one = BriefController.Entry(event: first, snapshot: await sampleBrief(fixture, event: first))
                one.reminders = .shown
                upcoming = .entries([one, BriefController.Entry(event: second, snapshot: await sampleBrief(fixture, event: second, reminders: false))])
            default:
                let kind: BriefSampleKind = sample == .showAll ? .manyPeople : sample == .longNames ? .longPeople : .regular
                let event = await sampleBriefEvent(fixture, kind: kind)
                if sample == .unconfirmed { try? await fixture.world.seedVerificationMarks() }
                var snapshot = await sampleBrief(fixture, event: event, reminders: sample != .remindersHint && sample != .remindersNoLists, related: sample != .keyword)
                if sample == .unconfirmed { try? await fixture.world.clearVerificationMarks() }
                if sample == .inReminders {
                    // A task that has a reminder Vauta created is listed once, as the task, with its mark.
                    for index in snapshot.sections.indices {
                        if let first = snapshot.sections[index].items.firstIndex(where: { $0.kind == .task }) { snapshot.sections[index].items[first].inReminders = true }
                    }
                }
                if sample == .chain {
                    // A task the person confirmed is the same as earlier ones, a decision that is the first of its kind, and one that replaces an earlier decision.
                    let day = { (n: Int) in Calendar.current.date(byAdding: .day, value: n, to: fixture.world.startDate(ofMeeting: 0)) ?? AppClock.now }
                    var decisions = 0
                    // The earlier wording is the same decision before it was changed (a higher limit), so the pair reads as one decision
                    // that was reworded and never as two unrelated ones.
                    let earlierLimit = 1000.formatted(.number.locale(fixture.world.locale))
                    for index in snapshot.sections.indices {
                        // The chain is the task of the 1:1 that repeats in the next meeting; it goes back to the oldest meeting of the chain.
                        let chainText = fixture.world.chainTaskText
                        if let first = snapshot.sections[index].items.firstIndex(where: { $0.kind == .task && $0.text == chainText }) {
                            snapshot.sections[index].items[first].carriedMentions = 3
                            snapshot.sections[index].items[first].carriedSince = fixture.world.startDate(ofMeeting: 2)
                        }
                        for i in snapshot.sections[index].items.indices where snapshot.sections[index].items[i].kind == .decision {
                            decisions += 1
                            if decisions == 1 { snapshot.sections[index].items[i].firstDecided = day(-45) }
                            if decisions == 2 {
                                snapshot.sections[index].items[i].replacesDate = day(-24)
                                snapshot.sections[index].items[i].replacesText = snapshot.sections[index].items[i].text.replacingOccurrences(of: "500", with: earlierLimit)
                            }
                        }
                    }
                }
                switch sample {
                case .full, .showAll, .unconfirmed, .keyword, .longNames, .inReminders, .chain: snapshot.agenda = sampleAgenda(fixture, in: snapshot)
                case .noAgendaModel: snapshot.agenda = .unavailable
                case .noSuggestions: snapshot.agenda = .noSuggestions
                default: break
                }
                var entry = BriefController.Entry(event: event, snapshot: snapshot)
                entry.reminders = sample == .remindersHint ? .denied : sample == .remindersNoLists ? .noLists : .shown
                upcoming = .entries([entry])
            }
            history.brief?.installSnapshotState(next: nil, upcoming: upcoming, offersUpcoming: true, loadingWaited: sample == .loadingSlow)
            // The empty page of a brief that is off is reached from the sidebar while Calendar is on.
            history.brief?.prefs.installSnapshotDefaults(enabled: sample != .off)
            if sample == .showAll { history.brief?.upcomingIndex = 0 }
        }, configureRecorder: { _, _ in })
    }

    private static var briefTabScene: SnapshotScene {
        meetingsAfterScene("meeting-brief-tab", prepare: { history, fixture in
            history.selectedID = fixture.world.featuredMeetingID
            await history.loadDetail()
        }, apply: { history, fixture in
            // The brief this meeting started with, built ten minutes before it began from the meetings before it: one of them is "Last time",
            // and the agenda cites only what a recorded meeting keeps. A decision and a task the minutes could not back keep their marks.
            let began = fixture.world.startDate(ofMeeting: 0)
            let event = await sampleBriefEvent(fixture, kind: .tab, start: began)
            var snapshot = await sampleBrief(fixture, event: event, reminders: true)
            for index in snapshot.sections.indices {
                if let first = snapshot.sections[index].items.firstIndex(where: { $0.kind == .decision }) { snapshot.sections[index].items[first].unconfirmed = true }
                if let first = snapshot.sections[index].items.firstIndex(where: { $0.kind == .task }) {
                    snapshot.sections[index].items[first].ownerUncertain = true
                    if snapshot.sections[index].items[first].owner == nil { snapshot.sections[index].items[first].owner = event.otherAttendees.first?.name }
                }
            }
            snapshot.agenda = sampleAgenda(fixture, in: snapshot, keptOnly: true)
            history.storedBrief = (BriefStoredReferences(snapshot: snapshot), began.addingTimeInterval(-600))
            history.tab = .brief
            history.brief?.installSnapshotState(next: nil, upcoming: .off, offersUpcoming: true)
        })
    }

    // MARK: Settings scenes

    private static func briefSettings(_ name: String, size: CGSize = CGSize(width: 1020, height: 900), enabled: Bool = true, lead: Int = 10,
                                      reminders: Bool = false, access: BriefReminderAccess = .notDetermined, chosen: Set<String> = [],
                                      lists: Bool = false, noLists: Bool = false, calendarOn: Bool = true) -> SnapshotScene {
        settingsScene(name, .calendar, size: size) { recorder, fixture in
            recorder.calendar.installSnapshotState(enabled: calendarOn, access: true, calendars: sampleCalendars(fixture), selected: ["work", "team"])
            let sample = BriefSample.forLanguage(fixture.language)
            let reminderLists = noLists ? [] : [BriefReminderList(id: "work", title: sample.lists[0], source: "iCloud"),
                                                BriefReminderList(id: "personal", title: sample.lists[1], source: "iCloud"),
                                                BriefReminderList(id: "atlas", title: "Atlas", source: "Exchange · \(SampleNames.forLanguage(fixture.language).email)")]
            recorder.brief.prefs.installSnapshotDefaults(enabled: enabled, lead: lead)
            recorder.brief.prefs.installSnapshotState(remindersEnabled: reminders, access: access, lists: lists || access == .granted ? reminderLists : [], chosen: chosen)
        }
    }

    static var briefScenes: [SnapshotScene] {
        [
            briefPanelScene("brief-ready", .ready),
            briefPanelScene("brief-locked", .locked),
            briefPanelScene("brief-first-meeting", .first),
            briefPanelScene("brief-nothing-open", .nothing),
            briefPanelScene("brief-building", .building),
            briefPanelScene("brief-hot", .hot),
            briefPanelScene("brief-setup-offer", .hint),
            briefPanelScene("brief-long-names", .longNames),
            briefPanelScene("brief-unconfirmed", .unconfirmed),
            briefPanelScene("brief-record-at-start", .armed),
            briefRecordingScene("recording-brief-collapsed", expanded: false),
            briefRecordingScene("recording-brief-expanded", expanded: true),
            briefRecordingScene("recording-brief-locked", expanded: false, locked: true),
            scheduledSuggestionScene,
            upcomingScene("upcoming-brief-full", .full),
            upcomingScene("upcoming-brief-keyword", .keyword),
            upcomingScene("upcoming-brief-no-agenda-model", .noAgendaModel),
            upcomingScene("upcoming-brief-no-suggestions", .noSuggestions),
            upcomingScene("upcoming-brief-unconfirmed", .unconfirmed),
            upcomingScene("upcoming-brief-show-all", .showAll),
            upcomingScene("upcoming-brief-first-meeting", .first),
            upcomingScene("upcoming-brief-reminders-hint", .remindersHint),
            upcomingScene("upcoming-brief-hot", .hot),
            upcomingScene("upcoming-brief-two", .two),
            upcomingScene("upcoming-brief-long-names", .longNames),
            upcomingScene("upcoming-brief-in-reminders", .inReminders),
            upcomingScene("upcoming-brief-chain", .chain),
            upcomingScene("upcoming-brief-reminders-no-lists", .remindersNoLists),
            upcomingScene("upcoming-loading", .loading),
            upcomingScene("upcoming-loading-slow", .loadingSlow),
            upcomingScene("upcoming-empty", .empty),
            upcomingScene("upcoming-calendar-denied", .denied),
            upcomingScene("upcoming-off", .off),
            briefTabScene,
            briefSettings("calendar-reminders-off", size: CGSize(width: 1020, height: 980)),
            briefSettings("calendar-reminders-not-asked", size: CGSize(width: 1020, height: 980), reminders: true, access: .notDetermined),
            briefSettings("calendar-reminders-denied", size: CGSize(width: 1020, height: 980), reminders: true, access: .denied),
            briefSettings("calendar-reminders-lists", size: CGSize(width: 1020, height: 1600), reminders: true, access: .granted, chosen: ["work"]),
            briefSettings("calendar-reminders-no-choice", size: CGSize(width: 1020, height: 1600), reminders: true, access: .granted),
            briefSettings("calendar-reminders-no-lists", size: CGSize(width: 1020, height: 1600), reminders: true, access: .granted, noLists: true),
            briefSettings("calendar-brief-options", size: CGSize(width: 1020, height: 1240), lead: 15),
            briefSettings("calendar-brief-notification-off", size: CGSize(width: 1020, height: 1240), lead: 0),
            briefSettings("calendar-brief-off", size: CGSize(width: 1020, height: 1060), enabled: false),
        ]
    }
}
#endif
