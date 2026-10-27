// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import Foundation

// Everything the process creates is 0600/0700 (no window with open permissions).
umask(0o077)

// Leftovers of old builds that dumped diagnostic audio: audio must never stay
// on disk. Only those names, never other WAV files.
for name in ["Yo.wav", "Otros.wav"] {
    try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent(name))
}

// A command as the first argument runs it; anything else (no arguments,
// Launch Services' -psn_…, -AppleLanguages (en), -NSShowAllViews YES…)
// launches the menu-bar app.
switch LaunchMode.parse(Array(CommandLine.arguments.dropFirst())) {
case .app:
    // No window restoration (saved state lives outside the encrypted store).
    UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    VautaApp.main()
case .cli(let arguments):
    Task {
        exit(await runCLI(arguments))
    }
    #if VAUTA_DIAGNOSTICS
    if arguments.first == "render-ui" || arguments.first == "translate-bench" {
        // Rendering views needs AppKit's run loop (it never shows a window or a Dock icon).
        // render-ui uses an application that reports being active, so controls draw as in the frontmost app.
        let application = arguments.first == "render-ui" ? ActiveApplication.shared : NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.run()
    }
    #endif
    dispatchMain()
}
