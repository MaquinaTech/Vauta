// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The shape of the minutes the model writes for a meeting.
public enum MinutesTemplate: String, CaseIterable, Identifiable, Sendable, Codable {
    case general
    case oneOnOne
    case standup
    case clientCall
    case interview
    case lecture

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .general: String(localized: "General meeting", comment: "Minutes template")
        case .oneOnOne: String(localized: "One-on-one", comment: "Minutes template")
        case .standup: String(localized: "Stand-up", comment: "Minutes template")
        case .clientCall: String(localized: "Client or sales call", comment: "Minutes template")
        case .interview: String(localized: "Interview", comment: "Minutes template")
        case .lecture: String(localized: "Class or talk", comment: "Minutes template")
        }
    }

    /// What the minutes should emphasize, for the model (English, like every
    /// prompt). The JSON shape is the same for every template, so validation
    /// and storage do not depend on it.
    public var promptInstructions: String {
        switch self {
        case .general:
            "Kind of meeting: general work meeting. Cover what was discussed, the decisions, the tasks with their owners and dates, and what was left open."
        case .oneOnOne:
            "Kind of meeting: one-on-one. In the summary, focus on progress, feedback in both directions, blockers, wellbeing and career topics. Record each person's commitments as tasks. Keep a respectful, neutral tone."
        case .standup:
            "Kind of meeting: stand-up. Keep it short. In the summary, say per participant what was done, what comes next and what blocks them. Blockers that were not solved go into open_questions."
        case .clientCall:
            "Kind of meeting: client or sales call. In the summary, cover the client's needs and pain points, objections, budget, timeline, decision makers and competitors mentioned. Record promises made to the client and agreed next steps as tasks."
        case .interview:
            "Kind of meeting: interview. In the summary, cover the candidate's background, the questions asked and the substance of the answers, strengths and concerns that were stated. Only report what was said; do not judge the candidate yourself. Record follow-ups of the hiring process as tasks."
        case .lecture:
            "Kind of meeting: class or talk. In the summary, explain the key ideas, definitions and examples in a study-friendly way; the topics are the main concepts. There are usually no decisions; assignments, readings and deadlines are tasks."
        }
    }
}
