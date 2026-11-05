// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The two files `scripts/install.sh` writes to `~/Library/Application Scripts/<bundle-id>/` so that Update… can start an update
/// from inside the App Sandbox, and the checks Vauta makes before it runs them.
///
/// macOS lets a sandboxed app run the scripts in that folder (`NSUserUnixTask`) and read them, but not create or change them: only
/// the person (here, `install.sh` in their Terminal) can. `update-vauta` is fixed text that opens `Update Vauta.command` in
/// Terminal; that file names the checkout to update and how it was built, and runs `scripts/update.sh`, which verifies the release
/// tag's signature against the maintainer's key, shows the release notes and asks before it builds, tests and installs anything.
/// Vauta passes no arguments and no environment: it can only start that one update, never choose what runs.
///
/// Before running anything Vauta checks both files strictly (`inspect`): regular files (not links), owned by this user, writable by
/// no one else, small, and byte for byte in the form `install.sh` writes, with this app's bundle ID. Anything else is not run.
///
/// What this guards against: a broken or half-written install, files left by another app or another copy of Vauta, and a
/// compromised Vauta (which can't write the folder and passes no input, so it can't choose what runs). It does not guard against
/// software already running as the person: that could write a valid command for another folder, or change the checkout's own
/// `scripts/update.sh`, which is outside the sandbox and outside what Vauta can check.
public enum UpdateLauncher {
    /// The file Vauta runs.
    public static let launcherName = "update-vauta"
    /// The file the launcher opens in Terminal.
    public static let commandName = "Update Vauta.command"
    /// Larger files are refused (the real ones are well under 1 KB).
    static let maxFileBytes = 4096

    /// The launcher, byte for byte. `scripts/install-update-launcher.sh` writes the same text (a test compares them).
    public static let launcherText = """
        #!/bin/sh
        # vauta-update-launcher 1
        # Written by Vauta's scripts/install.sh (again at each install). Vauta runs it, with no arguments, when you click Update…;
        # macOS lets Vauta run the scripts in this folder but not change them. It opens Update Vauta.command in Terminal, where
        # scripts/update.sh verifies the release's signature before anything is built or installed.
        exec /usr/bin/open -a /System/Applications/Utilities/Terminal.app "${0%/*}/Update Vauta.command"

        """

    static let commandHead = [
        "#!/bin/bash",
        "# vauta-update-command 1",
        "# Written by Vauta's scripts/install.sh (again at each install): the Vauta checkout to update and how it was built.",
    ]
    static let commandTail = [
        "./scripts/update.sh",
        "echo",
        "read -r -p \"Press Return to close this window. \" _",
    ]
    /// The variables the command may set, as `install.sh` had them; `VAUTA_BUNDLE_ID` is required.
    static let allowedVariables: Set<String> = ["VAUTA_BUNDLE_ID", "VAUTA_ALLOW_ADHOC", "VAUTA_SIGN_IDENTITY", "VAUTA_SIGN_KEYCHAIN"]

    /// Why Update… can't start the update.
    public enum Problem: Error, Equatable, Sendable {
        /// The files are not there: this install predates them, or was not made with `install.sh`.
        case missing
        /// They are there but not exactly as `install.sh` writes them, or they update another app: nothing is run.
        case invalid
    }

    /// The checkout the command updates, once both files passed every check.
    public struct Ready: Equatable, Sendable {
        public let launcher: URL
        /// The Vauta checkout `update.sh` runs in.
        public let checkout: String
    }

    /// Checks the two files in `directory` (the app's Application Scripts folder) for the app with `bundleID`. Every comparison is
    /// on bytes, never on Swift text (which treats a quote followed by a combining mark as one character, and compares canonically):
    /// what bash reads is exactly what was checked.
    public static func inspect(directory: URL, bundleID: String, userID: UInt32 = getuid()) -> Result<Ready, Problem> {
        let fm = FileManager.default
        let launcher = directory.appending(path: launcherName, directoryHint: .notDirectory)
        let command = directory.appending(path: commandName, directoryHint: .notDirectory)
        guard fm.fileExists(atPath: launcher.path) || fm.fileExists(atPath: command.path) else { return .failure(.missing) }
        guard safeItem(directory.path, directory: true, userID: userID),
              safeItem(launcher.path, directory: false, userID: userID), safeItem(command.path, directory: false, userID: userID),
              let launcherData = fm.contents(atPath: launcher.path), launcherData == Data(launcherText.utf8),
              let commandData = fm.contents(atPath: command.path), commandData.count <= maxFileBytes,
              let checkout = checkout(ofCommand: commandData, bundleID: bundleID) else { return .failure(.invalid) }
        return .success(Ready(launcher: launcher, checkout: checkout))
    }

