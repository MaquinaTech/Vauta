// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

/// Post-meeting actions: the Tasks tab with the reminders' states, the Follow-up sheet and its editors, the email, the panel card and
/// Settings. Every state is built on the sample store with a `FakeActionWriter`: nothing reads or writes Reminders, Calendar or Mail.
@MainActor
extension SnapshotScenes {
    // MARK: Fixtures

    private static var retainedStage: ActionsStage?

    /// Everything one scene works with.
    struct ActionsStage {
        let recorder: RecorderModel
        let history: MeetingsModel
        let actions: ActionsModel
        let fake: FakeActionWriter
        let fixture: SnapshotFixture
        var tasks: [TaskItem] = []
        var meetingDay: DueDay { DueDay.containing(fixture.world.startDate(ofMeeting: 0), in: .current) }
    }

    /// The Meetings window's model on the sample store, the featured meeting open, a fake writer installed and the actions
    /// preferences back at their defaults. `tasks` are the featured meeting's (the original two and the ones the scenes add).
    static func stage(_ fixture: SnapshotFixture, meeting index: Int = 0, copyProtection: Bool = false, reminders: ActionAccess = .full,
                              events: ActionAccess = .full, seed: Bool = true) async -> ActionsStage? {
        let recorder = await fixture.makeRecorder()
        guard let history = recorder.history else { return nil }
        try? await fixture.world.restoreTranscript()
        if seed { try? await fixture.world.seedActionTasks() } else { try? await fixture.world.resetActions() }
        try? await fixture.world.seedAddresses()
        let prefs = fixture.preferences
        prefs.copyProtection = copyProtection
        let defaults = prefs.actions
        defaults.reminderListID = nil; defaults.reminderListName = nil; defaults.lastReminderListID = nil
        defaults.eventCalendarID = nil; defaults.eventCalendarName = nil; defaults.lastEventCalendarID = nil
        defaults.alertMinute = nil; defaults.includeMeetingName = true; defaults.calendarWriteNoticeShown = true
        defaults.followUpCardEnabled = true; defaults.emailMode = .one; defaults.emailSummary = false
        defaults.emailOpenQuestions = true; defaults.emailUnconfirmed = false
        history.llm = nil
        history.preferences = prefs
        await history.reload()
        let id = fixture.world.meetingIDs[index]
        history.selectedID = id
        await history.loadDetail()
        let fake = FakeActionWriter(reminderLists: SampleItems.reminderLists(fixture.language), calendars: SampleItems.calendars(fixture.language))
        fake.setAccess(.reminder, reminders)
        fake.setAccess(.event, events)
        history.actions.use(writer: fake)
        history.actions.forgetEverything()
        history.actions.caches = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-snapshots-handoff", isDirectory: true)
        var out = ActionsStage(recorder: recorder, history: history, actions: history.actions, fake: fake, fixture: fixture)
        out.tasks = history.tasks.sorted { $0.id < $1.id }
        // The editors read the window's model through a weak reference: the scene keeps it alive until the next one.
        retainedStage = out
        return out
    }

    /// The sheet's open tasks in the order they were created. The sheet itself sorts by owner name, which differs by language; the
    /// scenes tick by creation order so every language renders the same states.
    private static func openByCreation(_ stage: ActionsStage) -> [TaskItem] { (stage.actions.sheet?.tasks ?? []).sorted { $0.id < $1.id } }

    static func addReminder(_ stage: ActionsStage, _ task: TaskItem, due: DueDay? = nil, list: String = "list-work") async -> CreatedAction? {
        let meeting = await stage.actions.facts(meetingID: task.meetingID)
        var draft = ReminderDraft.make(task: task, selfEntityID: await stage.actions.selfEntityID(), containerID: list, meetingTitle: meeting?.title,
                                       meetingDate: meeting?.start, meetingTimeZone: meeting?.zone ?? .current)
        if let due { draft.dueDay = due }
        if case .added(let row) = await stage.actions.service.addReminder(task: task, draft: draft) { return row }
        return nil
    }

