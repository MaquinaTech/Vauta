// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension MeetingsModel {
    /// Before a restore: pending edits must not be written into the new store.
    func prepareForRestore() {
        draft = nil
        taskDraft = nil
        erasedTranslations()
    }

    /// After the store was replaced: forgets everything shown and reloads if the window is open.
    func storeWasReplaced() async {
        let showing = isShowing
        purgeVisible()
        selectedID = nil
        isShowing = showing
        if showing { await reload() }
    }
}
