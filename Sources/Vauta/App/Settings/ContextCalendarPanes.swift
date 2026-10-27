// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// Settings → Context: people, projects and glossary, behind Touch ID.
struct ContextPane: View {
    let recorder: RecorderModel

    var body: some View {
        if recorder.historyUnlocked, let context = recorder.context {
            ContextView(model: context)
        } else {
            LockedStateView(title: Text("Context Is Locked"),
                            message: String(localized: "Unlock with Touch ID or your password to edit people, projects and the glossary."),
                            recorder: recorder) {
                Task { _ = await recorder.authorizeHistory() }
            }
            // Centred in the pane: the detail column is top-leading, and this view would shrink to its content.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