    /// A task confirmed as the same in three meetings, with a reminder on the middle mention (the newest is the featured meeting's last task).
    private static func seedChainReminder(_ stage: ActionsStage) async {
        guard let ids = try? await stage.fixture.world.seedTaskChain(), ids.count == 3,
              let middle = (try? await stage.history.store.tasks(ids: [ids[1]]))?.first else { return }
        _ = await addReminder(stage, middle)
    }

    /// One task in each state the Tasks tab can show, and one with no reminder.
    private static func seedStates(_ stage: ActionsStage) async {
        let tasks = stage.tasks
        guard tasks.count >= 5 else { return }
        _ = await addReminder(stage, tasks[0])
        // The reminder the person already had carries the task's own due day, so the cell shows the link and not a mismatch.
        stage.fake.seedReminder(tasks[1].text, day: tasks[1].dueDay)
        if let item = await stage.fake.incompleteReminders(in: "list-work").first {
            _ = await stage.actions.service.useExisting(task: tasks[1], finding: .existing(item))
        }
        if let row = await addReminder(stage, tasks[2]), let id = row.itemID { stage.fake.deleteExternally(id) }
        if let row = await addReminder(stage, tasks[3]), let id = row.itemID { stage.fake.completeExternally(id) }
        if let row = await addReminder(stage, tasks[4], due: stage.meetingDay.adding(days: 9)), let id = row.itemID {
            stage.fake.setDueExternally(id, stage.meetingDay.adding(days: 2))
        }
        await stage.history.refreshTasks()
        await stage.actions.refresh(tasks: stage.history.tasks, readBack: true)
    }

    // MARK: Scene builders

    /// The Meetings window on the Tasks tab, with `apply` run once it has loaded.
    private static func tasksWindow(_ name: String, copyProtection: Bool = false, apply: @escaping @MainActor (ActionsStage) async -> Void) -> SnapshotScene {
        SnapshotScene(name: "meetings-\(name)", size: meetingsSize) { fixture in
            guard let stage = await stage(fixture, copyProtection: copyProtection) else { return .init(view: AnyView(EmptyView())) }
            stage.history.tab = .tasks
            let view = MeetingsWindow(model: stage.history, recorder: stage.recorder, preferences: fixture.preferences, settings: fixture.settings)
            return .init(view: AnyView(view), title: String(localized: "Meetings", comment: "Window title"), after: {
                stage.history.tab = .tasks
                await apply(stage)
            })
        }
    }

    /// The reminder editor, as a sheet. `pick` is the index of the task it opens for; `prepare` runs before, `afterOpen` once it is open.
    private static func reminderEditorScene(_ name: String, reminders: ActionAccess = .full, copyProtection: Bool = false, pick: Int = 0,
                                            prepare: @escaping @MainActor (ActionsStage, TaskItem) async -> Void = { _, _ in },
                                            choose: (@MainActor (ActionsStage) async -> TaskItem?)? = nil,
                                            afterOpen: @escaping @MainActor (ActionsStage) async -> Void = { _ in }) -> SnapshotScene {
        SnapshotScene(name: "meetings-\(name)", size: CGSize(width: ReminderEditor.width, height: 400), fitHeight: true, isSheet: true) { fixture in
            guard let stage = await stage(fixture, copyProtection: copyProtection, reminders: reminders), stage.tasks.count > pick else { return .init(view: AnyView(EmptyView())) }
            let chosen = stage.tasks[pick]
            await prepare(stage, chosen)
            // The newest task with that text (a scene may have replaced it).
            var now = ((try? await stage.history.store.tasks(fixture.world.featuredMeetingID)) ?? []).filter { $0.text == chosen.text }.max { $0.id < $1.id } ?? chosen
            if let choose {
                // The scene names the task it needs (the one carrying a mark, or one added for it): none, and the scene stays empty.
                guard let picked = await choose(stage) else { return .init(view: AnyView(EmptyView())) }
                now = picked
            }
            await stage.actions.openReminderEditor(now)
            await afterOpen(stage)
            return .init(view: AnyView(EditorHost(actions: stage.actions).background(Color(nsColor: .windowBackgroundColor))))
        }
    }

