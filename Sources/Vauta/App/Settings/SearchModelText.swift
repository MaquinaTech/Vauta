// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// The words of the search model card (Settings → Models) and of the Ask label: one place, so the card, the VoiceOver values
/// and the snapshot scenes say the same thing. "EmbeddingGemma 2", "Hugging Face" and file names are never translated.
enum SearchModelText {
    static let modelName = "EmbeddingGemma 2"
    static let shortRevision = String(SearchModelManifest.revision.prefix(7))
    static let modelCard = URL(string: "https://huggingface.co/google/embeddinggemma-2")!
    static let gemmaTerms = URL(string: "https://ai.google.dev/gemma/terms")!
    static let gemmaPolicy = URL(string: "https://ai.google.dev/gemma/prohibited_use_policy")!
    /// The MLX build Vauta runs is a patched fork (it compiles its GPU kernels at run time): the link goes to the fork.
    static let mlxRepository = URL(string: "https://github.com/MaquinaTech/mlx-swift")!

    /// "574 MB" in whole megabytes, with the unit of the language ("574 Mo" in French), the same style as the sizes of the other cards,
    /// and a no-break space before the unit.
    static func size(_ bytes: Int, locale: Locale = .current) -> String {
        guard bytes >= 1_000_000, bytes < 1_000_000_000 else { return ByteSize.string(Int64(bytes)) }
        // Whole megabytes ("574 MB"), as the card promises; the system's adaptive style would say "574.2 MB".
        let whole = Int64((Double(bytes) / 1_000_000).rounded()) * 1_000_000
        return ByteSize.glued(whole.formatted(.byteCount(style: .file, allowedUnits: [.mb], spellsOutZero: false, includesActualByteCount: false).locale(locale)))
    }

    static var downloadSize: String { size(SearchModelSpec.pinned.downloadSize) }

