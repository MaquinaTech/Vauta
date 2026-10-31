// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The one width of the Meetings and Context sheets.
enum SheetLayout {
    static let width: CGFloat = 440
}

/// Import Recording: the file, its language, then progress with Cancel.
struct ImportRecordingSheet: View {
    @Bindable var model: RecordingImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(Text("Import Recording"), symbol: "square.and.arrow.down")
            if let file = model.file {
                // The file in the grey card the Backup and Restore sheets use, then the form under it.
                FileCard(name: file.fileName,
                         detail: file.duration > 0
                             ? Duration.seconds(file.duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) : nil)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        label("Transcription language")
                        Picker("Transcription language", selection: $model.languageID) {
                            ForEach(model.languages) { language in
                                Text(language.displayName.standaloneCapitalized).tag(language.id)
                            }
                        }
                        .labelsHidden()
                        .disabled(model.isWorking)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground()
                if let language = model.selectedLanguage, !language.isInstalled, !model.isWorking {
                    Label("The speech model for \(language.displayName) downloads once from Apple first.", systemImage: "arrow.down.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                // Said before importing: the meeting will not be on the file's date, so it is not looked for there.
                if let redating = model.redating, !model.isWorking {
                    Label(Self.text(of: redating), systemImage: "calendar.badge.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if model.phase == .inspecting {
                // The same spinner row as every other sheet that works (backup, restore, erase).
                BusyRow(title: String(localized: "Reading the file…", comment: "Import recording: shown while the chosen file is read"))
            }
            status
            if let failure = model.failure {
                // Icon coloured, text in the normal colour; the note says what to do.
                FeedbackLabel(feedback: .init(kind: .error, text: failure,
                                              note: model.failureIsLanguage
                                                  ? String(localized: "Choose another language, or try again.",
                                                           comment: "Import recording failed because of the transcription language: what to do")
                                                  : String(localized: "Try again, or choose another file.",
                                                           comment: "Import recording failed: what to do")))
            }
            SheetFootnote(String(localized: "The recording is transcribed on this Mac. The file isn’t changed, copied or uploaded."))
            HStack {
                if model.file == nil && model.phase == .ready {
                    Button("Choose Another File…") {
                        Task {
                            model.cancel()
                            await model.chooseFile()
                        }
                    }
                }
                Spacer()
                Button(model.isWorking ? "Stop" : "Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.phase == .saving)
                Button(importTitle) { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.phase != .ready || model.file == nil || model.selectedLanguage == nil)
            }
        }
        .padding(20)
        .frame(width: SheetLayout.width)
        .onChange(of: model.failure) { _, failure in
            if let failure { AccessibilityNotification.Announcement(failure).post() }
        }
    }

    /// A missing speech model is fixed by downloading it, not by trying the same thing again.
    private var importTitle: LocalizedStringKey {
        if model.failure == nil { return "Import" }
        return model.failureIsModelMissing ? "Download and Import" : "Try Again"
    }

    private func label(_ key: LocalizedStringKey) -> some View {
        Text(key).gridColumnAlignment(.leading)
    }

    static func text(of redating: RecordingImportPlan.Redating) -> String {
        switch redating {
        case .tooOld(let date):
            String(localized: "This recording is from \(date.formatted(date: .abbreviated, time: .omitted)). The meeting will be dated today, so its transcript isn’t deleted for its age.",
                   comment: "Import recording: the file is older than the transcripts are kept; the argument is its date")
        case .future(let date):
            String(localized: "The file is dated \(date.formatted(date: .abbreviated, time: .omitted)), in the future. The meeting will be dated today.",
                   comment: "Import recording: the file's date is later than now; the argument is that date")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .downloading(let p):
            ProgressView(value: p) { Text("Downloading the speech model…") }
        case .transcribing(let p):
            ProgressView(value: p) { Text("Transcribing… \(p.formatted(.percent.precision(.fractionLength(0))))") }
        case .saving:
            ProgressView { Text("Saving the meeting…") }
        default:
            EmptyView()
        }
    }
}

/// Export: format and options, then the save panel.
struct ExportSheet: View {
    let model: MeetingsModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("exportFormat") private var format: MeetingExportFormat = .markdown
    @AppStorage("exportIncludesTranscript") private var includeTranscript = true
    @AppStorage("exportIncludesTranslation") private var includeTranslation = false
    @AppStorage("exportIncludesParticipantsInformed") private var includeInformed = true
    @AppStorage("exportSpeakerLabels") private var storedSpeakerLabels: MeetingExportOptions.SpeakerLabels = .channels
    /// The choice for meetings with speaker data, kept apart from the one above: a meeting with speakers starts on
    /// names (the point of separating the speakers) until the user picks otherwise, and that pick is remembered for
    /// the next meeting with speakers, without touching what they chose for meetings without.
    @AppStorage("exportSpeakerLabelsWithSpeakers") private var storedWithSpeakers: MeetingExportOptions.SpeakerLabels?
    /// What the user picked in this sheet.
    @ViewLocalState private var pickedSpeakerLabels: MeetingExportOptions.SpeakerLabels?
    private var hasSpeakerData: Bool { !model.speakers.isEmpty && !model.speakersOff }
    private var speakerLabels: MeetingExportOptions.SpeakerLabels {
        pickedSpeakerLabels ?? (hasSpeakerData ? storedWithSpeakers ?? .names : storedSpeakerLabels)
    }
    private var speakerLabelsBinding: Binding<MeetingExportOptions.SpeakerLabels> {
        Binding(get: { speakerLabels }, set: { value in
            pickedSpeakerLabels = value
            if hasSpeakerData { storedWithSpeakers = value } else { storedSpeakerLabels = value }
        })
    }

    private var transcriptIncluded: Bool { format.isTranscriptOnly || includeTranscript }
    private var hasTranslations: Bool { !model.translations.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(Text("Export Meeting"), symbol: "square.and.arrow.up")
                .padding([.top, .horizontal], 20)
            form
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    let options = MeetingExportOptions(includeTranscript: transcriptIncluded,
                                                       includeTranslation: transcriptIncluded && includeTranslation && hasTranslations,
                                                       speakerLabels: speakerLabels,
                                                       includeParticipantsInformed: includeInformed)
                    let chosen = format
                    dismiss()
                    Task { await model.export(format: chosen, options: options) }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: SheetLayout.width)
    }

    private var form: some View {
        // One group, like the Import and Backup sheets: primary labels, leading, in one column.
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Format").gridColumnAlignment(.leading)
                        Picker("Format", selection: $format) {
                            ForEach(MeetingExportFormat.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                // The translation is a sub-option of the transcript.
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Include transcript", isOn: Binding(get: { transcriptIncluded }, set: { includeTranscript = $0 }))
                        .toggleStyle(.checkbox)
                        .disabled(format.isTranscriptOnly)
                    // Only meetings with a stored translation offer it: for the rest it would be a disabled row and a note.
                    if hasTranslations {
                        // Named with the language of the stored translation.
                        Toggle(translationTitle, isOn: Binding(get: { includeTranslation }, set: { includeTranslation = $0 }))
                            .toggleStyle(.checkbox)
                            .padding(.leading, 20)
                            .disabled(!transcriptIncluded)
                            .help("Write the stored translation under each line of “Others”")
                    }
                }
                RadioGroupRow(title: String(localized: "Speakers", comment: "Export option title: how speakers are labelled"), selection: speakerLabelsBinding,
                              options: MeetingExportOptions.SpeakerLabels.allCases.map { ($0, title(of: $0)) },
                              labelSpacing: 5)
                    .disabled(!transcriptIncluded)
                // Only a meeting marked "participants informed" offers it; subtitles have no header to write it in.
                if model.participantsInformedAt != nil {
                    Toggle("Say when the participants were informed", isOn: $includeInformed)
                        .toggleStyle(.checkbox)
                        .disabled(format.isTranscriptOnly)
                        .help("Write the time you marked that the participants were told the meeting was being recorded")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
            SheetFootnote(footer)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var translationTitle: LocalizedStringKey {
        guard let id = model.translationLanguage,
              let name = Locale.current.localizedString(forIdentifier: id) else { return "Include translation" }
        return "Include translation into \(name)"
    }

    private func title(of option: MeetingExportOptions.SpeakerLabels) -> String {
        switch option {
        case .channels: String(localized: "“\(Channel.me.displayName)” and “\(Channel.others.displayName)”")
        case .names: String(localized: "Names, when known")
        }
    }

    private var footer: String {
        let withTranslation = transcriptIncluded && includeTranslation && hasTranslations
        if format.isTranscriptOnly {
            return withTranslation
                ? String(localized: "Subtitles contain the transcript and its translation, with the time of each passage.")
                : String(localized: "Subtitles contain only the transcript, with the time of each passage.")
        }
        if !includeTranscript {
            return String(localized: "The file contains the summary, topics, decisions, tasks, open questions and notes.")
        }
        return withTranslation
            ? String(localized: "The file contains the summary, topics, decisions, tasks, open questions, notes and the transcript with its translation.")
            : String(localized: "The file contains the summary, topics, decisions, tasks, open questions, notes and the transcript.")
    }
}

/// A chosen file in the grey card of the Backup and Restore sheets: a document icon, its name and, when known,
/// a secondary line.
private struct FileCard: View {
    let name: String
    let detail: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(2).truncationMode(.middle)
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
            }
        } icon: {
            Image(systemName: "doc").foregroundStyle(.secondary)
        }
        .labelStyle(AlignedIconLabelStyle())
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}