    private struct EditorHost: View {
        @Bindable var actions: ActionsModel
        var body: some View {
            if let state = actions.reminderEditor { ReminderEditor(actions: actions, state: state, showInTranscript: { _ in }, openSystemSettings: {}) }
        }
    }

    private static func eventEditorScene(_ name: String, events: ActionAccess = .full, prepare: @escaping @MainActor (ActionsStage) async -> FollowUp?) -> SnapshotScene {
        SnapshotScene(name: "meetings-\(name)", size: CGSize(width: EventEditor.width, height: 420), fitHeight: true, isSheet: true) { fixture in
            guard let stage = await stage(fixture, events: events) else { return .init(view: AnyView(EmptyView())) }
            try? await stage.history.store.storeDetectedFollowUps([], meetingID: fixture.world.featuredMeetingID)
            let follow = await prepare(stage)
            await stage.actions.openFollowUp(meetingID: fixture.world.featuredMeetingID)
            await stage.actions.openEventEditor(follow)
            guard let state = stage.actions.eventEditor else { return .init(view: AnyView(EmptyView())) }
            let view = EventEditor(actions: stage.actions, state: state).background(Color(nsColor: .windowBackgroundColor))
            return .init(view: AnyView(view))
        }
    }

    /// `day`, or the Monday after it when it falls on a Saturday or a Sunday.
    private static func workday(_ day: DueDay) -> DueDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        switch calendar.component(.weekday, from: day.utcNoonDate) {
        case 7: return day.adding(days: 2)
        case 1: return day.adding(days: 1)
        default: return day
        }
    }

    /// A detected follow-up meeting in the featured meeting (invented): on `days` after the meeting, said as a date or inferred from a weekday.
    private static func addFollowUp(_ stage: ActionsStage, days: Int, inferred: Bool, minute: Int?, segment: Int, title: String? = nil) async -> FollowUp? {
        let world = stage.fixture.world
        let store = stage.history.store
        let ids = world.featuredSegmentIDs
        let meetingTitle = (try? await store.meeting(world.featuredMeetingID))?.displayTitle ?? ""
        let title = title ?? EventDraft.defaultTitle(meeting: meetingTitle)
        // A work meeting is followed by a meeting on a working day, whatever day the scenes are rendered on.
        // A follow-up is always still ahead: when the render day is far from the featured meeting, the day moves forward (a weekday
        // phrase then names the weekday of that day), so the sheet never offers to add a meeting that is today or already past.
        let ahead = DueDay.containing(AppClock.now, in: .current).adding(days: days > 6 ? 7 : 2)
        let day = workday(max(stage.meetingDay.adding(days: days), ahead))
        // The line the follow-up was found in says it, in the language being rendered.
        try? await world.sayFollowUp(segmentIndex: segment, day: day, minuteOfDay: minute, weekday: inferred, meetingDay: stage.meetingDay)
        guard let id = try? await store.addFollowUp(world.featuredMeetingID, title: title, day: day, dayInferred: inferred,
                                                    minuteOfDay: minute, durationMinutes: 30, segmentID: ids[min(segment, ids.count - 1)], t: Double(segment) * 38,
                                                    source: .detected) else { return nil }
        return ((try? await store.followUps(world.featuredMeetingID)) ?? []).first { $0.id == id }
    }

    private static func followUpScene(_ name: String, height: CGFloat = 1500, meeting: Int = 0, copyProtection: Bool = false,
                                      prepare: @escaping @MainActor (ActionsStage) async -> Void,
                                      afterOpen: @escaping @MainActor (ActionsStage) async -> Void = { _ in }) -> SnapshotScene {
        SnapshotScene(name: "meetings-\(name)", size: CGSize(width: FollowUpSheet.width, height: 400), fitHeight: true, isSheet: true) { fixture in
            guard let stage = await stage(fixture, meeting: meeting, copyProtection: copyProtection, seed: meeting == 0) else { return .init(view: AnyView(EmptyView())) }
            let id = fixture.world.meetingIDs[meeting]
            try? await stage.history.store.storeDetectedFollowUps([], meetingID: id)
            await prepare(stage)
            await stage.actions.openFollowUp(meetingID: id)
            await afterOpen(stage)
            return .init(view: AnyView(FollowUpHost(actions: stage.actions, height: height).background(Color(nsColor: .windowBackgroundColor))))
        }
    }

    /// The sheet as it is drawn now (it reads the model on every change, as the window does).
    private struct FollowUpHost: View {
        @Bindable var actions: ActionsModel
        let height: CGFloat
        var body: some View {
            if let state = actions.sheet { FollowUpSheet(actions: actions, state: state, maxHeight: height) }
        }
    }

    private struct EmailHost: View {
        @Bindable var actions: ActionsModel
        var body: some View {
            if let state = actions.sheet {
                EmailDraftView(actions: actions, state: state.email, locked: actions.copyProtected)
                    .padding(20)
                    .frame(width: FollowUpSheet.width)
            }
        }
    }

    private static func emailScene(_ name: String, copyProtection: Bool = false, longTasks: Bool = false,
                                   prepare: @escaping @MainActor (ActionsStage) async -> Void = { _ in }) -> SnapshotScene {
        SnapshotScene(name: "meetings-\(name)", size: CGSize(width: FollowUpSheet.width, height: 400), fitHeight: true, isSheet: true) { fixture in
            guard let stage = await stage(fixture, copyProtection: copyProtection) else { return .init(view: AnyView(EmptyView())) }
            // The email draft is held in this release (`ActionsRelease`); these scenes show it as it appears when it is switched on.
            stage.actions.emailDraftAvailable = true
            let id = fixture.world.featuredMeetingID
            try? await stage.history.store.storeDetectedFollowUps([], meetingID: id)
            if longTasks {
                // Long tasks of their own: distinct sentences with an owner and a date each, in the language being rendered.
                try? await fixture.world.seedLongTasks()
                await stage.history.refreshTasks()
            }
            // The one the Follow-up sheet shows as already in Calendar (Saturday, a week later, 3 pm), said in the same line of the transcript.
            _ = await addFollowUp(stage, days: 13, inferred: false, minute: 15 * 60, segment: 7)
            // The follow-up meeting was added to Calendar, so the email names it.
            if let follow = ((try? await stage.history.store.followUps(id)) ?? []).first, let meeting = await stage.actions.facts(meetingID: id),
               let draft = EventDraft.make(from: follow, containerID: "cal-work", meetingTitle: meeting.title, meetingDate: meeting.start, meetingDuration: meeting.duration, timeZone: meeting.zone),
               case .added = await stage.actions.service.addEvent(followUp: follow, draft: draft) {
                try? await stage.history.store.setFollowUpState(follow.id, .done)
            }
            await stage.actions.openFollowUp(meetingID: id)
            await prepare(stage)
            return .init(view: AnyView(EmailHost(actions: stage.actions).background(Color(nsColor: .windowBackgroundColor))))
        }
    }

    private static func dialogScene(_ name: String, title: String, message: String, buttons: [SnapshotAlert.Button], defaultIndex: Int = 1) -> SnapshotScene {
        SnapshotScene(name: name, size: CGSize(width: 260, height: 160), isSheet: true) { _ in
            .init(view: AnyView(EmptyView()), alert: SnapshotAlert(title: title, message: message, buttons: buttons, defaultIndex: defaultIndex))
        }
    }

    // MARK: Scenes

    static var actionsScenes: [SnapshotScene] {
        [
            // The Tasks tab: every status the reminder column can show.
            tasksWindow("tasks-actions") { stage in
                await seedStates(stage)
            },
            tasksWindow("tasks-undo-bar") { stage in
                guard let task = stage.tasks.last, let row = await addReminder(stage, task) else { return }
                await stage.history.refreshTasks()
                await stage.actions.refresh(tasks: stage.history.tasks)
                stage.actions.showUndoBar(text: String(localized: "Added to Reminders · \(SampleItems.forLanguage(stage.fixture.language).list)", comment: "Bar after adding a reminder; the argument is the list and its account, such as Work · iCloud"), rows: [row], kind: .reminder)
            },
            // The reminder editor.
            reminderEditorScene("tasks-reminder-editor"),
            reminderEditorScene("tasks-reminder-editor-alert", prepare: { stage, _ in stage.fixture.preferences.actions.alertMinute = ReminderDraft.defaultAlertMinute }),
            // The task that carries the "could not confirm" mark (not the first one), so the warning and Show in Transcript are drawn.
            reminderEditorScene("tasks-reminder-editor-unconfirmed", prepare: { stage, _ in try? await stage.fixture.world.seedVerificationMarks() },
                                choose: { stage in
                ((try? await stage.history.store.tasks(stage.fixture.world.featuredMeetingID)) ?? []).first { $0.unconfirmed }
            }),
            // The first task owned by a speaker nobody has named, the owner not confirmed (the task is): the editor warns about the owner only.
            reminderEditorScene("tasks-reminder-editor-speaker-owner", prepare: { stage, _ in try? await stage.fixture.world.seedSpeakerOwner() },
                                choose: { stage in
                ((try? await stage.history.store.tasks(stage.fixture.world.featuredMeetingID)) ?? []).first { $0.ownerSpeakerID != nil }
            }),
            // A stored due day nobody said (a model copying a date): it is left out and the editor says so.
            reminderEditorScene("tasks-reminder-editor-due-skipped", prepare: { stage, _ in
                _ = try? await stage.history.store.addTask(stage.fixture.world.featuredMeetingID, text: SampleItems.forLanguage(stage.fixture.language).venueTask,
                                                          due: SampleItems.skippedDueDay?.startOfDay(in: .current), dueDay: SampleItems.skippedDueDay, source: "llm")
            }, choose: { stage in
                ((try? await stage.history.store.tasks(stage.fixture.world.featuredMeetingID)) ?? []).first { $0.dueDay == SampleItems.skippedDueDay }
            }),
            reminderEditorScene("tasks-reminder-editor-access-ask", reminders: .notDetermined),
            reminderEditorScene("tasks-reminder-editor-access-denied", reminders: .denied),
            reminderEditorScene("tasks-reminder-editor-copyprotected", copyProtection: true),
            reminderEditorScene("tasks-duplicate-found", prepare: { stage, task in stage.fake.seedReminder(task.text) }),
            // The person confirmed this task is the same as one from an earlier meeting, and that one already has a reminder: Use This Reminder or Add Anyway.
            reminderEditorScene("tasks-reminder-editor-chain-duplicate", prepare: { stage, _ in await seedChainReminder(stage) }, choose: { stage in
                ((try? await stage.history.store.tasks(stage.fixture.world.featuredMeetingID)) ?? []).max { $0.id < $1.id }
            }),
            reminderEditorScene("tasks-orphan-found", pick: 2, prepare: { stage, task in
                _ = await addReminder(stage, task)
                try? await stage.history.store.deleteTask(task.id)
                _ = try? await stage.history.store.addTask(task.meetingID, text: task.text, ownerID: task.ownerID, due: task.due, segmentID: task.segmentID, t: task.t, source: "user")
            }),
            // After the macOS prompt was answered: the lists fill in and what was typed is still there.
            reminderEditorScene("tasks-reminder-editor-access-granted", reminders: .notDetermined, afterOpen: { stage in
                stage.actions.reminderEditor?.draft.title += " (v2)"
                stage.fake.setAccess(.reminder, .full)
                await stage.actions.applyReminderAccess()
            }),
            // The Follow-up sheet.
            followUpScene("followup-sheet-full", height: 2200, prepare: { stage in
                try? await stage.fixture.world.seedVerificationMarks()
                _ = await addFollowUp(stage, days: 6, inferred: true, minute: nil, segment: 6)
                if let second = await addFollowUp(stage, days: 13, inferred: false, minute: 15 * 60, segment: 7) {
                    stage.fake.seedEvent(second.title, on: second.day ?? stage.meetingDay, in: "cal-work")
                }
                // One task already added, and one the list already has.
                if let first = stage.tasks.first { _ = await addReminder(stage, first) }
                if stage.tasks.count > 2 { stage.fake.seedReminder(stage.tasks[2].text) }
            }, afterOpen: { stage in
                let open = openByCreation(stage)
                for task in open.dropFirst().prefix(3) { stage.actions.toggleTick(task) }
                await stage.actions.addTicked()
                stage.actions.dismissUndoBar()
                if let last = open.last { stage.actions.toggleTick(last) }
            }),
            followUpScene("followup-sheet-ticked", prepare: { stage in
                _ = await addFollowUp(stage, days: 6, inferred: true, minute: 10 * 60, segment: 6)
            }, afterOpen: { stage in
                for task in openByCreation(stage).prefix(2) { stage.actions.toggleTick(task) }
            }),
            // The same chain in the Follow-up sheet: the newest mention is ticked and Add finds the reminder of the middle one.
            followUpScene("followup-sheet-chain-duplicate", height: 1300, prepare: { stage in await seedChainReminder(stage) }, afterOpen: { stage in
                if let newest = openByCreation(stage).last { stage.actions.toggleTick(newest) }
                await stage.actions.addTicked()
                stage.actions.dismissUndoBar()
            }),
            followUpScene("followup-sheet-duplicate", prepare: { stage in
                if stage.tasks.count > 2 { stage.fake.seedReminder(stage.tasks[2].text) }
            }, afterOpen: { stage in
                for task in openByCreation(stage).prefix(3) { stage.actions.toggleTick(task) }
                await stage.actions.addTicked()
                stage.actions.dismissUndoBar()
            }),
            // The bar after an Add, inside the sheet (the window behind it cannot be clicked while the sheet is open).
            followUpScene("followup-sheet-undo-bar", height: 1300, prepare: { _ in }, afterOpen: { stage in
                for task in openByCreation(stage).prefix(2) { stage.actions.toggleTick(task) }
                await stage.actions.addTicked()
            }),
            // A stored due day that is wrong (a model copying a date): the row says the reminder will have none.
            followUpScene("followup-sheet-due-skipped", height: 1300, prepare: { stage in
                _ = try? await stage.history.store.addTask(stage.fixture.world.featuredMeetingID, text: SampleItems.forLanguage(stage.fixture.language).venueTask,
                                                          due: SampleItems.skippedDueDay?.startOfDay(in: .current), dueDay: SampleItems.skippedDueDay, source: "llm")
            }, afterOpen: { stage in
                for task in openByCreation(stage).suffix(1) { stage.actions.toggleTick(task) }
            }),
            // A task owned by an unnamed speaker, the owner not confirmed: the glyph's help names the owner, not the whole task.
            followUpScene("followup-sheet-speaker-owner", height: 1300, prepare: { stage in try? await stage.fixture.world.seedSpeakerOwner() }),
            // Every suggested follow-up meeting marked "Not a Meeting": the sheet must not say that none was found.
            followUpScene("followup-sheet-dismissed", height: 1300, prepare: { stage in
                for (days, segment) in [(6, 6), (13, 7)] {
                    if let follow = await addFollowUp(stage, days: days, inferred: true, minute: nil, segment: segment) { try? await stage.history.store.setFollowUpState(follow.id, .dismissed) }
                }
            }),
            followUpScene("followup-sheet-empty", height: 900, meeting: 3, prepare: { _ in }),
            // The sheet while no follow-up meeting is looked for (the part is switched off): it does not say that none was mentioned.
            followUpScene("followup-sheet-by-hand", height: 1300, prepare: { stage in stage.actions.followUpDetectionAvailable = false }),
            // Copy protection on: the batch button carries the same one-line warning as the editors.
            followUpScene("followup-sheet-copyprotected", height: 1300, copyProtection: true, prepare: { _ in }, afterOpen: { stage in
                for task in openByCreation(stage).prefix(2) { stage.actions.toggleTick(task) }
            }),
            followUpScene("followup-sheet-access", height: 1100, prepare: { stage in stage.fake.setAccess(.reminder, .notDetermined) }),
            followUpScene("followup-sheet-denied", height: 1100, prepare: { stage in stage.fake.setAccess(.reminder, .denied) }),
            // The event editor.
            eventEditorScene("followup-event-editor") { stage in await addFollowUp(stage, days: 6, inferred: true, minute: nil, segment: 6) },
            eventEditorScene("followup-event-new") { _ in nil },
            eventEditorScene("followup-event-existing") { stage in
                let follow = await addFollowUp(stage, days: 13, inferred: false, minute: 15 * 60, segment: 7)
                if let follow { stage.fake.seedEvent(follow.title, on: follow.day ?? stage.meetingDay, in: "cal-work") }
                return follow
            },
            eventEditorScene("followup-event-ics", events: .notDetermined) { stage in await addFollowUp(stage, days: 13, inferred: false, minute: 15 * 60, segment: 7) },
            eventEditorScene("followup-event-first-write-notice") { stage in
                stage.fixture.preferences.actions.calendarWriteNoticeShown = false
                return await addFollowUp(stage, days: 13, inferred: false, minute: 15 * 60, segment: 7)
            },
            // The email.
            emailScene("followup-email-one"),
            emailScene("followup-email-per-owner") { stage in await stage.actions.setEmailMode(.perOwner) },
            emailScene("followup-email-external-recipient") { stage in
                guard let draft = stage.actions.sheet?.email.current else { return }
                for recipient in stage.actions.sheet?.email.recipients.recipients ?? [] { stage.actions.toggleRecipient(recipient, draft: draft) }
            },
            emailScene("followup-email-copyprotected", copyProtection: true),
            emailScene("followup-email-long", longTasks: true) { stage in
                guard let draft = stage.actions.sheet?.email.current else { return }
                for recipient in stage.actions.sheet?.email.recipients.recipients ?? [] { stage.actions.toggleRecipient(recipient, draft: draft) }
            },
            // Removing and deleting.
            SnapshotScene(name: "meetings-remove-reminder", size: CGSize(width: 260, height: 160), isSheet: true) { fixture in
                let item = SampleItems.forLanguage(fixture.language)
                let title = String(localized: "Remove “\(item.reminder)” from \(item.list)?", comment: "Confirmation title; the arguments are a reminder or event title and its list or calendar")
                return .init(view: AnyView(EmptyView()),
                             alert: SnapshotAlert(title: title, message: String(localized: "Only the reminder Vauta added is removed."),
                                                  buttons: [.init(title: String(localized: "Remove"), destructive: true), .init(title: String(localized: "Cancel", comment: "Alert button"))], defaultIndex: 1))
            },
            SnapshotScene(name: "meetings-remove-reminder-edited", size: CGSize(width: 260, height: 160), isSheet: true) { fixture in
                let item = SampleItems.forLanguage(fixture.language)
                let title = String(localized: "Remove “\(item.reminder)” from \(item.list)?", comment: "Confirmation title; the arguments are a reminder or event title and its list or calendar")
                return .init(view: AnyView(EmptyView()),
                             alert: SnapshotAlert(title: title, message: String(localized: "You changed this reminder in Reminders after Vauta added it."),
                                                  buttons: [.init(title: String(localized: "Remove"), destructive: true), .init(title: String(localized: "Cancel", comment: "Alert button"))], defaultIndex: 1))
            },
            // An event-only meeting: no reminder made Vauta read the calendar's name, so the title names the event alone.
            SnapshotScene(name: "meetings-remove-event-unnamed", size: CGSize(width: 260, height: 160), isSheet: true) { fixture in
                let title = String(localized: "Remove “\(SampleItems.followUpEventTitle(fixture))”?", comment: "Confirmation title when the list or calendar cannot be named; the argument is a reminder or event title")
                return .init(view: AnyView(EmptyView()),
                             alert: SnapshotAlert(title: title, message: String(localized: "Only the event Vauta added is removed."),
                                                  buttons: [.init(title: String(localized: "Remove"), destructive: true), .init(title: String(localized: "Cancel", comment: "Alert button"))], defaultIndex: 1))
            },
            SnapshotScene(name: "meetings-delete-with-actions", size: CGSize(width: 260, height: 160), isSheet: true) { fixture in
                let meeting = try? await fixture.world.store.meeting(fixture.world.featuredMeetingID)
                guard let meeting else { return .init(view: AnyView(EmptyView())) }
                let world = fixture.world
                // Earlier scenes added tasks to this meeting; the alert counts the pristine sample, the same as its Minutes and Tasks tabs show.
                try? await world.resetActions()
                // The counts of the featured meeting itself, not invented ones.
                let segments = (try? await world.store.segments(of: meeting.id).count) ?? 0
                let decisions = (try? await world.store.decisions(meeting.id).count) ?? 0
                let tasks = (try? await world.store.tasks(meeting.id).count) ?? 0
                let pending = PendingDeletion.meeting(meeting, segments: segments, decisions: decisions, tasks: tasks, kept: (reminders: 3, events: 1))
                return .init(view: AnyView(EmptyView()),
                             alert: SnapshotAlert(title: pending.title, message: pending.message,
                                                  buttons: [.init(title: pending.confirmLabel, destructive: true), .init(title: String(localized: "Cancel", comment: "Alert button"))], defaultIndex: 1))
            },
            // The menu-bar panel.
            panelCard("panel-followup-card", [FollowUpPending(meetingID: 1, readyAt: AppClock.now, tasks: 4, followUps: 1)]),
            panelCard("panel-followup-card-tasks-only", [FollowUpPending(meetingID: 1, readyAt: AppClock.now, tasks: 3, followUps: 0)]),
            panelCard("panel-followup-card-two-meetings", [FollowUpPending(meetingID: 1, readyAt: AppClock.now.addingTimeInterval(-1_800), tasks: 4, followUps: 1),
                                                           FollowUpPending(meetingID: 2, readyAt: AppClock.now, tasks: 2, followUps: 0)]),
            panelCard("panel-followup-card-locked", [FollowUpPending(meetingID: 1, readyAt: AppClock.now, tasks: 4, followUps: 1)], locked: true),
            // Settings.
            settingsScene("calendar-reminders-after-meetings", .calendar, size: CGSize(width: 1020, height: 1320)) { recorder, fixture in
                recorder.calendar.installSnapshotState(enabled: true, access: true, calendars: sampleCalendars(fixture), selected: ["work", "team"])
                recorder.brief.prefs.installSnapshotDefaults(enabled: true)
                let prefs = fixture.preferences.actions
                prefs.alertMinute = nil; prefs.reminderListID = nil; prefs.eventCalendarID = nil; prefs.includeMeetingName = true
                fixture.settings.afterMeetings.installSnapshotState(reminders: .full, events: .full,
                                                                    lists: SampleItems.reminderLists(fixture.language), calendars: SampleItems.calendars(fixture.language))
            },
            settingsScene("calendar-reminders-after-meetings-not-asked", .calendar, size: CGSize(width: 1020, height: 1400)) { recorder, fixture in
                recorder.calendar.installSnapshotState(enabled: false, access: false, calendars: [], selected: [])
                recorder.brief.prefs.installSnapshotDefaults(enabled: false)
                fixture.preferences.actions.alertMinute = nil
                fixture.settings.afterMeetings.installSnapshotState(reminders: .notDetermined, events: .notDetermined, lists: [], calendars: [])
            },
            settingsScene("calendar-reminders-after-meetings-denied", .calendar, size: CGSize(width: 1020, height: 1400)) { recorder, fixture in
                recorder.calendar.installSnapshotState(enabled: false, access: false, calendars: [], selected: [])
                recorder.brief.prefs.installSnapshotDefaults(enabled: false)
                fixture.preferences.actions.alertMinute = nil
                fixture.settings.afterMeetings.installSnapshotState(reminders: .denied, events: .denied, lists: [], calendars: [])
            },
            settingsScene("general-followup-card", .general, size: CGSize(width: 1020, height: 900)) { _, fixture in
                fixture.preferences.actions.followUpCardEnabled = true
            },
        ]
    }

    private static func panelCard(_ name: String, _ pending: [FollowUpPending], locked: Bool = false) -> SnapshotScene {
        storePanelScene(String(name.dropFirst("panel-".count))) { recorder, _ in
            recorder.followUpPending = pending
            recorder.historyUnlocked = !locked
            recorder.preferences.actions.followUpCardEnabled = true
        }
    }
}
#endif
