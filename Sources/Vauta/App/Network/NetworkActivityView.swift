// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// The Network Activity window: every connection Vauta has made since it started
/// (metadata only), with the places it went, a filter, export and clear.
struct NetworkActivityView: View {
    @Bindable var model: NetworkActivityModel
    /// Goes to Settings → Models (for a destination outside the local network).
    var openModels: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Every connection Vauta has made since it started: where it went, when and how much. Never the content.",
                     comment: "Network Activity window subtitle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                aboutButton
                Spacer(minLength: 0)
            }
            if model.entries.isEmpty {
                EmptyStateView(Text("No Network Activity Yet", comment: "Empty state title"),
                               symbol: "network.slash",
                               message: String(localized: "Connections appear here as Vauta makes them.", comment: "Network Activity empty state"),
                               messageWidth: 420)
                    .frame(minHeight: 140)
            } else {
                NetworkSummaryView(destinations: model.destinations, blocked: model.blocked, openModels: openModels)
                filterBar
                NetworkRequestTable(entries: model.visible)
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 560)
        .task { await model.run() }
    }

    /// What the list can't show and what its sizes mean: in a popover, so the table gets the window's height.
    private var aboutButton: some View {
        LearnMoreButton(accessibilityName: String(localized: "What this list doesn’t show", comment: "Network Activity: tooltip and VoiceOver label of the info button"), bare: true) { NetworkAboutNote() }
            .help(Text("What this list doesn’t show", comment: "Network Activity: tooltip and VoiceOver label of the info button"))
    }

    private var filterBar: some View {
        // The counter's first line shares the pop-up's baseline; the caption hangs below it.
        HStack(alignment: .firstTextBaseline) {
            Picker(selection: $model.filter) {
                Text("All Purposes", comment: "Network Activity filter: no filter").tag(NetworkPurpose?.none)
                Divider()
                ForEach(model.purposes, id: \.self) { purpose in
                    Text(purpose.displayName).tag(NetworkPurpose?.some(purpose))
                }
            } label: {
                Text("Purpose", comment: "Network Activity filter label")
            }
            .fixedSize()
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Group {
                    if model.isFiltering {
                        // Plural on the total (stringsdict): "1 of 1 request", "3 of 12 requests".
                        Text("\(model.visibleRequests) of \(model.totalRequests) requests", comment: "Network Activity: requests listed with a purpose filter on, out of all; arguments are two counts")
                    } else {
                        Text("\(model.visibleRequests) requests", comment: "Network Activity: number of listed requests; argument is a count")
                    }
                }
                .font(.callout)
                // The counter counts requests; the table lists rows. Say so while the two differ.
                if model.groupsRepeats {
                    Text("Repeated requests share one row.", comment: "Network Activity: under the request counter, when identical requests are grouped in one row of the table (the row shows N×)")
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Kept in memory only, for the last \(NetworkActivityLog.defaultCapacity) requests. Nothing is saved unless you export it.",
                     comment: "Network Activity footer; argument is a number of requests")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let feedback = model.exportFeedback {
                    FeedbackLabel(feedback: feedback)
                    if let file = model.exportedFile {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                            .controlSize(.small)
                            .padding(.leading, 28)
                    }
                }
            }
            Spacer(minLength: 16)
            Button("Clear List") { Task { await model.clear() } }
                .disabled(model.entries.isEmpty)
            Button("Export JSON…") { Task { await model.export() } }
                .disabled(model.entries.isEmpty)
        }
    }
}

/// The places Vauta connected to, with totals: the answer to "does it talk to anyone else?".
struct NetworkSummaryView: View {
    let destinations: [NetworkDestination]
    /// Requests refused before they were sent: not connections, but never hidden.
    var blocked: [NetworkActivityEntry] = []
    /// Goes to Settings → Models; nil where there is no Settings window to go to.
    var openModels: (() -> Void)?

    private var anyOutside: Bool { destinations.contains { $0.scope == .outside } }

    /// The summary counts the destinations Vauta's rules expect; a download the person started is listed below with its own name.
    private var headline: Text {
        let base = countedHeadline
        // The recognisable host first (huggingface.co), then the download servers it names.
        let names: [String] = destinations.filter { $0.scope == .download }.map { $0.label.split(separator: ":").first.map(String.init) ?? $0.label }
        let hosts = names.filter { $0 == "huggingface.co" } + names.filter { $0 != "huggingface.co" }.sorted()
        guard !hosts.isEmpty, destinations.contains(where: { $0.scope != .download }) else { return base }
        // Never "Only 2 … all on this Mac" over a list of four rows: with downloads below, the count says what it counts and the
        // downloads follow in the same breath.
        return countedHeadline(withDownloads: true) + Text("Space between two summary sentences", comment: "A space in English; ja and zh-Hans use an invisible word joiner (U+2060), because they put no space after a full-width full stop") + Text("Plus downloads you started from \(hosts.formatted(.list(type: .and))).",
                                                comment: "Network Activity summary, after the count of destinations; the argument is the list of hosts of the downloads the person started, e.g. huggingface.co and us.aws.cdn.hf.co")
    }

