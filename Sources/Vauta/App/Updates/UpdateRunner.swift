// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// The only code in Vauta that runs something outside the App Sandbox: `update-vauta` in the app's Application Scripts folder, which
/// `scripts/install.sh` wrote and the app can't change (`UpdateLauncher`). It is run only after `UpdateLauncher.inspect` accepted both
/// files, with no arguments and no input, and it only opens the update in Terminal, where `scripts/update.sh` verifies the release
/// before anything is built or installed. `NetworkAuditSourceScanTests` allows `NSUserUnixTask` in this file and nowhere else.
enum UpdateRunner {
    /// `~/Library/Application Scripts/<bundle-id>/`; nil outside the sandbox (a development build), where nothing is run.
    static var scriptsDirectory: URL? {
        try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    }

    /// The launcher, checked: nil with the reason when it is missing or not exactly what `install.sh` writes for this app.
    static func prepare() -> Result<UpdateLauncher.Ready, UpdateLauncher.Problem> {
        guard let directory = scriptsDirectory, let bundleID = Bundle.main.bundleIdentifier else { return .failure(.missing) }
        return UpdateLauncher.inspect(directory: directory, bundleID: bundleID)
    }

    /// Runs the launcher that `prepare` accepted, checking it again right before (it could have changed in between).
    static func run(_ ready: UpdateLauncher.Ready) async throws {
        guard case .success(let again) = prepare(), again == ready else { throw UpdateLauncher.Problem.invalid }
        let task = try NSUserUnixTask(url: again.launcher)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.execute(withArguments: []) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
