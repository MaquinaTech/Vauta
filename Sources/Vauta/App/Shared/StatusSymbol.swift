// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI

/// The one set of symbols for states (panel, Settings, onboarding, model guide, backup,
/// Meetings). Colour never carries the state alone: every use also has text or an
/// accessibility label. `info` is the outlined, secondary-coloured `info.circle` everywhere; inside a banner of the
/// menu-bar panel the label style fills it, and the tinted card around it carries the notice.
enum StatusSymbol: CaseIterable {
    case ok, warning, error, info, pending
    /// Something that is working right now (a request in flight).
    case running
    /// Something that is off or not reachable, without being a failure of Vauta.
    case inactive

    /// "This Mac" wherever it is named (Network Activity, the model server card, the model guide): one neutral
    /// symbol, since it may be a laptop, a mini or an iMac.
    static let thisMac = "display"

    var name: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.circle.fill"
        case .info: "info.circle"
        case .pending: "circle.dotted"
        case .running: "ellipsis.circle"
        case .inactive: "minus.circle"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .error: .red
        case .info, .pending, .running, .inactive: .secondary
        }
    }

    /// The symbol in its colour, hidden from VoiceOver (the text beside it says the state).
    var image: some View {
        Image(systemName: name).foregroundStyle(color).accessibilityHidden(true)
    }
}
