// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// The companion's details (Show Details on its bar): what the meeting gives while it goes on, which the panel shows only while
/// it is open and clicking in the meeting app closes. The answers to questions heard, the live notes and the newest passages of
/// the transcript, drawn by the panel's own cards from the recording's own state, so the two always show the same. Nothing in
/// them takes the keyboard or brings Vauta to the front: a click acts in place, and what arrives never moves the focus.
struct CompanionDetails: View {
    @Bindable var model: RecorderModel

    /// As wide as the panel's cards, so they wrap their text the same way.
    static let contentWidth: CGFloat = 328
    private static let padding: CGFloat = 10

    var body: some View {
        let limits = Self.limits(screenHeight: NSScreen.main?.visibleFrame.height ?? 800)
        VStack(spacing: 10) {
            if model.answers.isVisible {
                AnswersCard(model: model.answers, rowLimit: limits.answer, openSettings: { model.showSettings(.recording) })
            }
            LiveNotesView(model: model, maxHeight: limits.notes)
            if model.hasLiveTranscript {
                TranscriptSection(model: model, maxBoxHeight: limits.transcript)
            }
            if !model.answers.isVisible, !model.showsLiveNotes, !model.hasLiveTranscript {
                Text("The answers, the live notes and the transcript show here as the meeting goes on.",
                     comment: "Meeting companion details, before anything was said or written: what will appear")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
        .frame(width: Self.contentWidth)
        .padding(Self.padding)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
        .environment(\.copyProtection, model.preferences.copyProtection)
        .writingToolsBehavior(.disabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Meeting Companion Details", comment: "VoiceOver name of the part of the meeting companion with the answers, the live notes and the transcript"))
    }

    /// How tall each card may be: together about half the screen, so the companion never covers the meeting it sits beside.
    static func limits(screenHeight: CGFloat) -> (answer: CGFloat, notes: CGFloat, transcript: CGFloat) {
        let room = max(360, screenHeight * 0.55)
        return (answer: min(220, room * 0.35), notes: min(260, room * 0.4), transcript: min(150, room * 0.25))
    }
}
