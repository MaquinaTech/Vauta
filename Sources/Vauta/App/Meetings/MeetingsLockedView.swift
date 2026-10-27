// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI

/// The Meetings window while it is locked: one button to unlock.
struct MeetingsLockedView: View {
    let recorder: RecorderModel

    var body: some View {
        // The same locked state as Settings → Context.
        LockedStateView(title: Text("Meetings Are Locked"),
                        message: String(localized: "Unlock with Touch ID or your password to see your meetings."),
                        recorder: recorder) {
            Task { _ = await recorder.authorizeHistory() }
        }
        .frame(minWidth: MeetingsWindow.minimumSize.width, minHeight: MeetingsWindow.minimumSize.height)
        // The toolbar stays, disabled, so the title bar doesn't change height when the window unlocks.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {} label: { Label("Import Recording…", systemImage: "square.and.arrow.down") }
                    .disabled(true)
                    .help("Unlock your data first")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button {} label: { Label("Ask", systemImage: "text.bubble") }
                    .disabled(true)
                    .help("Unlock your data first")
            }
        }
    }
}
