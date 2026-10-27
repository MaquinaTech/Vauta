// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The pages of the first-run setup, in order.
public enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome
    case language
    case permissions
    case speechModel
    case models
    case done

    public var id: Int { rawValue }
}

/// Moves through the setup pages. Pages in `skipped` (for example the speech
/// model download when the model is already installed) are passed over in
/// both directions, but never the first or the last page.
public struct OnboardingFlow: Equatable, Sendable {
    public private(set) var step: OnboardingStep
    public var skipped: Set<OnboardingStep> {
        didSet { skipped.subtract([.welcome, .done]) }
    }

    public init(step: OnboardingStep = .welcome, skipped: Set<OnboardingStep> = []) {
        self.step = step
        self.skipped = skipped.subtracting([.welcome, .done])
    }

    /// The pages shown, in order.
    public var visibleSteps: [OnboardingStep] {
        OnboardingStep.allCases.filter { !skipped.contains($0) }
    }

    public var isFirst: Bool { step == .welcome }
    public var isLast: Bool { step == .done }
    /// "Skip setup" jumped straight to the last page: there is nothing to go back to review.
    public private(set) var finishedBySkipping = false
    /// Every page has Back except the first, and the last one when setup was skipped.
    public var canGoBack: Bool { !isFirst && !(isLast && finishedBySkipping) }

    /// 1-based position among the visible pages, and how many there are.
    public var position: (index: Int, count: Int) {
        // The page being shown always counts, even when it became skippable while the user is on it.
        let visible = OnboardingStep.allCases.filter { !skipped.contains($0) || $0 == step }
        return ((visible.firstIndex(of: step) ?? 0) + 1, visible.count)
    }

    public mutating func advance() {
        guard let next = OnboardingStep.allCases.first(where: { $0.rawValue > step.rawValue && !skipped.contains($0) }) else { return }
        step = next
    }

    public mutating func goBack() {
        guard canGoBack,
              let previous = OnboardingStep.allCases.last(where: { $0.rawValue < step.rawValue && !skipped.contains($0) })
        else { return }
        step = previous
    }

    /// Jumps to the last page (used by "Skip setup").
    public mutating func finish() {
        step = .done
        finishedBySkipping = true
    }
}
