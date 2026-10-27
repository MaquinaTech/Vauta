// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI

extension ColorSchemeContrast {
    /// The contrast to draw with: the system's setting. In the diagnostics build, `Vauta render-ui` shows Increase Contrast
    /// this way (SwiftUI's own value cannot be set from outside), so the high-contrast borders and fills get reviewed.
    @MainActor var snapshotResolved: ColorSchemeContrast {
        #if VAUTA_DIAGNOSTICS
        if SnapshotMode.highContrast { return .increased }
        #endif
        return self
    }
}
