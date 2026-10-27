// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// The meeting page's Questions section: what the live answers heard in the selected meeting.
extension MeetingsModel {
    func loadQuestions(_ id: Int64) async {
        let loaded = (try? await store.detectedQuestions(id)) ?? []
        guard selectedID == id else { return }
        detectedQuestions = loaded
    }

    func setQuestionKept(_ question: DetectedQuestion, kept: Bool) async {
        do {
            try await store.setQuestionKept(question.id, kept: kept)
            if let i = detectedQuestions.firstIndex(where: { $0.id == question.id }) { detectedQuestions[i].kept = kept }
            noteActivity()
        } catch {
            present(String(localized: "Couldn’t keep the question", comment: "Alert title"), error)
        }
    }

    func removeQuestion(_ question: DetectedQuestion) async {
        do {
            try await store.removeDetectedQuestion(question.id)
            detectedQuestions.removeAll { $0.id == question.id }
            noteActivity()
        } catch {
            present(String(localized: "Couldn’t remove the question", comment: "Alert title"), error)
        }
    }
}
