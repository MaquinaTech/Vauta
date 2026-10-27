// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

// Links to earlier meetings (post-meeting actions, Part B): the suggestion rows under tasks and decisions, the confirmed ones, the dismissed
// list, the chains of Tasks mode and the brief. The links are written to the sample store with the store's own functions; no model runs.
// They are off in this release (`LinksRelease`); the scenes show them as they appear when a backend's gates pass.

@MainActor
extension SnapshotScenes {
    private static let linksSize = CGSize(width: 1040, height: 760)

    /// The featured meeting open on `tab`, after `seed` ran on the sample store.
    private static func linkMeeting(_ name: String, tab: MeetingsModel.DetailTab, size: CGSize = linksSize,
                                    seed: @escaping @MainActor (SampleWorld) async -> Void) -> SnapshotScene {
        meetingsScene(name, size: size) { history, fixture in
            await seed(fixture.world)
            await history.reload()
            history.selectedID = fixture.world.featuredMeetingID
            await history.loadDetail()
            history.tab = tab
        }
    }

    /// Tasks mode after `seed`.
    private static func linkTasksMode(_ name: String, size: CGSize = linksSize, seed: @escaping @MainActor (SampleWorld) async -> Void,
                                      apply: @escaping @MainActor (MeetingsModel) async -> Void = { _ in }) -> SnapshotScene {
        meetingsScene(name, size: size) { history, fixture in
            await seed(fixture.world)
            history.mode = .tasks
            await history.reloadMode()
            await apply(history)
        }
    }

    static var linkScenes: [SnapshotScene] {
        [
            // 27, 28: under a task, as a question, and once the person confirmed it.
            linkMeeting("tasks-link-suggestion", tab: .tasks) { world in _ = try? await world.seedTaskLink(.suggested) },
            linkMeeting("tasks-link-suggestion-earlier-done", tab: .tasks) { world in _ = try? await world.seedTaskLink(.suggested, earlierDone: true) },
            linkMeeting("tasks-link-confirmed", tab: .tasks) { world in _ = try? await world.seedTaskLink(.confirmed) },
            // 29, 30: under decisions in the Minutes tab; a "same" suggestion and a confirmed one, then "different".
            linkMeeting("summary-decision-same", tab: .summary) { world in
                _ = try? await world.seedDecisionLink(.same, .suggested)
                try? await world.seedSecondDecisionLink(.confirmed)
            },
            linkMeeting("summary-decision-changes", tab: .summary) { world in _ = try? await world.seedDecisionLink(.changes, .suggested) },
            linkMeeting("summary-decision-changes-confirmed", tab: .summary) { world in _ = try? await world.seedDecisionLink(.changes, .confirmed) },
            // 38: the earlier decision is one a check doubted: its mark shows on the row.
            linkMeeting("summary-link-earlier-unconfirmed", tab: .summary) { world in _ = try? await world.seedDecisionLink(.same, .suggested, earlierUnconfirmed: true) },
            // 39: the group of other possible items has no link rows, while a main decision has one.
            meetingsScene("summary-other-items-no-link", size: CGSize(width: 1040, height: 1500)) { history, fixture in
                _ = try? await fixture.world.seedDecisionLink(.same, .suggested)
                try? await fixture.world.seedRankedOutItems()
                await history.reload()
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
                history.otherItemsExpanded = true
            },
            // 31: the pairs the person said are not the same, with Restore.
            linkMeeting("suggestions-dismissed-links", tab: .suggestions) { world in try? await world.seedDismissedLinks() },
            // 32, 33: Tasks mode, one row for the chain; its earlier mentions listed.
            linkTasksMode("tasks-chain-collapsed", seed: { world in _ = try? await world.seedTaskChain() }),
            linkTasksMode("tasks-chain-expanded", seed: { world in _ = try? await world.seedTaskChain() }, apply: { history in
                history.expandedChains = Set(history.openChains.keys)
            }),
            // Suggestions waiting under a meeting's tasks are one link on its title in Tasks mode.
            linkTasksMode("tasks-pending-suggestions", seed: { world in
                _ = try? await world.seedTaskLink(.suggested)
                try? await world.seedSecondTaskLink()
            }),
            chainDonePrompt,
            chainDueMismatch,
            settingsScene("models-search-items-line", .models, size: searchModelSize, showsLinksLine: true) { recorder, fixture in
                fixture.settings.models.installSnapshotState(recorder, discovered: [], saved: ModelProviderSettings(chat: .onDevice, embeddings: .onDeviceModel))
                fixture.settings.models.physicalMemory = 16 * ModelRecommendation.gibibyte
                recorder.searchModel.installSnapshotState(modelStatus(.ready, installed: installedBytes), index: doneIndex(), choice: .onDeviceModel, retiredNotice: false)
            },
        ]
    }

    /// 34: marking a chain done asks whether the earlier mentions go too. A sheet of its own: a window snapshot cannot hold the sheet.
    private static var chainDonePrompt: SnapshotScene {
        SnapshotScene(name: "meetings-tasks-chain-done-prompt", size: CGSize(width: 420, height: 200), fitHeight: true, isSheet: true) { fixture in
            let recorder = await fixture.makeRecorder()
            guard let history = recorder.history else { return .init(view: AnyView(EmptyView())) }
            history.llm = nil
            _ = try? await fixture.world.seedTaskChain()
            history.mode = .tasks
            await history.reload()
            await history.reloadMode()
            guard let chain = history.openChains.values.first else { return .init(view: AnyView(EmptyView())) }
            return .init(view: AnyView(ChainDoneSheet(model: history, chain: chain).background(Color(nsColor: .windowBackgroundColor))))
        }
    }

    /// 35: the reminder of the oldest mention is due on another day than the newest: the row says so and offers Open in Reminders.
    private static var chainDueMismatch: SnapshotScene {
        SnapshotScene(name: "meetings-tasks-chain-due-mismatch", size: linksSize) { fixture in
            guard let stage = await stage(fixture, seed: false) else { return .init(view: AnyView(EmptyView())) }
            let ids = (try? await fixture.world.seedTaskChain(dueDifference: true)) ?? []
            stage.history.mode = .tasks
            await stage.history.reload()
            await stage.history.reloadMode()
            // The reminder is the middle mention's, due on the day it said; the newest says another day.
            if ids.count == 3, let middle = (try? await stage.history.store.tasks(ids: [ids[1]]))?.first {
                _ = await addReminder(stage, middle, due: middle.displayDay())
            }
            await stage.actions.refresh(tasks: stage.history.openTasks, readBack: true)
            let view = MeetingsWindow(model: stage.history, recorder: stage.recorder, preferences: fixture.preferences, settings: fixture.settings)
            return .init(view: AnyView(view), title: String(localized: "Meetings", comment: "Window title"), after: {
                stage.history.mode = .tasks
                await stage.actions.refresh(tasks: stage.history.openTasks, readBack: true)
            })
        }
    }
}
#endif
