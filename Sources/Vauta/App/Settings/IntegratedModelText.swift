// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// The words of the integrated model's card (Settings → Models), of its status row, of the provider choice and of the Ask card
/// states: one place, so the card, the VoiceOver values and the snapshot scenes say the same thing. "Gemma 4 E4B", "Hugging Face"
/// and file names are never translated.
enum IntegratedModelText {
    static let modelName = "Gemma 4 E4B"
    static let shortRevision = String(LanguageModelManifest.revision.prefix(7))
    static let modelCard = URL(string: "https://huggingface.co/google/gemma-4-E4B-it")!
    static let license = URL(string: "https://ai.google.dev/gemma/docs/gemma_4_license")!
    static let gemmaTerms = URL(string: "https://ai.google.dev/gemma/terms")!
    static let gemmaPolicy = URL(string: "https://ai.google.dev/gemma/prohibited_use_policy")!

    /// "6.1 GB", "4.2 GB", "32 MB": decimal units written the way the person's language writes them (French says "Go" and "Mo"),
    /// rounded to a tenth of a gigabyte (a whole gigabyte from 10), or to a megabyte.
    static func size(_ bytes: Int) -> String {
        let step = bytes >= 10_000_000_000 ? 1_000_000_000 : bytes >= 1_000_000_000 ? 100_000_000 : 1_000_000
        let rounded = Int64((Double(bytes) / Double(step)).rounded()) * Int64(step)
        return ByteSize.glued(ByteCountFormatStyle(style: .decimal, allowedUnits: [.mb, .gb], spellsOutZero: false, includesActualByteCount: false).format(rounded))
    }

    static var downloadSize: String { size(LanguageModelSpec.pinned.downloadSize) }
    static var installedSize: String { size(LanguageModelSpec.pinned.installedSize) }
    static var tokenizerSize: String { size(LanguageModelSpec.pinned.tokenizerSize) }
    static var originalSize: String { size(LanguageModelSpec.pinned.sourceSize) }
    static var neededFree: String { size(LanguageModelSpec.pinned.installedSize + LanguageModelStore.headroom) }

