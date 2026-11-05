// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Settings → General → Updates: the automatic check, Check Now, and Update… when a newer release exists.
struct UpdatesSection: View {
    @Bindable var model: UpdateModel

    var body: some View {
        Section {
            Toggle(isOn: $model.checksAutomatically) {
                Text("Check for updates automatically", comment: "Settings → General → Updates: switch")
                Text(description: String(localized: "Once a day Vauta asks GitHub for the number of the latest release. Nothing about you, this Mac or your meetings is sent, and Network Activity lists the request.",
                                         comment: "Settings → General → Updates, under the automatic check switch"))
            }
            HStack(alignment: .firstTextBaseline) {
                status
                Spacer()
                Button {
                    model.checkNow()
                } label: {
                    Text("Check Now", comment: "Settings → General → Updates: asks GitHub for the latest release now")
                }
                .disabled(model.state == .checking || model.installed == nil)
            }
            if let version = model.availableVersion {
                HStack {
                    Button {
                        model.update()
                    } label: {
                        Text("Update…", comment: "Settings → General → Updates: opens Terminal, where scripts/update.sh verifies and installs the new release")
                    }
                    .buttonStyle(.borderedProminent)
                    Link(destination: UpdateDestination.releasePage(version)) {
                        Text("Release Notes", comment: "Settings → General → Updates: link to the release page on GitHub")
                    }
                }
                launchNote
            }
        } header: {
            Text("Updates", comment: "Settings → General: section with the update check")
        } footer: {
            if model.availableVersion != nil {
                SettingsNote(String(localized: "Update… opens Terminal. There, scripts/update.sh checks that the release is signed with the maintainer’s key, shows its notes and asks before it builds, tests and installs it, which takes about 15 minutes. Vauta then quits and opens again: don’t start a recording until it has.",
                                    comment: "Settings → General → Updates, under Update…; scripts/update.sh is a file name and stays as it is"))
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .idle:
            NoticeLabel(Text("Vauta \(model.installed?.description ?? "") is installed.", comment: "Settings → General → Updates, before any check; the argument is a version number"),
                        status: .info, secondary: true, note: lastChecked)
        case .checking:
            NoticeLabel(Text("Checking for updates…", comment: "Settings → General → Updates"), status: .info, secondary: true)
        case .upToDate(let installed):
            NoticeLabel(Text("Vauta \(installed.description) is up to date.", comment: "Settings → General → Updates; the argument is a version number"),
                        status: .ok, note: lastChecked)
        case .available(let version):
            NoticeLabel(Text("Vauta \(version.description) is available. You have \(model.installed?.description ?? "").",
                             comment: "Settings → General → Updates; the arguments are the new version number and the installed one"),
                        status: .info, note: lastChecked)
        case .failed(let error):
            NoticeLabel(Text("Couldn’t check for updates.", comment: "Settings → General → Updates"), status: .warning, note: Text(reason(error)))
        case .noVersion:
            NoticeLabel(Text("This build has no version number, so it can’t be compared with the releases.", comment: "Settings → General → Updates, in a development build"),
                        status: .info, secondary: true)
        }
    }

    private var lastChecked: Text? {
        model.lastChecked.map { date in
            Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened)).", comment: "Settings → General → Updates; the argument is a date and time")
        }
    }

    private func reason(_ error: UpdateCheckError) -> String {
        switch error {
        case .unreachable:
            String(localized: "GitHub can’t be reached. Vauta tries again later.", comment: "Settings → General → Updates: why the check failed")
        case .rateLimited:
            String(localized: "GitHub asked to wait before checking again. Vauta tries again later.", comment: "Settings → General → Updates: why the check failed (rate limit)")
        case .refused(let status):
            String(localized: "GitHub answered with an error (\(status)).", comment: "Settings → General → Updates: why the check failed; the argument is an HTTP status code")
        case .invalidResponse:
            String(localized: "GitHub’s answer wasn’t a Vauta release, so it was ignored.", comment: "Settings → General → Updates: why the check failed")
        }
    }

    @ViewBuilder private var launchNote: some View {
        switch model.launch {
        case .none:
            EmptyView()
        case .started:
            NoticeLabel(Text("The update is running in Terminal.", comment: "Settings → General → Updates, after Update…"), status: .ok)
        case .recording:
            NoticeLabel(Text("Stop the recording before updating: the update quits Vauta at the end.", comment: "Settings → General → Updates, after Update… during a recording"),
                        status: .warning)
        case .copiedCommand:
            NoticeLabel(Text("This install can’t open the update by itself yet. The command \(UpdateModel.manualCommand) is copied: paste it in Terminal, in the folder you built Vauta from. The next install adds what Update… needs.",
                             comment: "Settings → General → Updates, after Update… in an install from before the launcher; the argument is the command ./scripts/update.sh"),
                        status: .info)
        case .invalidLauncher:
            NoticeLabel(Text("The update files in ~/Library/Application Scripts aren’t the ones scripts/install.sh writes for this app, so Vauta didn’t run them. Run ./scripts/install.sh again, or ./scripts/update.sh in Terminal.",
                             comment: "Settings → General → Updates, after Update… when the launcher failed its checks; the paths and commands stay as they are"),
                        status: .warning)
        case .failed:
            NoticeLabel(Text("Terminal couldn’t be opened. Run ./scripts/update.sh in Terminal, in the folder you built Vauta from.",
                             comment: "Settings → General → Updates, after Update… failed; the command stays as it is"),
                        status: .warning)
        }
    }
}
