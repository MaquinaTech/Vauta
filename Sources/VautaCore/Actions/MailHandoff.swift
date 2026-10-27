// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Someone the email could go to: an attendee of the meeting with an address already stored. No address is guessed and no address book
/// is read.
public struct EmailRecipient: Sendable, Equatable, Identifiable {
    public var id: Int64 { entityID }
    public let entityID: Int64
    public let name: String
    public let email: String
    /// The address's domain differs from the person's own: marked "External" (text plus symbol) in the sheet.
    public let isExternal: Bool

    public init(entityID: Int64, name: String, email: String, isExternal: Bool) {
        self.entityID = entityID
        self.name = name
        self.email = email
        self.isExternal = isExternal
    }
}

public struct EmailRecipients: Sendable, Equatable {
    public let recipients: [EmailRecipient]
    /// False when the person has no address of their own stored: nobody can be marked External, and the sheet says so.
    public let selfDomainKnown: Bool

    public init(recipients: [EmailRecipient], selfDomainKnown: Bool) {
        self.recipients = recipients
        self.selfDomainKnown = selfDomainKnown
    }
}

public enum FollowUpRecipients {
    /// Attendees with a stored address, without the person themselves. Nobody is ticked: ticking is the sheet's, one explicit click per
    /// address (in per-owner mode, only the owner's own address is offered in each draft).
    public static func candidates(attendees: [Entity], selfEntity: Entity?) -> EmailRecipients {
        let selfDomain = selfEntity?.email.flatMap { domain(of: $0) }
        var seen = Set<String>()
        let recipients = attendees.compactMap { person -> EmailRecipient? in
            guard !person.isSelf, person.id != selfEntity?.id, person.kind == .person, let email = person.email?.trimmingCharacters(in: .whitespaces),
                  isPlausible(email), seen.insert(email.lowercased()).inserted else { return nil }
            return EmailRecipient(entityID: person.id, name: person.displayName, email: email, isExternal: selfDomain.map { domain(of: email) != $0 } ?? false)
        }
        return EmailRecipients(recipients: recipients, selfDomainKnown: selfDomain != nil)
    }

    static func domain(of email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...].lowercased()
        return domain.isEmpty ? nil : String(domain)
    }

    static func isPlausible(_ email: String) -> Bool {
        guard !email.contains(where: { $0.isWhitespace || $0 == "," || $0 == ";" || $0 == "<" || $0 == ">" }) else { return false }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
    }
}

/// How the draft reaches the person's mail app. Vauta never sends anything.
public enum MailHandoff {
    /// A `mailto:` URL longer than this is not used: mail apps truncate long ones. The draft is copied and Mail opened instead.
    public static let maximumURLLength = 2_000

    public enum Plan: Equatable, Sendable {
        /// `NSSharingService(named: .composeEmail)` is tried first by the app; this is its fallback.
        case mailto(URL)
        /// "Copy and Open Mail": the draft is too long for a URL.
        case copyAndOpen
    }

    public static func plan(to recipients: [String], subject: String, body: String) -> Plan {
        mailtoURL(to: recipients, subject: subject, body: body).map(Plan.mailto) ?? .copyAndOpen
    }

    /// `mailto:a@b.c,d@e.f?subject=…&body=…` with RFC 6068 percent-encoding and CRLF line breaks; nil when it would be longer than the limit.
    public static func mailtoURL(to recipients: [String], subject: String, body: String) -> URL? {
        let to = recipients.map { encode($0, keeping: "@.-_+") }.joined(separator: ",")
        let crlf = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        let string = "mailto:\(to)?subject=\(encode(subject))&body=\(encode(crlf))"
        guard string.count <= maximumURLLength else { return nil }
        return URL(string: string)
    }

    static func encode(_ text: String, keeping extra: String = "") -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        allowed.insert(charactersIn: extra)
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

/// The marks that keep a copied draft out of clipboard managers (the nspasteboard.org conventions). The app's `ProtectedPasteboard`
/// writes them, and asks macOS to keep the item on this Mac (`.currentHostOnly`); Copy Minutes uses the same helper.
public enum PasteboardMarks {
    public static let concealed = "org.nspasteboard.ConcealedType"
    public static let transient = "org.nspasteboard.TransientType"
    public static let all = [concealed, transient]
}

/// What copy protection (Settings › Privacy & Security) allows around actions.
public enum ActionCopyPolicy {
    /// The email draft leaves Vauta as text (mail app, Share, Copy), so copy protection blocks it like Export; the preview stays readable.
    public static func emailAllowed(copyProtection: Bool) -> Bool { !copyProtection }

    /// A reminder or a calendar event is an explicit, per-item action, so it stays allowed, with a one-line warning in the editor:
    /// "Copy protection is on. This text will leave Vauta for Reminders."
    public static func writeAllowed(copyProtection: Bool) -> Bool { true }
    public static func writeWarns(copyProtection: Bool) -> Bool { copyProtection }
}
