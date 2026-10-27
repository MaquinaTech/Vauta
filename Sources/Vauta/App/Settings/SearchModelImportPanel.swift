// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import VautaCore

/// The open panel for "Import from a File…". Files, not a folder: Hugging Face's cache stores each file as a link into a
/// `blobs` folder, and the sandbox only grants the targets of the files the person picks.
@MainActor
enum SearchModelImportPanel {
    /// `missing`: one of the two files was already imported, so only the other one is asked for.
    static func chooseFiles(missing: SearchModelStatus.MissingPart? = nil) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        // Hugging Face's cache lives in a hidden folder (~/.cache/huggingface): show it without Command-Shift-Period.
        panel.showsHiddenFiles = true
        panel.prompt = String(localized: "Import", comment: "Open panel button that installs the search model from the chosen files")
        let revision = SearchModelText.shortRevision
        switch missing {
        case nil:
            panel.message = String(localized: "Choose model.safetensors and tokenizer.json of EmbeddingGemma 2 (revision \(revision)). Vauta checks them before using them; your files are never changed.",
                                   comment: "Open panel message when importing the search model from files; the file names and the argument (the revision) are not translated")
        case .tokenizer?:
            panel.message = String(localized: "Choose tokenizer.json of EmbeddingGemma 2 (revision \(revision)). Vauta checks it before using it; your file is never changed.",
                                   comment: "Open panel message when importing the tokenizer of the search model; the file name and the argument (the revision) are not translated")
        case .weights?:
            panel.message = String(localized: "Choose model.safetensors of EmbeddingGemma 2 (revision \(revision)). Vauta checks it before using it; your file is never changed.",
                                   comment: "Open panel message when importing the weights of the search model; the file name and the argument (the revision) are not translated")
        }
        return panel.runModal() == .OK ? panel.urls : []
    }
}
