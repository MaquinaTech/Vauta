// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The steps of the guide (the app, the model, the server, using it) and the context fix.
extension ModelGuideSheet {
    // MARK: Step 4: use it

    /// What the footer button does, said where the steps are: the guide ends with it.
    var useStep: some View {
        GuideStep(number: guide.number(of: 4), title: savesTwoModels ? String(localized: "Use the models", comment: "Model guide step title: the last step, the footer button, with two models")
                                                    : String(localized: "Use the model", comment: "Model guide step title: the last step, the footer button"),
                  state: guide.stepState(4)) {
            // While the choice is checked the button is disabled: the note says what is happening instead of asking for the click.
            // The status strip says "Checking and saving…" with its spinner: not twice.
            if guide.phase != .applying {
                GuideNote(String(localized: "Click “\(useTitle)”. Vauta tests the server, saves it and uses it for minutes.",
                                 comment: "Model guide: what the last button does; the argument is the title of the button below"))
            }
        }
    }

    var appPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("App", selection: Binding(get: { guide.app }, set: { guide.app = $0 })) {
                ForEach(LocalModelApp.allCases) { app in
                    Text(app.displayName).tag(app)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(Text("App that runs the model", comment: "VoiceOver: picker of LM Studio or Ollama"))
            GuideNote(guide.app == .lmStudio
                ? String(localized: "Recommended: LM Studio runs its fast engine on every Apple silicon Mac.",
                         comment: "Model guide: why LM Studio is first")
                : String(localized: "Ollama is a good alternative if you already use it.",
                         comment: "Model guide: Ollama note"))
        }
    }

    // MARK: Step 1: the app