    /// "1 min", "45 sec": the time left, abbreviated by the system.
    static func duration(seconds: Int) -> String {
        Duration.seconds(max(1, seconds)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))
    }

    // MARK: Descriptions of each state

    static var notInstalled: String {
        String(localized: "From Google. Improves Ask, sidebar search and related meetings and documents by finding passages by meaning, in any language, entirely on this Mac: a question in English finds the passage in Spanish. \(downloadSize) download, Apple silicon only.",
               comment: "Settings → Models; under the search model before it is installed; the argument is the download size, e.g. 574 MB")
    }

    /// "312 MB of 574 MB · about 1 min left" (the time left once it is known).
    static func progress(received: Int, total: Int, secondsRemaining: Int?) -> String {
        let done = size(received), all = size(total)
        guard let secondsRemaining else {
            return String(localized: "\(done) of \(all)", comment: "Settings → Models; progress of the search model download: size done of total size")
        }
        return String(localized: "\(done) of \(all) · about \(duration(seconds: secondsRemaining)) left",
                      comment: "Settings → Models; progress of the search model download: size done of total size, then the time left, e.g. 1 min")
    }

    static var pausedForRecording: String {
        String(localized: "Paused during the recording; it will continue afterwards.", comment: "Settings → Models; the search model download waits for the recording to end")
    }

    static func stopped(verified: Int, total: Int) -> String {
        String(localized: "Download stopped at \(size(verified)) of \(size(total)).", comment: "Settings → Models; a search model download that was cancelled or interrupted and can be resumed")
    }

    /// One of the two files was imported from the person's files; the other one is still needed.
    static func importedPart(missing: SearchModelStatus.MissingPart) -> String {
        switch missing {
        case .tokenizer:
            String(localized: "Imported the weights. Also choose tokenizer.json from the same model, or download just the tokenizer (\(tokenizerSize)).",
                   comment: "Settings → Models; the model weights were imported from a file and the tokenizer is still needed; tokenizer.json and model.safetensors are file names, not translated; the argument is a size, e.g. 32 MB")
        case .weights:
            String(localized: "Imported tokenizer.json. Also choose model.safetensors from the same model, or download the weights (\(weightsSize)).",
                   comment: "Settings → Models; the tokenizer was imported from a file and the model weights are still needed; tokenizer.json and model.safetensors are file names, not translated; the argument is a size, e.g. 542 MB")
        }
    }

    static var tokenizerSize: String { size(SearchModelSpec.pinned.tokenizerSize) }
    static var weightsSize: String { size(SearchModelSpec.pinned.downloadSize - SearchModelSpec.pinned.tokenizerSize) }

    static var verifying: String { String(localized: "Checking the model…", comment: "Settings → Models; the downloaded search model is being checked against the pinned checksums") }
    static var preparing: String { String(localized: "Preparing the model…", comment: "Settings → Models; the search model is loading for the first time") }
    static var deleting: String { String(localized: "Deleting the model…", comment: "Settings → Models; the search model is being removed") }

    static func ready(installedBytes: Int) -> String {
        installedBytes > 0
            ? String(localized: "Ready · \(size(installedBytes)) on this Mac.", comment: "Settings → Models; the search model is installed; the argument is its size on disk")
            : String(localized: "Ready.", comment: "Settings → Models; the search model is installed")
    }

    static var readyServerChosen: String {
        String(localized: "Installed. Search by meaning uses your model server.", comment: "Settings → Models; the search model is installed but the person chose the model server for search by meaning")
    }

    /// "Meetings 40 of 60 · Documents 1,200 of 5,740 passages": each corpus on its own, so meetings are not lost in the count of
    /// document passages.
    static func indexingParts(_ index: LLMService.SearchIndexStatus) -> String {
        var parts: [String] = []
        if index.meetings.total > 0 {
            parts.append(String(localized: "Meetings \(index.meetings.covered.formatted()) of \(index.meetings.total.formatted())",
                                comment: "Settings → Models; indexing progress of the meetings: done of total"))
        }
        if index.documents.total > 0 {
            parts.append(String(localized: "Documents \(index.documents.covered.formatted()) of \(index.documents.total.formatted()) passages",
                                comment: "Settings → Models; indexing progress of the documents: passages done of total"))
        }
        return parts.joined(separator: " · ")
    }

    /// The first line while the library is indexed (the second is `indexing`).
    static var indexingTitle: String {
        String(localized: "Ready · Indexing for search by meaning", comment: "Settings → Models; the search model is installed and the meetings and documents are being indexed for search by meaning")
    }

    /// "Meetings 40 of 60 · Documents 1,200 of 5,740 passages. Until then, Ask uses keyword search for meetings." The ranking is per
    /// corpus: a corpus that has not been fully indexed yet is ranked by keywords as a whole, including the part that is already indexed.
    static func indexing(_ index: LLMService.SearchIndexStatus) -> String {
        let parts = indexingParts(index)
        switch (index.meetingsRanking, index.documentsRanking) {
        case (false, true):
            return String(localized: "\(parts). Until then, Ask uses keyword search for meetings.",
                          comment: "Settings → Models; second line while the meetings are being indexed; the argument is the progress of each, e.g. Meetings 40 of 60 · Documents 1,200 of 5,740 passages")
        case (true, false):
            return String(localized: "\(parts). Until then, Ask uses keyword search for documents.",
                          comment: "Settings → Models; second line while the documents are being indexed; the argument is the progress of each, e.g. Meetings 40 of 60 · Documents 1,200 of 5,740 passages")
        default:
            return String(localized: "\(parts). Until then, Ask uses keyword search for meetings and documents.",
                          comment: "Settings → Models; second line while the meetings and documents are being indexed; the argument is the progress of each, e.g. Meetings 40 of 60 · Documents 1,200 of 5,740 passages")
        }
    }

    static var readyKeywordChosen: String {
        String(localized: "Installed. Ask uses keyword search.", comment: "Settings → Models; the search model is installed but the person chose keyword search")
    }

    /// The confirmation of Delete…: what stops working depends on what the person chose for search by meaning.
    static func deleteMessage(choice: ModelProviderSettings.Embeddings, freed: Int) -> String {
        let space = size(freed)
        if choice == .onDeviceModel {
            return String(localized: "Ask, search and related meetings and documents go back to keyword search, and the index for search by meaning is removed. Frees \(space). You can download it again.",
                          comment: "Confirmation of deleting the search model while search by meaning uses it; the argument is the space it frees, e.g. 574 MB")
        }
        return String(localized: "Your choice for search doesn’t change. Frees \(space). You can download it again.",
                      comment: "Confirmation of deleting the search model while search uses keywords or a model server; the argument is the space it frees, e.g. 574 MB")
    }

    /// Items the model looked at and could not embed (they are left out of the count that completes the index).
    static func skipped(_ count: Int) -> String {
        String(localized: "Items the model couldn’t read: \(count.formatted()). Keyword search still finds them.",
               comment: "Settings → Models; some text could not be turned into numbers by the search model; the argument is how many items")
    }

    static func pauseReason(_ index: LLMService.SearchIndexStatus) -> String? {
        if let pause = index.pause {
            switch pause {
            case .recording: return String(localized: "Waits until the recording is over.", comment: "Settings → Models; why indexing for search by meaning is paused")
            case .lowPower: return String(localized: "Waits while Low Power Mode is on.", comment: "Settings → Models; why indexing for search by meaning is paused")
            case .thermal: return String(localized: "Waits while your Mac cools down.", comment: "Settings → Models; why indexing for search by meaning is paused")
            }
        }
        if index.onBattery { return String(localized: "Waits for the charger.", comment: "Settings → Models; why indexing for search by meaning is paused") }
        return nil
    }

    static var unsupported: String {
        String(localized: "This Mac can’t run the search model.", comment: "Settings → Models; the Mac has no supported GPU or the model’s self-test failed")
    }

    static func unsupportedDetail(_ reason: SearchModelUnavailableReason) -> String {
        switch reason {
        case .unsupportedHardware:
            String(localized: "It needs an Apple silicon Mac. Keyword search keeps working.", comment: "Settings → Models; under “This Mac can’t run the search model”")
        case .selfTestFailed:
            String(localized: "Its self-test failed on this Mac. Run “Vauta doctor” in Terminal for details. Keyword search keeps working.", comment: "Settings → Models; under “This Mac can’t run the search model”")
        case .verificationFailed:
            damaged
        }
    }

    static var damaged: String {
        String(localized: "The model files on this Mac are damaged. Delete them and download again.", comment: "Settings → Models; the installed search model no longer matches the pinned checksums")
    }

    static var migratedNotice: String {
        String(localized: "Search by meaning on this Mac now uses a better model. Download it to turn it back on.", comment: "Settings → Models; shown once to a person whose saved choice used Apple’s retired on-device embeddings")
    }

    // MARK: Errors

    static func failure(_ error: SearchModelError) -> String {
        switch error {
        case .mismatch:
            String(localized: "The downloaded file didn’t match Google’s original. Nothing was installed.", comment: "Settings → Models; the search model failed its checksum")
        case .hostNotAllowed:
            String(localized: "Hugging Face sent the download to a server Vauta doesn’t allow. Nothing was downloaded from it.", comment: "Settings → Models; the download was redirected to a host that is not on the allowlist")
        case .revisionGone:
            String(localized: "This version of the model is no longer available from Hugging Face. You can import it from a file.", comment: "Settings → Models; the pinned revision was removed")
        case .offline:
            String(localized: "Couldn’t reach Hugging Face. Check your connection and try again.", comment: "Settings → Models; the download could not connect")
        case .diskFull(let needed):
            String(localized: "Not enough space: the model needs about \(size(needed)) free.", comment: "Settings → Models; the argument is the free space needed, e.g. 843 MB")
        case .importWrongFile:
            String(localized: "This isn’t the \(modelName) file Vauta needs (revision \(shortRevision)).", comment: "Settings → Models; a file chosen for import is not the model; the arguments are the model name and the revision, not translated")
        case .unexpectedResponse:
            String(localized: "Hugging Face answered with something Vauta didn’t expect. Nothing was installed.", comment: "Settings → Models; the server’s answer was not the requested range of the file")
        case .ioError:
            String(localized: "Vauta couldn’t write the model to disk. Nothing was installed.", comment: "Settings → Models; a file operation failed")
        case .unsupported, .selfTestFailed:
            unsupported
        case .tokenizerUnreadable:
            String(localized: "The model’s tokenizer couldn’t be read. Delete the model and download it again.", comment: "Settings → Models")
        case .encoderFailed:
            String(localized: "The model couldn’t run on this Mac. Keyword search keeps working.", comment: "Settings → Models")
        }
    }

    /// Importing a file can fix the failure.
    static func offersImport(_ error: SearchModelError) -> Bool {
        switch error {
        case .mismatch, .hostNotAllowed, .revisionGone, .offline, .importWrongFile, .unexpectedResponse: true
        default: false
        }
    }

    /// Free space is the problem: Storage settings help.
    static func isDiskFull(_ error: SearchModelError) -> Bool {
        if case .diskFull = error { return true }
        return false
    }

    // MARK: Accessibility

    /// "312 of 574 megabytes, about 1 minute left" for the progress bar's value.
    static func spokenProgress(received: Int, total: Int, secondsRemaining: Int?) -> String {
        let done = Int((Double(received) / 1_000_000).rounded()), all = Int((Double(total) / 1_000_000).rounded())
        guard let secondsRemaining else {
            return String(localized: "\(done) of \(all) megabytes", comment: "Accessibility value of the search model download progress")
        }
        let time = Duration.seconds(max(1, secondsRemaining)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 1))
        return String(localized: "\(done) of \(all) megabytes, about \(time) left", comment: "Accessibility value of the search model download progress; the last argument is a duration such as 1 minute")
    }

    /// The progress bar's value while the download waits for a recording to end.
    static func spokenPaused(_ progress: String) -> String {
        String(localized: "\(progress), paused", comment: "Accessibility value of the search model download progress while it waits for a recording to end; the argument is the progress, e.g. 312 of 574 megabytes")
    }

    // MARK: Ask

    static func askLabel(_ mode: SearchModelModel.AskMode) -> String {
        switch mode {
        case .meaning: String(localized: "Search by meaning", comment: "Ask; under the question: Ask finds passages with the search model")
        case .meaningIndexing(.meetings, let percent):
            String(localized: "Search by meaning · meetings indexing \(percent)%", comment: "Ask; under the question: documents are found by meaning while the meetings still index; the argument is a percentage without the sign")
        case .meaningIndexing(.documents, let percent):
            String(localized: "Search by meaning · documents indexing \(percent)%", comment: "Ask; under the question: meetings are found by meaning while the documents still index; the argument is a percentage without the sign")
        case .indexing(let percent): String(localized: "Keyword search · indexing \(percent)%", comment: "Ask; under the question: keyword search while the search model indexes; the argument is a percentage without the sign")
        case .keyword: String(localized: "Keyword search", comment: "Ask; under the question: Ask finds passages by keywords")
        }
    }

    static func askHelp(_ mode: SearchModelModel.AskMode) -> String {
        switch mode {
        case .meaning: String(localized: "Ask finds passages by meaning, on this Mac. Click to open Settings.", comment: "Tooltip of the Ask search label")
        case .meaningIndexing(.meetings, _): String(localized: "Documents are found by meaning; meetings use keyword search until they are indexed. Click to open Settings.", comment: "Tooltip of the Ask search label")
        case .meaningIndexing(.documents, _): String(localized: "Meetings are found by meaning; documents use keyword search until they are indexed. Click to open Settings.", comment: "Tooltip of the Ask search label")
        case .indexing: String(localized: "Ask uses keyword search until the search model has indexed your meetings and documents. Click to open Settings.", comment: "Tooltip of the Ask search label")
        case .keyword: String(localized: "Ask finds passages by keywords. Click to open Settings.", comment: "Tooltip of the Ask search label")
        }
    }

    static func askSymbol(_ mode: SearchModelModel.AskMode) -> String {
        switch mode {
        case .meaning, .meaningIndexing: "sparkle.magnifyingglass"
        case .indexing: "arrow.triangle.2.circlepath"
        case .keyword: "magnifyingglass"
        }
    }

    static var askOffer: String {
        String(localized: "Search by meaning in any language: get the \(downloadSize) search model in Settings\u{00A0}→\u{00A0}Models", comment: "Ask; a one-line offer of the optional search model, shown until dismissed; the argument is the download size, e.g. 574 MB")
    }
}
