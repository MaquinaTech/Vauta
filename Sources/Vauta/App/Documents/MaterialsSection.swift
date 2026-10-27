// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The Summary's Materials: files attached to this meeting. Ask about the meeting can use them; the minutes and notes never do
/// (they say what was said).
struct MaterialsSection: View {
    @Bindable var model: MeetingsModel

    var body: some View {
        DetailSection(String(localized: "Materials", comment: "Section title in a meeting: documents attached to it")) {
            if model.materials.isEmpty {
                Text("Drop files here to attach them to this meeting.", comment: "Materials: shown when the meeting has none; files can be dragged in")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            ForEach(model.materials) { material in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: DocumentFormat.format(forExtension: (material.name as NSString).pathExtension)?.symbol ?? "doc").foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: material.name).lineLimit(1).truncationMode(.middle)
                        // Whether Ask can use the file yet, and if not, why: a file that was never read must not look like one that was.
                        if let state = model.materialStates[material.id] {
                            Label { Text(verbatim: state.text) } icon: { Image(systemName: state.symbol).foregroundStyle(state.isProblem ? Color.orange : Color.secondary) }
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Open File") { model.open(material: material) }.controlSize(.small)
                    Button("Detach") { model.detach(material) }.controlSize(.small)
                }
                .accessibilityElement(children: .combine)
            }
            // Files that could not be attached (a kind Vauta does not read, an error): said here, where the files were dropped.
            ForEach(Array(model.materialsNotes.enumerated()), id: \.offset) { _, note in
                NoticeLabel(Text(note.text), status: .warning)
            }
            HStack {
                Button("Attach Files…") { model.chooseMaterials() }
                Spacer()
            }
        }
        // The outline sits outside the section's text edge (it does not push the content in, so the heading lines up with the
        // other sections of the Summary).
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(model.materialsDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                .padding(-8)
                .allowsHitTesting(false)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.attachMaterials(urls)
            return !urls.isEmpty
        } isTargeted: { model.materialsDropTargeted = $0 }
        // The index moved on (a file was read, skipped, a drive came back): the rows say so.
        .task(id: model.documentsModel?.snapshot) { await model.refreshMaterialStates() }
    }
}

/// The passages of the person's documents that go with the meeting's topics and decisions: by meaning when the search model
/// ranks the documents, else by keywords.
struct RelatedDocumentsSection: View {
    @Bindable var model: MeetingsModel

    var body: some View {
        DetailSection(String(localized: "Related documents", comment: "Section title in a meeting: passages of the person's documents that match its topics and decisions")) {
            if model.relatedDocumentsByMeaning {
                Text("Found by meaning", comment: "Caption under “Related documents” or “Related meetings” when the search model found them")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.relatedDocuments) { passage in
                let citation = DocumentCitation(passage)
                Button { model.openDocument(citation) } label: {
                    Label { Text(verbatim: citation.label) } icon: { Image(systemName: citation.format.symbol) }
                }
                .buttonStyle(.link)
                .lineLimit(1)
                .accessibilityLabel(Text(verbatim: citation.spokenLabel))
            }
        }
    }
}
