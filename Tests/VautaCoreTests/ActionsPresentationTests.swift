// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// What a task row says about its reminder, and when the panel's Follow-up card shows.
@Suite("Actions: presentation")
struct ActionsPresentationTests {
    private func row(_ state: ActionState, id: Int64 = 1) -> CreatedAction {
        CreatedAction(id: id, target: .reminder, source: .task, sourceID: 7, meetingID: 1, itemID: "r1", externalID: "e1", containerID: "list",
                      titleHash: "h", state: state, writtenAt: .now, updatedAt: .now)
    }

    @Test func eachStateOfTheLedgerAndTheReadBackHasItsOwnCell() {
        #expect(TaskActionState.make(row: nil, readBack: nil).kind == .none)
        #expect(TaskActionState.make(row: row(.created), readBack: .inReminders).kind == .inReminders)
        #expect(TaskActionState.make(row: row(.created), readBack: nil).kind == .inReminders, "without a read-back the ledger is believed")
        #expect(TaskActionState.make(row: row(.linked), readBack: .inReminders).kind == .linked)
        #expect(TaskActionState.make(row: row(.missing), readBack: nil).kind == .missing)
        #expect(TaskActionState.make(row: row(.created), readBack: .missing).kind == .missing)
        #expect(TaskActionState.make(row: row(.created), readBack: .doneInReminders).kind == .doneInReminders)
        let a = DueDay(year: 2026, month: 10, day: 10), b = DueDay(year: 2026, month: 10, day: 24)
        #expect(TaskActionState.make(row: row(.created), readBack: .dueDiffers(reminder: a, task: b)).kind == .dueDiffers(reminder: a, task: b))
        for state in [ActionState.removed, .orphaned, .handedOff, .writing] { #expect(TaskActionState.make(row: row(state), readBack: nil).kind == .none) }
    }

    @Test func removalIsOfferedOnlyForWhatVautaCreatedAndUnlinkOnlyForWhatItLinked() {
        let created = TaskActionState.make(row: row(.created), readBack: .inReminders)
        #expect(created.canRemove && !created.canUnlink && created.canOpen)
        let linked = TaskActionState.make(row: row(.linked), readBack: .inReminders)
        #expect(!linked.canRemove && linked.canUnlink && linked.canOpen)
        let missing = TaskActionState.make(row: row(.missing), readBack: nil)
        #expect(!missing.canRemove && !missing.canUnlink && !missing.canOpen)
        #expect(TaskActionState.make(row: row(.created), readBack: .doneInReminders).canRemove)
    }

    @Test func aTaskThatOnlyShowsAChainMembersReminderCannotRemoveOrUnlinkIt() {
        for ledger in [ActionState.created, .linked] {
            let borrowed = TaskActionState.make(row: row(ledger), readBack: .inReminders, borrowed: true)
            #expect(borrowed.isBorrowed && borrowed.canOpen && !borrowed.canRemove && !borrowed.canUnlink)
        }
    }

    @Test func theCardRules() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = FollowUpPending(meetingID: 1, readyAt: now.addingTimeInterval(-3 * 3600), tasks: 1, followUps: 0)
        let b = FollowUpPending(meetingID: 2, readyAt: now.addingTimeInterval(-60), tasks: 2, followUps: 1)
        #expect(FollowUpCard.content([a, b], now: now, recording: false, enabled: true) == .several(count: 2, newest: 2), "the older one is kept while the newest is within 2 hours")
        #expect(FollowUpCard.content([a], now: now, recording: false, enabled: true) == .hidden, "2 hours after the newest minutes")
        #expect(FollowUpCard.expiry([a, b]) == b.readyAt.addingTimeInterval(7200))
        #expect(FollowUpCard.content([b], now: now, recording: true, enabled: true) == .hidden)
        #expect(FollowUpCard.content([b], now: now, recording: false, enabled: false) == .hidden)
        #expect(FollowUpCard.content([b], now: now, recording: false, enabled: true).newestMeetingID == 2)
    }
}
