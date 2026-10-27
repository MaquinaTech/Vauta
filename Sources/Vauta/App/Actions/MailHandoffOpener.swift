// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import Foundation
import os
import VautaCore

/// Hands a follow-up email draft to the person's mail app. Vauta never sends anything and never connects to a mail server: the mail app
/// does. The draft is never logged; the only log line says which route was taken, and anything about the draft is `.private`.
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
            log.info("mailto opened: \(url.absoluteString, privacy: .private)")
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
