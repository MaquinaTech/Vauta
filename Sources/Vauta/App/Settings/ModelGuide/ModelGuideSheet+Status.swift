// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

extension ModelGuideSheet {
    // MARK: Live status and "Use it"

    /// Always visible: what Vauta sees on this Mac right now, and what to fix. "Use This Model" in
    /// the footer is the last step. Short: one or two lines and, when the fix is in a step, a button to it.
    var statusStrip: some View {
        Group {
            if case .failed(let message) = guide.phase {
                // What happened and what to do, instead of a success row with an error under it.
                // In Settings the guide opens over the Models pane itself: only setup points to it.
                GuideStatusRow(kind: .error, inStepColumn: true, title: Self.withoutFinalPeriod(message),
                               detail: keepApple != nil
                                ? String(localized: "Make sure the server is still running, then try again. Or check it in Settings\u{00A0}→\u{00A0}Models.",
                                         comment: "Model guide in first-run setup: what to do after the server settings couldn’t be saved")
                                : String(localized: "Make sure the server is still running, then try again. Or close this guide and check the server in the Models pane.",
                                         comment: "Model guide in Settings: what to do after the server settings couldn’t be saved"))
            } else if guide.phase == .applying {
                // The footer keeps its link and buttons; the wait is explained where the status is.
                GuideStatusRow(kind: .waiting, inStepColumn: true, title: String(localized: "Checking and saving…", comment: "Model guide progress"))
            } else {
                let status = statusDescription
                HStack(alignment: .center, spacing: 12) {
                    GuideStatusRow(kind: status.kind, inStepColumn: true, title: status.title, detail: status.detail)
                    if let action = status.action, !isInView(action) {
                        Button(action.title) {
                            switch action.target {
                            case .step(let step): scrollRequest = ScrollRequest(step: step)
                            case .openApp: guide.openApp()
                            }
                        }
                        .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        // As tall as its content, with the same space above and below it: a single line is not left floating in a
        // two-line band, and the buttons below are not further from it than the rule above.
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    enum ActionTarget { case step(Int), openApp }
    typealias StatusAction = (title: String, target: ActionTarget)
    typealias StatusDescription = (kind: GuideStatusRow.Kind, title: String, detail: String?, action: StatusAction?)

    /// The button that scrolls to a step (or opens the app of step 3) is pointless while that step is on screen.
    func isInView(_ action: StatusAction) -> Bool {
        guard visibleRect != .zero else { return false }
        // "Open Ollama" is the button of step 3: it is not repeated while that step shows its own.
        let step: Int
        switch action.target {
        case .step(let number): step = number
        case .openApp: step = 3
        }
        var contextTooSmall = false
        if case .contextTooSmall = guide.status { contextTooSmall = true }
        guard let frame = blockFrames[step == 3 && contextTooSmall ? Self.fixKey : step] else { return false }
        let shown = frame.intersection(visibleRect)
        return !shown.isNull && shown.height >= min(frame.height, 100)
    }

    /// A message used as a title has no final period (the sentence form stays for alerts).
    static func withoutFinalPeriod(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.last, last == "." || last == "。" { trimmed.removeLast() }
        return trimmed
    }

    /// What the strip says now. Titles have no final period; details are sentences.
    var statusDescription: StatusDescription {
        let appName = guide.app.displayName
        let lookingForServer: Bool = switch guide.status {
        case .searching, .serverNotRunning: true
        default: false
        }
        if lookingForServer, !guide.isInstalled {
            // Nothing to wait for before the app exists.
            return (.info, String(localized: "Install \(appName) to continue.", comment: "Model guide status while the app is not installed; the argument is an app name"), nil, nil)
        }
        switch guide.status {
        case .searching:
            return (.waiting, lookingTitle(appName), lookingDetail, nil)
        case .serverNotRunning:
            // The same wording as while the first look is running: it is the same wait.
            return (.waiting, lookingTitle(appName), lookingDetail,
                    // Ollama serves as soon as its app is open; LM Studio's server is a switch inside the app.
                    guide.app == .ollama && guide.isInstalled
                        ? (String(localized: "Open \(appName)", comment: "Model guide button; the argument is an app name"), .openApp) : nil)
        case .noSuitableModel:
            let name = guide.recommendation.main?.displayName ?? ""
            // The expected next step, not a problem: the waiting style, as while the server is looked for.
            return (.waiting,
                    String(localized: "\(appName) is running, but \(name) isn’t downloaded yet",
                           comment: "Model guide status; arguments are an app name and a model name"),
                    String(localized: "Download it in step \(guide.number(of: 2)). Vauta notices when it’s ready.", comment: "Model guide status detail; the argument is the number of the download step"),
                    (String(localized: "Show Step \(guide.number(of: 2))", comment: "Model guide: scrolls to the download step; the argument is its number"), .step(2)))
        case .contextTooSmall(let shortfall):
            let model = guide.displayName(of: shortfall.modelID)
            return (.warning,
                    ModelGuideModel.contextTitle(shortfall, name: model),
                    [ModelGuideModel.contextDetail(shortfall),
                     String(localized: "The fix is in step \(guide.number(of: 3)).", comment: "Model guide status detail when a model has too little context; the button beside it scrolls to the step; the argument is its number")].joinedAsSentences(),
                    (String(localized: "Show Fix", comment: "Model guide: scrolls to the step with the fix for the context length"), .step(3)))
        case .ready(let candidate):
            return readyDescription(candidate)
        }
    }

    private func lookingTitle(_ appName: String) -> String {
        String(localized: "Looking for the \(appName) server…", comment: "Model guide status while Vauta looks for the app’s server; the argument is an app name")
    }

    private var lookingDetail: String {
        String(localized: "Vauta checks this Mac every few seconds while this guide is open.", comment: "Model guide status detail")
    }

    /// The same words for VoiceOver when the strip changes; nil while nothing is worth saying.
    var statusAnnouncement: String? {
        if case .failed(let message) = guide.phase { return message }
        if guide.phase == .applying { return String(localized: "Checking and saving…", comment: "Model guide progress") }
        if case .done(let summary) = guide.phase {
            // The sheet swaps to the result: say that it worked and what changed, as the backup sheets do.
            let title = String(localized: "Model Server Ready")
            let result = String(localized: "Minutes are now written with \(summary.mainModel) in \(summary.serverName). The model runs on this Mac, so meeting text sent to it stays here.",
                                comment: "Model guide result; arguments are a model name and an app name")
            return [title, result].joined(separator: " ")
        }
        guard showsSteps else { return nil }
        let status = statusDescription
        return [status.title, status.detail].compactMap { $0 }.joined(separator: " ")
    }

    func readyDescription(_ candidate: SetupCandidate) -> StatusDescription {
        let appName = candidate.serverKind.displayName
        let main = guide.displayName(of: candidate.mainModel)
        let title: String
        if candidate.fastModel == candidate.mainModel {
            title = String(localized: "Found \(main) in \(appName)", comment: "Model guide status; arguments are a model name and an app name")
        } else {
            let fast = guide.displayName(of: candidate.fastModel)
            title = String(localized: "Found \(main) and \(fast) in \(appName)",
                           comment: "Model guide status; arguments are two model names and an app name")
        }
        // The server didn't say which context the model loads with (it isn't loaded yet): Vauta looks once it is,
        // when the setup is saved, instead of leaving a warning the person can do nothing about.
        guard candidate.contextVerified else {
            return (.info, title, String(localized: "Context length is checked when you save.",
                                         comment: "Model guide status detail"), nil)
        }
        return (.success, title, String(localized: "Context length: \(ModelGuideModel.tokens(candidate.config.contextTokens)), enough for long meetings.",
                                        comment: "Model guide status detail; the argument is a token count"), nil)
    }

    // MARK: Formatting

    /// An approximate size in whole gigabytes ("About 16 GB"): a decimal adds nothing to an estimate.
    static func gigabytes(_ gb: Double) -> String {
        Measurement(value: gb.rounded(), unit: UnitInformationStorage.gigabytes)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
            .replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// Free space the way download sizes are written: whole gigabytes, one decimal below 10 GB, the same in every language.
    static func freeSpace(_ count: Int64) -> String {
        let gb = Double(count) / 1_000_000_000
        let decimals = gb < 10 ? 1 : 0
        return Measurement(value: gb, unit: UnitInformationStorage.gigabytes)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(decimals))))
            .replacingOccurrences(of: " ", with: "\u{00A0}")
    }
}