    /// A regular file (or folder) that is not a link, owned by `userID` and writable by no one else; a file must be executable by its owner.
    static func safeItem(_ path: String, directory: Bool, userID: UInt32) -> Bool {
        // `attributesOfItem` does not follow a final symbolic link: a link is reported as one, and refused.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType,
              let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
              let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value else { return false }
        guard type == (directory ? .typeDirectory : .typeRegular), owner == userID, mode & 0o022 == 0 else { return false }
        return directory || mode & 0o100 != 0
    }

    /// The command `install-update-launcher.sh` writes, byte for byte: the checkout, then the variables in the script's order.
    public static func commandData(checkout: String, variables: [String: String]) -> Data {
        var lines = commandHead
        lines.append("cd '\(checkout)' || exit 1")
        for name in variableOrder { if let value = variables[name] { lines.append("export \(name)='\(value)'") } }
        lines += commandTail
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// The order the script writes the variables in.
    static let variableOrder = ["VAUTA_BUNDLE_ID", "VAUTA_ALLOW_ADHOC", "VAUTA_SIGN_IDENTITY", "VAUTA_SIGN_KEYCHAIN"]

    /// The checkout named by a command in exactly the form `install.sh` writes, for `bundleID`; nil for anything else. The values are
    /// read as bytes, each must be `safe`, and the file must then equal, byte for byte, the command rebuilt from them.
    static func checkout(ofCommand data: Data, bundleID: String) -> String? {
        let bytes = [UInt8](data)
        guard bytes.last == 0x0A else { return nil }
        let lines = bytes.dropLast().split(separator: 0x0A, omittingEmptySubsequences: false).map(Array.init)
        let middle = lines.count - commandHead.count - commandTail.count
        guard middle >= 2 else { return nil }
        // cd '<absolute path>' || exit 1
        let cd = lines[commandHead.count]
        let cdHead = Array("cd '".utf8), cdTail = Array("' || exit 1".utf8)
        guard cd.count > cdHead.count + cdTail.count, cd.starts(with: cdHead), cd.suffix(cdTail.count).elementsEqual(cdTail),
              let checkout = value(cd[cdHead.count..<(cd.count - cdTail.count)]), checkout.hasPrefix("/"), checkout.utf8.count > 1 else { return nil }
        // export NAME='value', each allowed name at most once.
        var variables: [String: String] = [:]
        for line in lines[(commandHead.count + 1)..<(commandHead.count + middle)] {
            let prefix = Array("export ".utf8)
            guard line.starts(with: prefix), let equals = line.firstIndex(of: UInt8(ascii: "=")), equals > prefix.count,
                  let name = String(bytes: line[prefix.count..<equals], encoding: .utf8), allowedVariables.contains(name), variables[name] == nil,
                  line.count >= equals + 3, line[equals + 1] == 0x27, line.last == 0x27,
                  let v = value(line[(equals + 2)..<(line.count - 1)]) else { return nil }
            variables[name] = v
        }
        guard variables["VAUTA_BUNDLE_ID"] == bundleID, variables["VAUTA_ALLOW_ADHOC"].map({ $0 == "1" }) ?? true,
              commandData(checkout: checkout, variables: variables) == data else { return nil }
        return checkout
    }

    /// A value inside single quotes: valid UTF-8 with no quote (0x27) and no control byte (below 0x20, or 0x7F). The script refuses
    /// to write anything else, with the same byte rule (`LC_ALL=C`).
    static func value(_ bytes: ArraySlice<UInt8>) -> String? {
        guard bytes.allSatisfy(safe) else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    static func safe(_ byte: UInt8) -> Bool { byte >= 0x20 && byte != 0x7F && byte != 0x27 }
}
