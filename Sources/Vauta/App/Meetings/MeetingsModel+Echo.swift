// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import VautaCore

/// Echoes in the transcript: a Me line that repeats what the other side said (the microphone heard it from the speakers), or an
/// Others line that repeats what the user said (a participant's speakers sent it back). The person can say a line is not an echo,
/// with Edit ▸ Undo.
extension MeetingsModel {
    /// Marks the line as the person's own (`isEcho` false) or as an echo again (Undo). The transcript, talk time and search
    /// chunks are read again; the minutes take the line in the next time they are written.
    func setEcho(_ segment: MeetingStore.StoredSegment, _ isEcho: Bool) async {
        noteActivity()
        do {
            try await store.setEcho(segment.id, isEcho)
        } catch {
            present(String(localized: "Couldn’t change the line", comment: "Alert title: saying whether a transcript line is the user's own or an echo of the speakers failed"), error)
            return
        }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { _ = Task { await model.setEcho(segment, !isEcho) } }
        }
        undoManager?.setActionName(isEcho ? String(localized: "Mark as Echo", comment: "Edit menu: the action Undo takes back, marking a transcript line as an echo of the speakers again")
                                          : segment.channel == .me ? String(localized: "It Was Me", comment: "Edit menu: the action Undo takes back, saying a transcript line marked as an echo was the user's own")
                                          : EchoNote.farRestore)
        await reloadSpeakers()
    }
}
