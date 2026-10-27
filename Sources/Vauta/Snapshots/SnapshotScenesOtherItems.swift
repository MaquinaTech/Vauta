// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

// The Minutes tab's group of items that ranked out ("Other possible items") in the states a person meets.

extension SnapshotScenes {
    // The open states are tall so the whole group shows (the real window scrolls).
    static var otherItemsScenes: [SnapshotScene] {
        [
            // The group of items that ranked out ("Other possible items") in the Minutes tab: collapsed (how it opens), open, many items,
            // long text, next to an item a check doubted (which keeps its "Unconfirmed" mark in the main list), and with nothing to
            // group (only a doubted item: the group is not there).
            meetingsScene("summary-other-items") { history, fixture in
                try? await fixture.world.seedRankedOutItems()
                await history.reload()
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
                history.otherItemsExpanded = false
            },
            meetingsScene("summary-other-items-open", size: CGSize(width: 1040, height: 1500)) { history, fixture in
                try? await fixture.world.seedRankedOutItems()
                await history.reload()
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
                history.otherItemsExpanded = true
            },
            meetingsScene("summary-other-items-many", size: CGSize(width: 1040, height: 1500)) { history, fixture in
                try? await fixture.world.seedRankedOutItems(extra: 9)
                await history.reload()
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
                history.otherItemsExpanded = true
            },
            meetingsScene("summary-other-items-long", size: CGSize(width: 1040, height: 1500)) { history, fixture in
                try? await fixture.world.seedRankedOutItems(long: true)
                await history.reload()
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
                history.otherItemsExpanded = true
            },
            meetingsScene("summary-other-items-and-doubted", size: CGSize(width: 1040, height: 1500)) { history, fixture in
                try? await fixture.world.seedRankedOutItems(doubted: true)
                await history.reload()
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
                history.otherItemsExpanded = true
            },
            meetingsScene("summary-other-items-owner", size: CGSize(width: 1040, height: 1500)) { history, fixture in
                try? await fixture.world.seedRankedOutItems(uncertainOwner: true)
                await history.reload()
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
                history.otherItemsExpanded = true
            },
            meetingsScene("summary-other-items-none") { history, fixture in
                try? await fixture.world.seedVerificationMarks()
                await history.reload()
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
            },
        ]
    }
}
#endif
