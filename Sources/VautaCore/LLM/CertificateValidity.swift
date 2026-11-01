// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Security

/// When the model server's TLS certificates stop being valid: the earliest end among the certificates of its chain (the
/// server's own, any intermediate and the private authority), as the last connection presented them. Status warns ahead, and
/// a connection refused for an expired certificate says so instead of a general TLS failure.
public struct CertificateValidity: Sendable, Equatable {
    public let notAfter: Date

    public enum State: Sendable, Equatable { case valid, expiresSoon, expired }

    /// How long before the end Status starts warning: time to renew it without hurry.
    public static let warningDays = 30

    public init(notAfter: Date) { self.notAfter = notAfter }

    public func state(at now: Date = .now) -> State {
        if now >= notAfter { return .expired }
        return notAfter.timeIntervalSince(now) <= Double(Self.warningDays) * 86_400 ? .expiresSoon : .valid
    }

    /// The earliest end among `certificates`; nil when there are none.
    static func earliest(_ certificates: [SecCertificate]) -> CertificateValidity? {
        certificates.compactMap { SecCertificateCopyNotValidAfterDate($0) as Date? }.min().map(CertificateValidity.init)
    }
}
