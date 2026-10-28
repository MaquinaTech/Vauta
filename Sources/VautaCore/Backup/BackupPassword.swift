// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Rules and feedback for the password that protects a backup. The file can be
/// copied anywhere, so an attacker can try passwords offline: the password is
/// the only thing that protects it.
public enum BackupPassword {
    public static let minimumLength = 12

    public enum Strength: Int, Sendable, Comparable {
        case tooShort, weak, good, strong
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// Length counts characters, not bytes. Passphrases of several words are
    /// encouraged; repeated characters and short passwords are not enough.
    public static func strength(of password: String) -> Strength {
        let chars = Array(password)
        guard chars.count >= minimumLength else { return .tooShort }
        let distinct = Set(chars).count
        guard distinct >= minimumDistinctCharacters else { return .weak }
        let classes = [chars.contains { $0.isLowercase }, chars.contains { $0.isUppercase },
                       chars.contains { $0.isNumber }, chars.contains { !$0.isLetter && !$0.isNumber }].filter { $0 }.count
        let words = password.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).count
        if chars.count >= 20 || (chars.count >= 16 && (classes >= 2 || words >= 3)) { return .strong }
        if chars.count >= 16 || classes >= 3 || words >= 3 { return .good }
        return .weak
    }

    /// Fewer distinct characters than this is trivially repetitive (`111111111111`), however long.
    public static let minimumDistinctCharacters = 6

    /// A password is accepted when it reaches the minimum length and is not trivially repetitive.
    public static func isAcceptable(_ password: String) -> Bool {
        strength(of: password) >= .weak && Set(password).count >= minimumDistinctCharacters
    }
}