    private var countedHeadline: Text { countedHeadline(withDownloads: false) }

    private func countedHeadline(withDownloads: Bool) -> Text {
        let counted = destinations.filter { $0.scope != .download }
        let outside = counted.filter { $0.scope == .outside }.count
        if counted.isEmpty, !destinations.isEmpty { return Text(NetworkDestination.Scope.download.displayName) }
        if outside > 0 {
            return Text("\(counted.count) destinations, \(outside) outside your local network.", comment: "Network Activity summary; arguments are the number of destinations and how many of them are outside the local network")
        } else {
            if withDownloads {
                return counted.allSatisfy({ $0.scope == .thisMac })
                    ? Text("\(counted.count) destinations on this Mac.", comment: "Network Activity summary when downloads are listed too and every other destination is on this Mac; argument is a count")
                    : Text("\(counted.count) destinations on your Mac or your local network.", comment: "Network Activity summary when downloads are listed too; argument is a count")
            }
            if counted.allSatisfy({ $0.scope == .thisMac }) {
                return Text("Only \(counted.count) destinations, all on this Mac.", comment: "Network Activity summary when every destination is on this Mac; argument is a count")
            }
            return Text("Only \(counted.count) destinations, all on your Mac or your local network.", comment: "Network Activity summary; argument is a count")
        }
    }

    /// The sentence with each address in the monospaced font of the destinations above and below it.
    private static func monospacingAddresses(_ places: [String], in sentence: String) -> AttributedString {
        var text = AttributedString(sentence)
        for place in places {
            var from = text.startIndex
            while from < text.endIndex, let range = text[from...].range(of: place) {
                text[range].font = .callout.monospaced()
                from = range.upperBound
            }
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The one state this window exists to flag: the warning symbol comes first, and the follow-up sits in the
            // headline's own text column with the button at its trailing edge.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if anyOutside {
                    StatusSymbol.warning.image
                        .font(.headline)
                        .frame(width: 20, alignment: .center)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    headline
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    if anyOutside {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("Vauta only expects connections on your Mac or local network. Check the address of your model server.",
                                 comment: "Network Activity: under the summary when a destination is outside the local network")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            if let openModels {
                                Button(SettingsModel.Pane.models.openTitle, action: openModels)
                            }
                        }
                    }
                }
            }
            // A grid, so the counts and sizes line up in columns from one destination to the next.
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                ForEach(destinations) { destination in
                    if destination.id != destinations.first?.id { Divider() }
                    DestinationRow(destination: destination, anyFailures: destinations.contains { $0.failures > 0 })
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .cardBackground()
            if !blocked.isEmpty {
                // The headline is about what was sent; refused requests are said here, so it never seems to contradict the list.
                let places = blocked.map(\.destination).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                let sentence = String(localized: "Blocked before sending: \(places.formatted(.list(type: .and))). Nothing left this Mac.",
                                      comment: "Network Activity summary; the argument is a list of addresses that requests were refused for")
                Label {
                    Text(Self.monospacingAddresses(places, in: sentence))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                }
                .labelStyle(AlignedIconLabelStyle())
                .font(.callout)
                .foregroundStyle(.secondary)
                // The icon sits in the card's icon column.
                .padding(.horizontal, 12)
            }
        }
    }
}

