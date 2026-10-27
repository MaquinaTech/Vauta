// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore

extension DocumentFormat {
    /// The symbol that stands for this kind of file wherever a document is named (the passage viewer, Ask's citations and passages,
    /// Related documents), so a spreadsheet or a deck does not look like a PDF.
    var symbol: String {
        switch self {
        case .pdf: "doc.richtext"
        case .xlsx, .csv, .tsv: "tablecells"
        case .pptx: "play.rectangle"
        case .image: "photo"
        default: "doc.text"
        }
    }
}
