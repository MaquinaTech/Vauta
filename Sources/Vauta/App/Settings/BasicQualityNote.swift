// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI

/// Where the model-server guidance lives and how the Apple on-device model is
/// described wherever the provider is chosen or shown.
enum ModelQuality {
    static let guideURL = URL(string: "https://github.com/MaquinaTech/Vauta/blob/main/docs/MODEL_SERVERS.md")!

    static let helpURL = URL(string: "https://github.com/MaquinaTech/Vauta#readme")!

    /// The badge of Apple's on-device model.
    static var badge: String {
        String(localized: "Quick start · Basic quality", comment: "Badge of the Apple on-device model: zero setup, lower minutes quality than a 9B+ model server")
    }

    /// The same badge without its first word, for the one-line status row of the panel (the full badge is in its tooltip).
    static var shortBadge: String {
        String(localized: "Basic quality", comment: "Short badge of the Apple on-device model, in the panel's status row")
    }

    /// The recommendation to set up a model server, said the same way in the Meetings hint, Settings → Models
    /// and the last setup page: a title and a one-line reason. (The panel keeps its short `recommendation`.)
    /// Its glyph, the same wherever the recommendation appears (Meetings, Settings, the last setup page).
    static let recommendationSymbol = "arrow.up.circle.fill"

    static var recommendationTitle: String {
        String(localized: "Better minutes with a model server", comment: "Title of the recommendation to set up a model server")
    }

    static var recommendationReason: String {
        String(localized: "Install LM Studio or Ollama, and Vauta shows you the model that fits this Mac.",
               comment: "Reason under the recommendation to set up a model server")
    }

    /// The same, on a Mac with too little memory for a model server on it: the advice is a server on another computer.
    static var serverRecommendationReason: String {
        String(localized: "This Mac has too little memory for a good model. Use a model server on a Mac or PC with more memory.",
               comment: "Reason under the model-server recommendation on a Mac with less than 16 GB of memory")
    }

    static var recommendation: String {
        String(localized: "For better minutes, set up a model server.",
               comment: "Recommendation shown next to the Apple on-device model")
    }
}

/// Opens Settings → Models from places that don't have the Settings model.
private struct OpenModelsSettingsKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

/// Opens the "Set up a model server" guide in Settings → Models.
private struct OpenModelGuideKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    var openModelGuide: (@MainActor () -> Void)? {
        get { self[OpenModelGuideKey.self] }
        set { self[OpenModelGuideKey.self] = newValue }
    }


    var openModelsSettings: (@MainActor () -> Void)? {
        get { self[OpenModelsSettingsKey.self] }
        set { self[OpenModelsSettingsKey.self] = newValue }
    }
}

/// The one-time recommendation to connect a model server. It can be dismissed
/// for good and is never shown as an alert.
struct BasicQualityHint: View {
    @AppStorage("basicQualityHintDismissed") private var dismissed = false
    @Environment(\.openModelsSettings) private var openModels
    @Environment(\.openModelGuide) private var openGuide
    /// The size of the card's button; the Meetings page uses the small size of its other banners.
    var controlSize: ControlSize = .regular

    var body: some View {
        if !dismissed, let open = openGuide ?? openModels {
            RecommendationCard(title: ModelQuality.recommendationTitle,
                               reason: ModelQuality.recommendationReason,
                               symbol: ModelQuality.recommendationSymbol,
                               controlSize: controlSize,
                               actionTitle: openGuide != nil ? String(localized: "Set Up…", comment: "Button that opens the model server guide")
                                                             : SettingsModel.Pane.models.openTitle,
                               onDismiss: { dismissed = true },
                               action: { open() })
        }
    }
}
