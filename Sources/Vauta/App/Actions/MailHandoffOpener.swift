// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import Foundation
import os
import VautaCore

/// Hands a follow-up email draft to the person's mail app. Vauta never sends anything and never connects to a mail server: the mail app
/// does. The draft is never logged, not even as `.private`: a log line says which route was taken, with counts only (recipients, bytes).
enum MailHandoffOpener {
    private static let log = Logger(subsystem: "local.vauta", category: "mail-handoff")

    enum Route: String { case composer, mailto, copyAndOpen, unavailable }

    /// Composer first (`NSSharingService(named: .composeEmail)`), then a `mailto:` URL when it is short enough, else the draft is copied
    /// (marked, local) and Mail is opened with nothing in it: "Copy and Open Mail".
    @MainActor
    @discardableResult
    static func open(subject: String, body: String, recipients: [String]) -> Route {
        if let service = NSSharingService(named: .composeEmail) {
            service.recipients = recipients
            service.subject = subject
            if service.canPerform(withItems: [body]) {
                service.perform(withItems: [body])
                log.info("mail composer opened, \(recipients.count, privacy: .public) recipients")
                return .composer
            }
        }
        switch MailHandoff.plan(to: recipients, subject: subject, body: body) {
        case .mailto(let url):
            NSWorkspace.shared.open(url)
            // The URL holds the addresses, the subject and the body: only its length is logged.
            let bytes = url.absoluteString.utf8.count
            log.info("mailto opened, \(recipients.count, privacy: .public) recipients, \(bytes, privacy: .public) bytes")
            return .mailto
        case .copyAndOpen:
            ProtectedPasteboard.copy(body)
            guard let mail = URL(string: "mailto:") else { return .unavailable }
            NSWorkspace.shared.open(mail)
            log.info("draft copied, mail opened")
            return .copyAndOpen
        }
    }
}
