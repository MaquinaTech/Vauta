// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import Foundation

/// A file attached to the open meeting as its material: one of its own, or one of the library linked to it.
struct MeetingMaterial: Identifiable, Equatable {
    enum Origin: Equatable { case attached(sourceID: Int64), linked(sourceID: Int64, relPath: String) }
    let origin: Origin
    let name: String
    var id: String {
        switch origin {
        case .attached(let id): "a\(id)"
        case .linked(let id, let path): "l\(id):\(path)"
        }
    }
}

/// The Materials and Related documents of the open meeting.
extension MeetingsModel {
    /// Reads the open meeting's materials and, with no model, the passages of the person's documents that go with its topics and decisions.
    func loadDocuments() async {
        guard let id = selectedID, let documents = documentsModel else {
            materials = []
            materialStates = [:]
            materialsNotes = []
            relatedDocuments = []
            return
        }
        if materialsNotesMeeting != id { materialsNotes = [] }
        let found = (try? await store.meetingMaterials(id)) ?? (attached: [], linked: [])
        materials = found.attached.map { MeetingMaterial(origin: .attached(sourceID: $0.id), name: $0.displayName) }
            + found.linked.map { MeetingMaterial(origin: .linked(sourceID: $0.source, relPath: $0.relPath), name: ($0.relPath as NSString).lastPathComponent) }
        await refreshMaterialStates()
        // The topics and decisions of the minutes, as keywords (no model, nothing sent anywhere).
        let words = ((draft?.topicsText ?? "") + " " + decisions.map(\.text).joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
        guard documents.snapshot.hasSources, words.count >= 3 else {
            relatedDocuments = []
            return
        }
        // By meaning when the search model ranks the documents, else by keywords.
        let text = String(words.prefix(400))
        let hits: [DocumentPassage]
        var byMeaning = false
        if let llm, let found = await llm.relatedDocuments(for: text, limit: 3) {
            hits = found
            byMeaning = true
        } else {
            hits = (try? await documents.index?.keywordHits(text, limit: 3)) ?? []
        }
        guard selectedID == id else { return }
        relatedDocuments = hits
        relatedDocumentsByMeaning = byMeaning
    }

    func attachMaterials(_ urls: [URL]) {
        guard let meeting = selectedID, let indexer = documentsModel?.indexer else { return }
        Task {
            var problems: [DocumentsModel.Note] = []
            for url in urls {
                do { try await indexer.attachMaterial(url, to: meeting) } catch {
                    // Said here, in the meeting's Materials: not in Settings → Documents, which the person is not looking at.
                    let note = DocumentsModel.Note.note(for: error)
                    if !problems.contains(note) { problems.append(note) }
                }
            }
            materialsNotes = problems
            materialsNotesMeeting = meeting
            if !problems.isEmpty { AccessibilityNotification.Announcement(problems.map(\.text).joined(separator: " ")).post() }
            await loadDocuments()
        }
    }

    /// Asks the indexer how each material is doing (called when the index changes).
    func refreshMaterialStates() async {
        guard let indexer = documentsModel?.indexer else { return }
        var states: [String: MaterialState] = [:]
        for material in materials {
            switch material.origin {
            case .attached(let sourceID): states[material.id] = await indexer.materialState(source: sourceID, relPath: nil)
            case .linked(let sourceID, let relPath): states[material.id] = await indexer.materialState(source: sourceID, relPath: relPath)
            }
        }
        if states != materialStates { materialStates = states }
    }

    func chooseMaterials() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Attach", comment: "Open panel button that attaches the chosen files to a meeting")
        panel.message = String(localized: "Choose files to attach to this meeting. Ask about the meeting can use them. Your files are never changed.", comment: "Open panel message when attaching files to a meeting")
        guard panel.runModal() == .OK else { return }
        attachMaterials(panel.urls)
    }

    func detach(_ material: MeetingMaterial) {
        guard let meeting = selectedID else { return }
        Task {
            switch material.origin {
            case .attached(let sourceID): try? await documentsModel?.indexer?.removeSource(sourceID)
            case .linked(let sourceID, let relPath): try? await store.unlinkMaterial(meeting: meeting, source: sourceID, relPath: relPath)
            }
            await loadDocuments()
        }
    }

    func open(material: MeetingMaterial) {
        guard let indexer = documentsModel?.indexer else { return }
        let (sourceID, relPath): (Int64, String) = switch material.origin {
        case .attached(let id): (id, material.name)
        case .linked(let id, let path): (id, path)
        }
        openInApp(source: sourceID, relPath: relPath, indexer: indexer)
    }

    /// Hands a document to its app, unless a cloud service keeps it online only: its app would make the service download
    /// it, and Vauta never starts a download (as in the passage viewer). A notice says so instead, with Show in Finder.
    func openInApp(source: Int64, relPath: String, indexer: DocumentIndexer) {
        Task {
            guard let file = await indexer.openForViewing(source: source, relPath: relPath) else { return }
            if await indexer.isNotOnThisMac(file) {
                show(MeetingsNotice(text: DocumentSkipReason.cloudNotDownloaded.localizedText, symbol: "icloud.slash", reveal: file.url))
            } else {
                NSWorkspace.shared.open(file.url)
            }
            try? await Task.sleep(for: .seconds(2))
            await indexer.closeViewing(file)
        }
    }
}
