// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A release number, `major.minor.patch`, as Vauta's release tags (`v0.10.0`) and `CFBundleShortVersionString` (`0.10.0`) write it.
/// Parsing is strict: three decimal numbers of at most four digits each, nothing before or after (no pre-release or build suffix,
/// no sign, no spaces), so a tag that is not a release, or a value built to overflow or to confuse a comparison, is refused.
public struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// `0.10.0`; nil for anything else.
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // ASCII digits only: `Int("٣")` and `"+1"` are not version numbers.
            guard (1...4).contains(part.utf8.count), part.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                  let n = Int(part) else { return nil }
            numbers.append(n)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    /// A release tag, `v0.10.0`; nil for anything else (`0.10.0`, `v0.10.0-rc1`, `V0.10.0`).
    public init?(tag: String) {
        guard tag.hasPrefix("v") else { return nil }
        self.init(String(tag.dropFirst()))
    }

    public var description: String { "\(major).\(minor).\(patch)" }
    /// The release tag, `v0.10.0`.
    public var tag: String { "v\(description)" }

    public static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    /// The version of the running app, from its `Info.plist`; nil for a build without one (`swift run`).
    public static var running: ReleaseVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap { ReleaseVersion($0) }
    }
}