    static func duration(seconds: Int) -> String {
        Duration.seconds(max(1, seconds)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))
    }

    // MARK: Provider choice

    static var optionTitle: String {
        String(localized: "Integrated model (Gemma 4 E4B, Google)", comment: "Settings → Models; provider option for the model that runs inside Vauta; Gemma 4 E4B is a name, not translated")
    }

    static var badge: String { String(localized: "Large download", comment: "Settings → Models; badge of the integrated model option: it needs a download of about 15 GB") }

    static var optionExplanation: String {
        String(localized: "Runs entirely on this Mac. It reads a whole meeting at once, so long meetings are summarized in one pass. Needs a one-time download from Hugging Face.",
               comment: "Settings → Models; explanation of the integrated model option")
    }

    /// The same once the model is installed: nothing is left to download.
    static var optionExplanationInstalled: String {
        String(localized: "Runs entirely on this Mac. It reads a whole meeting at once, so long meetings are summarized in one pass.",
               comment: "Settings → Models; explanation of the integrated model option when the model is already installed")
    }

    /// The explanation, and when Apple Intelligence can't stand in, that no minutes are written until the model is ready.
    static func optionExplanation(appleAvailable: Bool, installed: Bool = false) -> String {
        if installed { return optionExplanationInstalled }
        return appleAvailable ? optionExplanation : [optionExplanation, noStandIn].joinedAsSentences()
    }

    static var noStandIn: String {
        String(localized: "Until the download finishes, Vauta can’t write minutes. You can also choose a model server.",
               comment: "Settings → Models; under the integrated model option on a Mac where Apple Intelligence is not available to write minutes meanwhile")
    }

    static func unsupportedNote(_ reason: LanguageModelUnsupported) -> String {
        switch reason {
        case .memory(let gb):
            String(localized: "The integrated model (Gemma 4 E4B) needs 16 GB of memory. This Mac has \(gb) GB.",
                   comment: "Settings → Models; under the provider choice on a Mac with too little memory; the argument is the memory in GB, e.g. 8")
        case .gpu, .workingSet:
            String(localized: "The integrated model can’t run on this Mac’s graphics.", comment: "Settings → Models; under the provider choice")
        case .selfTestFailed:
            String(localized: "The integrated model failed its self-test on this Mac. Run “Vauta doctor” in Terminal for details.", comment: "Settings → Models; under the provider choice; Vauta doctor is a command, not translated")
        }
    }

    static var onboardingLine: String {
        String(localized: "On this Mac you can also download the integrated model (Gemma 4, from Google) in Settings\u{00A0}→\u{00A0}Models to write minutes on this Mac from a whole meeting at once (\(downloadSize) download).",
               comment: "Onboarding, under the Apple Intelligence option on a Mac with 16 GB or more; the argument is the download size, e.g. 15 GB")
    }

    /// The same line where Apple Intelligence is not an option, so there is no "also".
    static var onboardingLineWithoutApple: String {
        String(localized: "On this Mac you can download the integrated model (Gemma 4, from Google) in Settings\u{00A0}→\u{00A0}Models to write minutes on this Mac from a whole meeting at once (\(downloadSize) download).",
               comment: "Onboarding, on a Mac with 16 GB or more where Apple Intelligence is off or unsupported, so no other model is offered before it; the argument is the download size, e.g. 15 GB")
    }

    // MARK: Card: descriptions of each state

    static var notInstalled: String {
        String(localized: "From Google. Writes minutes and answers on this Mac. Downloads about \(downloadSize) from Hugging Face and keeps about \(installedSize).",
               comment: "Settings → Models; under the integrated model before it is installed; the arguments are sizes, e.g. 15 GB and 4.2 GB")
    }

    static var starting: String { String(localized: "Starting the download…", comment: "Settings → Models; the integrated model download is about to transfer") }

    static func progress(received: Int, total: Int, secondsRemaining: Int?) -> String {
        let done = size(received), all = size(total)
        guard let secondsRemaining else {
            return String(localized: "Downloading and converting · \(done) of \(all)", comment: "Settings → Models; progress of the integrated model download: size done of total size")
        }
        return String(localized: "Downloading and converting · \(done) of \(all) · about \(duration(seconds: secondsRemaining)) left",
                      comment: "Settings → Models; progress of the integrated model download: size done of total size, then the time left, e.g. 25 min")
    }

    static func repairing(received: Int, total: Int) -> String {
        String(localized: "Repairing · downloading only the damaged part · \(size(received)) of \(size(total))",
               comment: "Settings → Models; progress of the repair of the integrated model; the arguments are sizes, e.g. 1.2 GB and 9.8 GB")
    }

    static var checkingPartial: String {
        String(localized: "Checking what was already downloaded…", comment: "Settings → Models; a paused download of the integrated model is going on again and its kept blocks are checked")
    }

    static func pausedForRecording(received: Int, total: Int) -> String {
        String(localized: "Paused at \(size(received)) of \(size(total)) · continues after the recording",
               comment: "Settings → Models; the model download waits for the recording to end; the arguments are sizes, e.g. 6.1 GB and 15 GB")
    }

    static func paused(verified: Int, total: Int) -> String {
        String(localized: "Paused at \(size(verified)) of \(size(total)).", comment: "Settings → Models; a download of the integrated model that was paused or interrupted and can be resumed; the arguments are sizes, e.g. 6.1 GB and 15 GB")
    }

    static func converting(_ fraction: Double) -> String {
        String(localized: "Converting Google’s file · \(fraction.formatted(.percent.precision(.fractionLength(0))))",
               comment: "Settings → Models; the original model file chosen by the person is converted on this Mac; the argument is a percentage")
    }

    static func convertingPaused(_ fraction: Double) -> String {
        String(localized: "Converting Google’s file · \(fraction.formatted(.percent.precision(.fractionLength(0)))) · paused during the recording; it continues afterwards",
               comment: "Settings → Models; the conversion of the file the person chose waits for the recording to end; the argument is a percentage")
    }

    static func importedPart(missing: LanguageModelStatus.MissingPart) -> String {
        switch missing {
        case .tokenizer:
            String(localized: "Imported the model. Also choose tokenizer.json from the same model, or download just the tokenizer (\(tokenizerSize)).",
                   comment: "Settings → Models; the model weights were imported from a file and the tokenizer is still needed; tokenizer.json is a file name, not translated; the argument is a size, e.g. 32 MB")
        case .weights:
            String(localized: "Imported tokenizer.json. Also choose Google’s model.safetensors (\(originalSize)), or download the model (\(downloadSize)).",
                   comment: "Settings → Models; the tokenizer was imported from a file and the model is still needed; tokenizer.json and model.safetensors are file names, not translated; the arguments are sizes, e.g. 16 GB and 15 GB")
        }
    }

    static var verifying: String { String(localized: "Checking the model…", comment: "Settings → Models; the downloaded integrated model is being checked against the pinned checksums") }
    static var preparing: String { String(localized: "Preparing the model…", comment: "Settings → Models; the integrated model is loading for the first time") }
    static var deleting: String { String(localized: "Deleting the model…", comment: "Settings → Models; the integrated model is being removed") }

    static func ready(installedBytes: Int) -> String {
        installedBytes > 0
            ? String(localized: "Ready · \(size(installedBytes)) on this Mac.", comment: "Settings → Models; the integrated model is installed; the argument is its size on disk")
            : String(localized: "Ready.", comment: "Settings → Models; the integrated model is installed")
    }

    static func notChosen(provider: ModelProviderChoice) -> String {
        provider == .onDevice
            ? String(localized: "Installed. Minutes use Apple Intelligence.", comment: "Settings → Models; the integrated model is installed but the person chose Apple Intelligence")
            : String(localized: "Installed. Minutes use your model server.", comment: "Settings → Models; the integrated model is installed but the person chose a model server")
    }

    static func damaged(appleAvailable: Bool = true) -> String {
        appleAvailable
            ? String(localized: "The model files on this Mac are damaged. Until they’re repaired, Apple Intelligence writes minutes.",
                     comment: "Settings → Models; the installed integrated model no longer matches the pinned checksums")
            : String(localized: "The model files on this Mac are damaged. Until they’re repaired, Vauta can’t write minutes. You can also choose a model server.",
                     comment: "Settings → Models; the installed integrated model no longer matches the pinned checksums and Apple Intelligence is not available to stand in")
    }

    /// What the repair costs: it fetches from the first damaged tensor on, which can be most of the file.
    static var repairSize: String {
        String(localized: "Repair downloads up to about \(downloadSize) from Hugging Face, usually less.",
               comment: "Settings → Models; under the damaged integrated model, what the Repair button downloads; the argument is a size, e.g. 15 GB")
    }

    static func repairPaused(verified: Int, total: Int, appleAvailable: Bool = true) -> String {
        appleAvailable
            ? String(localized: "Repair paused at \(size(verified)) of \(size(total)). The model can’t be used until it’s repaired; Apple Intelligence writes minutes.",
                     comment: "Settings → Models; a repair of the damaged integrated model was paused or interrupted; the arguments are sizes, e.g. 6.1 GB and 15 GB")
            : String(localized: "Repair paused at \(size(verified)) of \(size(total)). The model can’t be used until it’s repaired, and Vauta can’t write minutes. You can also choose a model server.",
                     comment: "Settings → Models; a repair of the damaged integrated model was paused or interrupted and Apple Intelligence is not available to stand in; the arguments are sizes, e.g. 6.1 GB and 15 GB")
    }

    /// Who does what while recording. With Apple Intelligence the integrated model stays idle until the recording ends.
    static var readyLiveApple: String {
        String(localized: "Who writes live notes and answers questions during a meeting. With Apple Intelligence, the integrated model stays idle until the meeting ends, so minutes take longer to start.",
               comment: "Settings → Models; under the While recording choice of the integrated model")
    }

    // MARK: Errors

    static func failure(_ error: IntegratedModelError, appleAvailable: Bool = true) -> String {
        switch error {
        case .mismatch:
            String(localized: "The downloaded data didn’t match Google’s original. Nothing was installed.", comment: "Settings → Models; the integrated model failed a checksum")
        case .hostNotAllowed:
            String(localized: "Hugging Face sent the download to a server Vauta doesn’t allow. Nothing was downloaded from it.", comment: "Settings → Models; the download was redirected to a host that is not on the allowlist")
        case .revisionGone:
            String(localized: "This version of the model is no longer available from Hugging Face. You can import it from a file.", comment: "Settings → Models; the pinned revision was removed")
        case .offline:
            String(localized: "Couldn’t reach Hugging Face. Check your connection and try again.", comment: "Settings → Models; the download could not connect")
        case .diskFull(let needed):
            String(localized: "Not enough space: the model needs about \(size(needed)) free.", comment: "Settings → Models; the argument is the free space needed, e.g. 4.7 GB")
        case .importWrongFile:
            String(localized: "This isn’t the Gemma 4 E4B file Vauta needs (revision \(shortRevision)).", comment: "Settings → Models; a file chosen for import is not the model; Gemma 4 E4B and the revision are not translated")
        case .unexpectedResponse:
            String(localized: "Hugging Face answered with something Vauta didn’t expect. Nothing was installed.", comment: "Settings → Models; the server’s answer was not the requested range of the file")
        case .ioError:
            String(localized: "Vauta couldn’t write the model to disk. Nothing was installed.", comment: "Settings → Models; a file operation failed")
        case .unsupported:
            String(localized: "The integrated model can’t run on this Mac’s graphics.", comment: "Settings → Models; under the provider choice")
        case .tokenizerUnreadable:
            String(localized: "The model’s tokenizer couldn’t be read. Repair or delete the model.", comment: "Settings → Models")
        case .engineFailed:
            appleAvailable
                ? String(localized: "The model couldn’t run on this Mac. Apple Intelligence writes minutes instead.", comment: "Settings → Models")
                : String(localized: "The model couldn’t run on this Mac, and Vauta can’t write minutes until it does. You can also choose a model server.",
                         comment: "Settings → Models; the integrated model failed to run and Apple Intelligence is not available to stand in")
        case .nonFiniteWeights:
            String(localized: "The model file is damaged. Delete it and download again.", comment: "Settings → Models")
        }
    }

    static func offersImport(_ error: IntegratedModelError) -> Bool {
        switch error {
        case .mismatch, .hostNotAllowed, .revisionGone, .offline, .importWrongFile, .unexpectedResponse: true
        default: false
        }
    }

    static func isDiskFull(_ error: IntegratedModelError) -> Bool {
        if case .diskFull = error { return true }
        return false
    }

    // MARK: Confirmations

    static var cancelTitle: String { String(localized: "Cancel the download?", comment: "Confirmation title") }
    static var cancelRepairTitle: String { String(localized: "Stop the repair?", comment: "Confirmation title for stopping the repair of the integrated model") }
    static var discardTitle: String { String(localized: "Discard the paused download?", comment: "Confirmation title") }
    static var discardMessage: String {
        String(localized: "You’ll start from the beginning next time.", comment: "Confirmation of discarding a paused download of the integrated model: the next download starts over")
    }

    /// Stopping a repair deletes the installed model (its file was moved aside to be mended): the dialog says so.
    static func cancelRepairMessage(downloadSize: String) -> String {
        String(localized: "The damaged model will be deleted. You can download it again (\(downloadSize)). To continue later, keep repairing and use Pause on the card.",
               comment: "Confirmation of stopping the repair of the integrated model; the argument is the download size, e.g. 15 GB")
    }
    static var deleteTitle: String { String(localized: "Delete the integrated model?", comment: "Confirmation title") }

    static func cancelMessage(downloaded: Int) -> String {
        String(localized: "The \(size(downloaded)) downloaded so far will be deleted. To continue later, keep downloading and use Pause on the card.",
               comment: "Confirmation of cancelling the integrated model download; the argument is the size downloaded so far, e.g. 6.1 GB")
    }

    /// `liveIntegrated`: a recording runs and its live notes and questions use this model (the recording line is only for that).
    static func deleteMessage(chosen: Bool, liveIntegrated: Bool, freed: Int, appleAvailable: Bool = true) -> String {
        let space = size(freed)
        if chosen {
            let base = appleAvailable
                ? String(localized: "Minutes and answers go back to Apple Intelligence. Frees \(space). You can download it again (\(downloadSize)).",
                         comment: "Confirmation of deleting the integrated model while it is the chosen provider; the arguments are the space it frees and the download size, e.g. 4.2 GB and 15 GB")
                : String(localized: "Vauta can’t write minutes or answers until you choose another model or download this one again (\(downloadSize)). Frees \(space).",
                         comment: "Confirmation of deleting the integrated model while it is the chosen provider and Apple Intelligence is not available; the arguments are the download size and the space it frees, e.g. 15 GB and 4.2 GB")
            guard liveIntegrated else { return base }
            return [base, appleAvailable
                ? String(localized: "Live notes switch to Apple Intelligence for this recording.", comment: "Confirmation of deleting the integrated model during a recording")
                : String(localized: "Live notes stop for this recording.", comment: "Confirmation of deleting the integrated model during a recording on a Mac where Apple Intelligence is not available")].joinedAsSentences()
        }
        return String(localized: "Your choice for minutes doesn’t change. Frees \(space).", comment: "Confirmation of deleting the integrated model while it is not the chosen provider; the argument is the space it frees")
    }

    // MARK: Accessibility

    /// "6.1 of 15 gigabytes, about 25 minutes left": rounded to 100 MB and 1 minute.
    static func spokenProgress(received: Int, total: Int, secondsRemaining: Int?) -> String {
        let done = (Double(received) / 1_000_000_000 * 10).rounded() / 10, all = (Double(total) / 1_000_000_000 * 10).rounded() / 10
        let d = done.formatted(.number.precision(.fractionLength(0...1))), a = all.formatted(.number.precision(.fractionLength(0...1)))
        guard let secondsRemaining else {
            return String(localized: "\(d) of \(a) gigabytes", comment: "Accessibility value of the integrated model download progress")
        }
        let time = Duration.seconds(max(60, (secondsRemaining + 30) / 60 * 60)).formatted(.units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 1))
        return String(localized: "\(d) of \(a) gigabytes, about \(time) left", comment: "Accessibility value of the integrated model download progress; the last argument is a duration such as 25 minutes")
    }

    static func spokenPaused(_ progress: String) -> String {
        String(localized: "\(progress), paused", comment: "Accessibility value of the integrated model download progress while it is paused; the argument is the progress, e.g. 6.1 of 15 gigabytes")
    }

    // MARK: Status pane and activity

    static var statusReady: String { String(localized: "Ready", comment: "Settings → Status; the integrated model is ready") }
    static func statusDownloading(_ percent: Int) -> String {
        String(localized: "Downloading (\(percent)%)", comment: "Settings → Status; the integrated model is downloading; the argument is a percentage without the sign")
    }
    static func statusPausedForRecording(_ percent: Int) -> String {
        String(localized: "Paused during the recording (\(percent)%)", comment: "Settings → Status; the integrated model download waits for the recording to end; the argument is a percentage without the sign")
    }
    static func statusImportPaused(_ percent: Int) -> String {
        String(localized: "Import paused during the recording (\(percent)%)", comment: "Settings → Status; converting the file the person chose waits for the recording to end; the argument is a percentage without the sign")
    }
    static func statusRepairing(_ percent: Int) -> String {
        String(localized: "Repairing (\(percent)%)", comment: "Settings → Status; the integrated model is being repaired; the argument is a percentage without the sign")
    }
    static var statusDamaged: String { String(localized: "Damaged", comment: "Settings → Status; the integrated model files no longer match the checksums") }
    static var statusNotDownloaded: String { String(localized: "Not downloaded", comment: "Settings → Status; the integrated model is chosen but not downloaded") }
    static func statusImporting(_ percent: Int) -> String {
        String(localized: "Importing (\(percent)%)", comment: "Settings → Status; the integrated model is converted from a file the person chose; the argument is a percentage without the sign")
    }
    static var statusChecking: String { String(localized: "Checking the model", comment: "Settings → Status; the integrated model is being checked against its checksums") }
    static var statusPreparing: String { String(localized: "Preparing the model", comment: "Settings → Status; the integrated model is loading for the first time") }
    static func statusPaused(verified: Int, total: Int) -> String {
        String(localized: "Paused at \(size(verified)) of \(size(total))", comment: "Settings → Status; a paused download of the integrated model; the arguments are sizes, e.g. 6.1 GB and 15 GB")
    }
    static func statusNeeds(_ missing: LanguageModelStatus.MissingPart) -> String {
        switch missing {
        case .tokenizer: String(localized: "Needs tokenizer.json", comment: "Settings → Status; the integrated model is missing its tokenizer file, a file name that is not translated")
        case .weights: String(localized: "Needs model.safetensors", comment: "Settings → Status; the integrated model is missing its weights file, a file name that is not translated")
        }
    }

    static var activityReading: String {
        String(localized: "While recording, the integrated model reads the meeting as it goes, so minutes usually start sooner when it ends.",
               comment: "Settings → Models activity, with the integrated model as the provider")
    }

    /// "While recording" is Apple Intelligence: the integrated model reads nothing and is not loaded until the recording ends.
    static var activityIdleWhileRecording: String {
        String(localized: "While recording, Apple Intelligence writes live notes and the integrated model stays idle. Minutes read the whole meeting when it ends, so they take longer to start.",
               comment: "Settings → Models activity, with the integrated model as the provider and Apple Intelligence chosen for While recording")
    }

    /// The line of the Activity section about what the integrated model does during a recording.
    static func activityWhileRecording(liveOnApple: Bool) -> String { liveOnApple ? activityIdleWhileRecording : activityReading }

    static func activityFallback(appleAvailable: Bool = true) -> String {
        appleAvailable
            ? String(localized: "Using Apple Intelligence until the integrated model is ready.", comment: "Settings → Models activity; the integrated model is chosen but not ready")
            : String(localized: "Minutes can’t be written until the integrated model is ready.", comment: "Settings → Models activity; the integrated model is chosen but not ready and Apple Intelligence is not available to stand in")
    }

    static func appliedFallback(appleAvailable: Bool = true) -> String {
        appleAvailable
            ? String(localized: "Saved. Until the model is ready, Apple Intelligence writes minutes.", comment: "Settings → Models; result after the integrated model was chosen while it is still downloading")
            : String(localized: "Saved. Minutes can’t be written until the model is ready.", comment: "Settings → Models; result after the integrated model was chosen while it is not ready and Apple Intelligence is not available to stand in")
    }
}