private struct DestinationRow: View {
    let destination: NetworkDestination
    /// Whether any row shows a failure count, so the column exists for every row.
    let anyFailures: Bool

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            ScopeIcon(scope: destination.scope)
            Text(verbatim: destination.label)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Text(destination.scope.displayName)
                .foregroundStyle(destination.scope == .outside ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .gridColumnAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(destination.requests) requests", comment: "Network Activity: requests to one destination; argument is a count")
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
            if anyFailures {
                Group {
                    if destination.failures > 0 {
                        // Only the icon is orange: orange words are hard to read on the light card.
                        Label {
                            Text("\(destination.failures) failed")
                        } icon: {
                            Image(systemName: StatusSymbol.warning.name).foregroundStyle(.orange)
                        }
                        .labelStyle(.titleAndIcon)
                        .monospacedDigit()
                    } else {
                        Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                    }
                }
                .gridColumnAlignment(.leading)
            }
            // The arrow sits right before its size, in one trailing-aligned cell: the totals end on one edge.
            HStack(spacing: 4) {
                Image(systemName: "arrow.up").accessibilityHidden(true)
                Text(NetworkFormat.bytes(destination.bytesSent)).monospacedDigit()
            }
            .gridColumnAlignment(.trailing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Sent \(NetworkFormat.bytes(destination.bytesSent))", comment: "VoiceOver; argument is a size"))
            HStack(spacing: 4) {
                Image(systemName: "arrow.down").accessibilityHidden(true)
                Text(NetworkFormat.bytes(destination.bytesReceived)).monospacedDigit()
            }
            .gridColumnAlignment(.trailing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Received \(NetworkFormat.bytes(destination.bytesReceived))", comment: "VoiceOver; argument is a size"))
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// This Mac, the local network, or a warning for anywhere else.
private struct ScopeIcon: View {
    let scope: NetworkDestination.Scope

    var body: some View {
        switch scope {
        case .thisMac: Image(systemName: StatusSymbol.thisMac).foregroundStyle(.secondary).frame(width: 20).accessibilityHidden(true)
        case .localNetwork: Image(systemName: "wifi.router").foregroundStyle(.secondary).frame(width: 20).accessibilityHidden(true)
        case .outside: Image(systemName: StatusSymbol.warning.name).foregroundStyle(.orange).frame(width: 20).accessibilityHidden(true)
        case .download: Image(systemName: "arrow.down.circle").foregroundStyle(.secondary).frame(width: 20).accessibilityHidden(true)
        }
    }
}

/// The requests, newest first.
private struct NetworkRequestTable: View {
    let entries: [NetworkActivityEntry]

    var body: some View {
        // The table takes all the height between the filter and the footer, so it looks finished at any row count.
        table
            .frame(minHeight: 160, maxHeight: .infinity)
            .layoutPriority(1)
    }

    private var table: some View {
        Table(entries) {
            TableColumn(Text("Time", comment: "Network Activity column")) { entry in
                CellInset {
                    // The narrow no-break space before AM/PM is nearly invisible at this size: a plain no-break space reads as a space.
                    Text(verbatim: entry.lastTimestamp.formatted(.dateTime.hour().minute().second()).replacingOccurrences(of: "\u{202F}", with: "\u{00A0}"))
                        .monospacedDigit()
                        .help(entry.count > 1 ? NetworkFormat.repeatedHelp(entry) : "")
                }
            }
            .width(min: NetworkFormat.timeColumnWidth, ideal: NetworkFormat.timeColumnWidth, max: NetworkFormat.timeColumnWidth + 8)
            TableColumn(Text("Purpose", comment: "Network Activity column")) { entry in
                CellInset {
                    Text(entry.purpose.displayName)
                        .help(entry.purpose.displayName)
                }
            }
            .width(min: 250, ideal: 280, max: 380)
            TableColumn(Text("Destination", comment: "Network Activity column")) { entry in
                CellInset {
                    DestinationCell(entry: entry)
                }
            }
            .width(min: 150, ideal: 160, max: 240)
            TableColumn(Text("Request", comment: "Network Activity column: HTTP method and path")) { entry in
                CellInset {
                    HStack(spacing: 6) {
                        Text(verbatim: entry.method + " " + entry.path)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            // The method and the file name (the end of the path) say the most: the middle is what is cut.
                            .truncationMode(.middle)
                            .help(Text(verbatim: entry.method + " " + entry.path))
                            .accessibilityLabel(Text(verbatim: entry.method + " " + entry.path))
                            // Copy takes the whole request, whatever the column cut.
                            .contextMenu {
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.method + " " + entry.path, forType: .string)
                                }
                            }
                        if entry.count > 1 {
                            Text("\(entry.count)×", comment: "Network Activity: how many identical probes one row stands for; argument is a count")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .help(NetworkFormat.repeatedHelp(entry))
                        }
                    }
                }
            }
            // The path is the fact the person came here to check: it gets the room the other columns do not need.
            .width(min: 200, ideal: 270, max: 760)
            TableColumn(Text("Sent", comment: "Network Activity column; the sizes are approximate, which the info popover says")) { entry in
                CellInset {
                    if entry.blocked != nil {
                        NotSentDash()
                    } else {
                        Text(NetworkFormat.bytes(entry.bytesSent)).monospacedDigit()
                            .help(NetworkFormat.approximateNote)
                    }
                }
            }
            .width(min: 64, ideal: 70, max: 84)
            .alignment(.numeric)
            TableColumn(Text("Received", comment: "Network Activity column; the sizes are approximate, which the info popover says")) { entry in
                CellInset {
                    if entry.blocked != nil {
                        NotSentDash()
                    } else if entry.isInProgress {
                        Text(verbatim: "—")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("In progress", comment: "Network Activity result: the request has not finished"))
                    } else {
                        Text(NetworkFormat.bytes(entry.bytesReceived)).monospacedDigit()
                            .help(NetworkFormat.approximateNote)
                    }
                }
            }
            .width(min: 76, ideal: 84, max: 100)
            .alignment(.numeric)
            TableColumn(Text("Result", comment: "Network Activity column")) { entry in
                CellInset {
                    ResultLabel(entry: entry)
                }
            }
            .width(min: 150, ideal: 160, max: 240)
            TableColumn(Text("Duration", comment: "Network Activity column")) { entry in
                CellInset {
                    if let seconds = entry.duration, entry.blocked == nil {
                        Text(NetworkFormat.duration(seconds)).monospacedDigit()
                    } else {
                        // Refused before it was sent, or not finished: there is no duration (the Result column says which).
                        Text(verbatim: "—")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .width(min: 60, ideal: 64, max: 84)
            .alignment(.numeric)
        }
        .tableStyle(.bordered(alternatesRowBackgrounds: true))
        .scrollIndicators(.visible)
    }
}

/// A table cell shifted right by the header's own inset, so the column titles and their values start on one edge.
private struct CellInset<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View { content.padding(.leading, 2) }
}

/// A request refused before sending has no sizes: a dash, not a measured "0 bytes".
private struct NotSentDash: View {
    var body: some View {
        Text(verbatim: "—")
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Not sent", comment: "Network Activity: the size of a request that was refused before it was sent"))
    }
}

/// Success, failure or "in progress", always with an icon and a word.
private struct ResultLabel: View {
    let entry: NetworkActivityEntry

    var body: some View {
        if let reason = entry.blocked {
            // The word and the hand in the cell; the reason in the tooltip and for VoiceOver (the cell is too narrow for it).
            Label {
                Text("Blocked", comment: "Network Activity result: refused before it was sent")
            } icon: {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            }
            .labelStyle(AlignedIconLabelStyle(width: 16))
            .help(Text("Blocked before it was sent: \(reason.displayName). Nothing went over the network.", comment: "Network Activity tooltip; the argument says why"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Blocked: \(reason.displayName)", comment: "Network Activity result: refused before it was sent; the argument says why"))
        } else if entry.isInProgress {
            Label {
                Text("In progress", comment: "Network Activity result: the request has not finished")
            } icon: {
                StatusSymbol.running.image
            }
            .labelStyle(AlignedIconLabelStyle(width: 16))
        } else if let error = entry.error {
            if entry.isExpectedProbeMiss {
                // Looking for a server that isn't running is normal, not a fault.
                Label {
                    Text("Nothing running", comment: "Network Activity result: a server discovery probe found nothing at the address")
                        .foregroundStyle(.secondary)
                        .help(Text("No server answered at this address. Vauta looks for model servers on this Mac, so this is expected.",
                                   comment: "Network Activity tooltip for a discovery probe that found nothing"))
                } icon: {
                    StatusSymbol.inactive.image
                }
                .labelStyle(AlignedIconLabelStyle(width: 16))
            } else {
                Label {
                    Text(error.displayName)
                        .help(error.displayName)
                } icon: {
                    Image(systemName: StatusSymbol.warning.name).foregroundStyle(.orange)
                }
                .labelStyle(AlignedIconLabelStyle(width: 16))
            }
        } else {
            Label {
                Text(Self.statusText(entry.status))
                    .monospacedDigit()
            } icon: {
                Image(systemName: entry.isSuccess ? StatusSymbol.ok.name : StatusSymbol.warning.name)
                    .foregroundStyle(entry.isSuccess ? .green : .orange)
            }
            .labelStyle(AlignedIconLabelStyle(width: 16))
            .help(entry.status.map { HTTPURLResponse.localizedString(forStatusCode: $0).localizedCapitalized } ?? "")
        }
    }
}

extension ResultLabel {
    /// The HTTP status in words, with the code kept for anyone who knows it: "OK (200)", "Busy (503)".
    static func statusText(_ status: Int?) -> String {
        guard let code = status else { return "" }
        switch code {
        case 200..<300: return String(localized: "OK (\(code))", comment: "Network Activity result; the argument is an HTTP status code")
        case 300..<400: return String(localized: "Redirected (\(code))", comment: "Network Activity result; the argument is an HTTP status code")
        case 401, 403: return String(localized: "Key rejected (\(code))", comment: "Network Activity result; the argument is an HTTP status code")
        case 404: return String(localized: "Not found (\(code))", comment: "Network Activity result; the argument is an HTTP status code")
        case 429, 503: return String(localized: "Busy (\(code))", comment: "Network Activity result; the argument is an HTTP status code")
        case 400..<500: return String(localized: "Refused (\(code))", comment: "Network Activity result; the argument is an HTTP status code")
        default: return String(localized: "Server error (\(code))", comment: "Network Activity result; the argument is an HTTP status code")
        }
    }
}

/// The address, always flush with its header; a warning icon follows it when the request went outside the local
/// network (Vauta's rules never allow that). A blocked request has no icon: the Result column carries the hand.
private struct DestinationCell: View {
    let entry: NetworkActivityEntry

    var body: some View {
        if entry.blocked != nil {
            address
                .help(Text(verbatim: entry.destination) + Text(verbatim: "\n")
                      + Text("Blocked before it was sent. Nothing went over the network.", comment: "Network Activity tooltip for the address of a blocked request"))
                .accessibilityLabel(Text(verbatim: entry.destination))
        } else if entry.scope == .outside {
            HStack(spacing: 6) {
                address
                Image(systemName: StatusSymbol.warning.name).foregroundStyle(.orange)
            }
            .help(Text(verbatim: entry.destination) + Text(verbatim: "\n") + Text(entry.scope.displayName))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: entry.destination + ", " + entry.scope.displayName))
        } else {
            address
                .help(Text(verbatim: entry.destination))
                .accessibilityLabel(Text(verbatim: entry.destination))
        }
    }

    private var address: some View {
        Text(verbatim: entry.destination).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
    }
}

/// The info button's popover: what the list doesn't show, and what its sizes mean.
struct NetworkAboutNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NotShownNote()
            Text(description: NetworkFormat.approximateNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                // On the text column of the note above (past its icon), not under the icon.
                .padding(.leading, 28)
        }
        .padding(16)
        .frame(width: 420)
    }
}

/// What the list cannot show, because macOS (not Vauta) makes those connections.
struct NotShownNote: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Not shown here", comment: "Network Activity note title")
                    .font(.callout.weight(.semibold))
                Text(description: String(localized: "macOS makes these downloads itself, not Vauta: speech recognition and translation languages, and Apple Intelligence model files. To watch everything your Mac sends, use a network monitor such as Little Snitch or\u{00A0}LuLu.",
                                         comment: "Network Activity note: what the list does not cover"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .labelStyle(AlignedIconLabelStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum NetworkFormat {
    /// Sizes count only what is in the request and response bodies.
    static var approximateNote: String {
        String(localized: "Sizes are approximate: only the body of each request and response is counted, not headers or connection overhead.",
               comment: "Network Activity: what the Sent and Received sizes mean")
    }

    /// For a row that stands for several identical probes.
    static func repeatedHelp(_ entry: NetworkActivityEntry) -> String {
        let first = entry.timestamp.formatted(.dateTime.hour().minute().second())
        let last = entry.lastTimestamp.formatted(.dateTime.hour().minute().second())
        return String(localized: "\(entry.count) identical requests: the first at \(first), the latest at \(last).",
                      comment: "Network Activity tooltip; arguments are a count and two times")
    }

    static func bytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return ByteSize.glued(formatter.string(fromByteCount: Int64(count)))
    }

    /// "30 ms", "4.1 sec", "48 sec": milliseconds under a second, then seconds, with the language's own
    /// abbreviation and spacing (the narrow width drops the space in some languages and keeps it in others).
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return Measurement(value: (seconds * 1000).rounded(), unit: UnitDuration.milliseconds)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
        }
        return Measurement(value: seconds, unit: UnitDuration.seconds)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(seconds < 10 ? 1 : 0))))
    }

    /// The Time column: seconds in 24 hours, or with AM/PM (English, Korean…), whichever the language uses.
    static var timeColumnWidth: CGFloat {
        let template = DateFormatter.dateFormat(fromTemplate: "jms", options: 0, locale: .current) ?? ""
        return template.contains("a") ? 104 : 72
    }
}

/// The Network Activity window with its way to Settings → Models.
struct NetworkActivityWindow: View {
    let model: NetworkActivityModel
    let settings: SettingsModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NetworkActivityView(model: model, openModels: {
            settings.pane = .models
            openWindow(id: "settings")
            NSApp.activate()
        })
    }
}