    var installStep: some View {
        let app = guide.app
        let installed = guide.isInstalled || guide.serverRunning
        return GuideStep(number: guide.number(of: 1), title: String(localized: "Install \(app.displayName)", comment: "Model guide step title; the argument is an app name"),
                         state: guide.stepState(1), summary: String(localized: "Installed"), isExpanded: isExpanded(1), toggle: toggle(1)) {
            if installed {
                HStack {
                    // The step's badge already says it is done: plain text, not a second check mark.
                    Text("Installed")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if guide.isInstalled {
                        Button(String(localized: "Open \(app.displayName)", comment: "Model guide button; the argument is an app name")) {
                            guide.openApp()
                        }
                    }
                }
            } else {
                HStack {
                    Text("Not installed")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "Get \(app.displayName)", comment: "Model guide button; the argument is an app name")) {
                        guide.openWebsite()
                    }
                    .buttonStyle(.borderedProminent)
                }
                GuideNote(String(localized: "Opens \(app.host) in your browser. Vauta doesn’t download anything.",
                                    comment: "Model guide note; the argument is a website host"))
            }
        }
    }

    // MARK: Step 2: the model

    var modelStep: some View {
        let app = guide.app
        let title = guide.models.count > 1 ? String(localized: "Download the models", comment: "Model guide step title when two models are downloaded")
                                           : String(localized: "Download the model", comment: "Model guide step title")
        return GuideStep(number: guide.number(of: 2), title: title, state: guide.stepState(2),
                         summary: guide.models.count > 1
                            ? String(localized: "downloaded.plural", defaultValue: "Downloaded", comment: "Model guide: summary of the finished download step when two models were downloaded")
                            : String(localized: "Downloaded", comment: "Model guide: summary of the finished download step"),
                         isExpanded: isExpanded(2), toggle: toggle(2)) {
            if guide.recommendation.tier == .large {
                GuideNote(String(localized: "This Mac has plenty of memory, so Vauta suggests a larger main model for minutes and a smaller fast model for live notes.",
                                    comment: "Model guide: explanation for Macs with 32 GB or more"))
            } else {
                GuideNote(String(localized: "Picked for the memory of this Mac, from the models Vauta was tested with.",
                                    comment: "Model guide: explanation for Macs with 16 to 31 GB"))
            }
            // The choice of how many models comes before the commands it changes.
            if guide.recommendation.fast != nil {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Use one model only", isOn: Binding(get: { !guide.includeFastModel }, set: { guide.includeFastModel = !$0 }))
                        .toggleStyle(.checkbox)
                        .disabled(guide.phase == .applying)
                    // Under the label, not under the box.
                    GuideNote(String(localized: "Skips the fast model. Live notes then use the main model, which is slower.",
                                        comment: "Model guide: one model only explanation"))
                        .padding(.leading, 21)
                }
            }
            // A warning comes before the commands it is about; the plain amount of free space after them.
            if guide.diskIsShort { diskRow }
            ForEach(guide.models) { model in
                modelBlock(model, app: app)
            }
            // The plain amount of free space answers "does it fit?": right after the size and the command, before the notes.
            if !guide.diskIsShort { diskRow }
            // The tip about other ways to download waits until this step is the one to do (the steps below stay in view).
            // Ollama has none: its button above is what its command needs.
            if guide.stepState(2) != .upcoming, app == .lmStudio {
                lmsNote
            }
            // Ollama's context length part lives in its folded, done "Open Ollama" step: while the model downloads, it is said
            // here, where the person is, so it is not found only later in the "context too small" state.
            if app == .ollama, guide.stepState(3) == .done, guide.stepState(2) != .done {
                GuideNote(String(localized: "Then set Context length to 32K in Ollama’s Settings.",
                                 comment: "Model guide: reminder in the download step of Ollama once the app runs; the context part of its first step is folded"))
            }
        }
    }

    /// Other ways to download with LM Studio. The command works once the app has been opened: that sentence goes away
    /// when the server was found (the app is open).
    var lmsNote: some View {
        let search = String(localized: "You can also search for the model name in the Discover tab of LM Studio.",
                            comment: "Model guide: another way to download with LM Studio")
        let command = guide.serverRunning ? nil
            : String(localized: "The \("lms") command works once LM Studio has been opened.",
                     comment: "Model guide: when the lms command works; the argument is the command name")
        return GuideNote([search, command].compactMap { $0 }.joinedAsSentences(), code: command == nil ? [] : ["lms"])
    }

    func modelBlock(_ model: LocalModel, app: LocalModelApp) -> some View {
        let size = Self.gigabytes(model.downloadGB(for: app))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.displayName).fontWeight(.semibold)
                Text("About \(size)", comment: "Model guide: download size; the argument is a size like “7 GB”")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(model.score) of 100 in our tests", comment: "Model guide: score of the model in the project's evaluation")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            switch model.install(for: app) {
            case .command(let command):
                // The instruction sits right above the command it is about.
                GuideNote(String(localized: "Paste this in Terminal:", comment: "Model guide: before a command; Terminal is the macOS app"))
                CommandBlock(command: command)
            case .searchTerm(let term):
                GuideNote(String(localized: "Search for “\(term)” in the app’s model browser.", comment: "Model guide; the argument is a search term"))
            }
        }
    }

    var diskRow: some View {
        return Group {
            if guide.diskIsShort, let free = guide.freeBytes {
                // Rounded up, so "needs 29, has 14" and "free up 15" add up for the reader.
                let needed = Self.gigabytes((Double(DiskSpace.requiredBytes(downloadGB: guide.downloadGB)) / 1_000_000_000).rounded(.up))
                VStack(alignment: .leading, spacing: 8) {
                    GuideStatusRow(kind: .warning,
                                   title: String(localized: "Not enough free space", comment: "Model guide warning title: the disk is too full for the download"),
                                   detail: diskAdvice(free: free, needed: needed), compactIcon: true)
                    // The pane where space is freed, as in the speech model page.
                    Button("Open Storage Settings") { Permissions.open(.storage) }
                        .wrapsToTwoLines()
                        .padding(.leading, GuideStatusRow.compactTextIndent)
                }
            } else if let free = guide.freeBytes {
                // The plain amount of free space is a note, not a status: it must not outweigh the commands.
                GuideNote(String(localized: "Free space on this Mac: \(Self.freeSpace(free)).", comment: "Model guide; the argument is a size"))
            }
        }
    }

    /// What to do about the missing space: the smaller choice if it fits, or how much to free.
    func diskAdvice(free: Int64, needed: String) -> String {
        let available = Self.freeSpace(free)
        let recommendation = guide.recommendation
        let mainOnlyFits = guide.includeFastModel && recommendation.fast != nil
            && !DiskSpace.isShort(downloadGB: recommendation.downloadGB(for: guide.app, includeFast: false), available: free)
        if mainOnlyFits {
            return String(localized: "Vauta needs about \(needed) (the download plus room to unpack); this Mac has \(available) free. Free up space first, or turn on the “Use one model only” option.",
                          comment: "Model guide: low disk space when one model would fit; arguments are two sizes")
        }
        let missing = max(0, DiskSpace.requiredBytes(downloadGB: guide.downloadGB) - free)
        let size = Self.gigabytes((Double(missing) / 1_000_000_000).rounded(.up))
        return String(localized: "Vauta needs about \(needed), including room to unpack. This Mac has \(available) free. Free up at least \(size).",
                      comment: "Model guide: low disk space; arguments are the size needed, the free space and the size to free up")
    }

    @ViewBuilder
    func contextBlock(app: LocalModelApp) -> some View {
        // Until step 3 is the one to do, its context length part is a closed heading: the four steps stay readable in
        // one view, and the part opens on a click.
        // Ollama's part stays closed until its app is open too: the app comes first, and the context is what is left once it runs.
        let foldable = guide.stepState(3) == .upcoming || (guide.app == .ollama && !guide.serverRunning)
        let folded = foldable && !contextOpen
        VStack(alignment: .leading, spacing: 6) {
            // A sub-heading, one level under the step title; once the server runs the title already names the context.
            if !(guide.serverRunning && guide.stepState(3) != .done) {
                if foldable {
                    // The same disclosure as a finished step: the title, then the chevron at the trailing edge, turning down when open.
                    Button { contextOpen.toggle() } label: {
                        HStack(spacing: 8) {
                            Text("Context length").font(.callout.weight(.semibold))
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(folded ? 0 : 90))
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // A sub-heading of step 3, not a step: its own words for VoiceOver.
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityValue(folded ? Text(String(localized: "context.length.collapsed", defaultValue: "collapsed", comment: "VoiceOver: the context length part of the server step, closed"))
                                               : Text(String(localized: "context.length.expanded", defaultValue: "expanded", comment: "VoiceOver: the context length part of the server step, open")))
                    .accessibilityHint(Text("Shows or hides how to set the context length", comment: "VoiceOver hint of the context length part of the server step"))
                } else {
                    Text("Context length").font(.callout.weight(.semibold))
                }
            }
            if folded {
                EmptyView()
            } else if case .contextTooSmall(let shortfall) = guide.status {
                // A model is loaded with too little: the fix, outlined, is here (the strip above the footer points to it).
                contextFix(for: shortfall)
                    .trackFrame(Self.fixKey, in: Self.contentSpace, into: $blockFrames)
            } else {
                switch app {
                case .lmStudio:
                    GuideNote(String(localized: "Vauta needs a context length of at least 32K tokens. In Terminal, load the model like this:",
                                     comment: "Model guide: context length instruction before a command; Terminal is the macOS app"))
                    // Every model Vauta will use needs the context, the fast one too.
                    ForEach(guide.models) { model in
                        if case .command(let command) = model.contextFix(for: app) { CommandBlock(command: command) }
                    }
                case .ollama:
                    GuideNote(String(localized: "Vauta needs a context length of at least 32K tokens. In Ollama, open Settings and move the “Context length” slider to 32K.",
                                     comment: "Model guide: Ollama context instruction"))
                }
            }
        }
    }

    // MARK: Step 3: the server

    var serverStep: some View {
        let app = guide.app
        // Ollama serves on its own: its step is to open the app.
        // Once the server runs, what is left in this step is the context: the title says so instead of asking to start it.
        let title: String
        if guide.serverRunning, guide.stepState(3) != .done {
            title = app.startServerCommand != nil ? String(localized: "Load the model with a longer context length", comment: "Model guide step title once the LM Studio server runs and the context is too small")
                                                  : String(localized: "Set the context length", comment: "Model guide step title once the Ollama server runs and the context is too small")
        } else {
            title = app.startServerCommand != nil ? String(localized: "Start the server", comment: "Model guide step title")
                                                  : String(localized: "Open \(app.displayName)", comment: "Model guide button; the argument is an app name")
        }
        return GuideStep(number: guide.number(of: 3), title: title, state: guide.stepState(3),
                         summary: String(localized: "Running", comment: "Model guide: summary of the finished server step"),
                         isExpanded: isExpanded(3), toggle: toggle(3)) {
            // Done before the steps above it: say why the badge is already checked.
            if guide.stepState(3) == .done, guide.stepOrder.prefix { $0 != 3 }.contains(where: { guide.stepState($0) != .done }) {
                GuideStatusRow(kind: .info, title: String(localized: "The \(app.displayName) server is already running",
                                                          comment: "Model guide: step 3 is done early; the argument is an app name"))
            }
            // Not while it runs: then the one thing left in this step is the context.
            if !guide.serverRunning {
                if let command = app.startServerCommand {
                    GuideNote(String(localized: "In LM Studio, open the Developer tab and turn the server on, or paste this in Terminal:",
                                        comment: "Model guide: how to start the LM Studio server; Terminal is the macOS app"))
                    CommandBlock(command: command)
                } else {
                    // As in step 1: the state, with the action trailing on its line, then the explanation.
                    if guide.isInstalled {
                        HStack {
                            Text("Not running")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(String(localized: "Open \(app.displayName)", comment: "Model guide button; the argument is an app name")) {
                                guide.openApp()
                            }
                        }
                    }
                    GuideNote(String(localized: "Ollama serves on its own while its app is open. Look for its icon in the menu bar.",
                                        comment: "Model guide: Ollama needs no server step"))
                }
            }
            contextBlock(app: app)
        }
    }

    @ViewBuilder
    func contextFix(for shortfall: ContextShortfall) -> some View {
        let app = LocalModelApp.allCases.first { $0.serverKind == shortfall.serverKind } ?? guide.app
        VStack(alignment: .leading, spacing: 6) {
            switch shortfall.model.contextFix(for: app, loadedID: shortfall.modelID) {
            case .command(let command):
                GuideNote(String(localized: "Vauta needs a context length of at least 32K tokens. In Terminal, load it again with a longer context length:",
                                    comment: "Model guide: before a command that reloads a model; Terminal is the macOS app"))
                CommandBlock(command: command, highlighted: true)
            case .appSetting:
                GuideNote(String(localized: "In Ollama, open Settings and move the “Context length” slider to 32K. Then paste this in Terminal to unload the model (Vauta loads it again on its own):",
                                    comment: "Model guide: Ollama context fix; Terminal is the macOS app"))
                CommandBlock(command: "ollama stop \(shortfall.model.identifier(for: .ollama))", highlighted: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
