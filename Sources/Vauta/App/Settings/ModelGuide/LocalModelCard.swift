// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The compact invitation in Settings → Models while Apple's on-device model is in use.
struct LocalModelCard: View {
    let setUp: () -> Void
    private let enoughMemory: Bool
    private let metrics: RecommendationCard.Metrics
    private let controlSize: ControlSize
    private let reasonFont: Font

    init(physicalMemory: UInt64, metrics: RecommendationCard.Metrics = .standard, controlSize: ControlSize = .regular, reasonFont: Font = .callout, setUp: @escaping () -> Void) {
        self.setUp = setUp
        self.metrics = metrics
        self.controlSize = controlSize
        self.reasonFont = reasonFont
        enoughMemory = ModelRecommendation(physicalMemory: physicalMemory).hasRecommendation
    }

    /// The offer is the same for both memory sizes (better minutes with a model server), so it is one glyph wherever
    /// the recommendation appears; only the detail differs.
    private var symbol: String { ModelQuality.recommendationSymbol }

    var body: some View {
        RecommendationCard(
            title: ModelQuality.recommendationTitle,
            reason: enoughMemory ? ModelQuality.recommendationReason
                                 : ModelQuality.serverRecommendationReason,
            symbol: symbol,
            controlSize: controlSize,
            reasonFont: reasonFont,
            metrics: metrics,
            actionTitle: enoughMemory ? String(localized: "Set Up…", comment: "Button that opens the model server guide")
                                      : String(localized: "See Options…", comment: "Button that opens the model guide on a Mac with little memory"),
            actionHelp: enoughMemory ? String(localized: "Open the guide to set up a model server", comment: "Tooltip")
                                     : String(localized: "See ways to get better minutes on this Mac", comment: "Tooltip of the button that opens the model guide on a Mac with little memory"),
            action: setUp)
    }
}
