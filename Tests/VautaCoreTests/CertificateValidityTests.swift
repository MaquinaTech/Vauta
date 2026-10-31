// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Security
import Testing
@testable import VautaCore

/// How long the model server's certificates stay valid: Status warns 30 days ahead, and a refusal for an expired one says so.
@Suite("Models: certificate validity")
struct CertificateValidityTests {
    typealias F = ModelsFixtures
    /// The fixture server certificate ends on 4 January 2029 at 07:39:45 UTC; its authority in 2036.
    private let serverEnd = Date(timeIntervalSince1970: 1_862_206_785)

    @Test func theStateFollowsTheEnd() {
        let validity = CertificateValidity(notAfter: serverEnd)
        #expect(validity.state(at: serverEnd - 31 * 86_400) == .valid)
        #expect(validity.state(at: serverEnd - 30 * 86_400) == .expiresSoon)
        #expect(validity.state(at: serverEnd - 1) == .expiresSoon)
        #expect(validity.state(at: serverEnd) == .expired)
        #expect(validity.state(at: serverEnd + 86_400) == .expired)
    }

    /// The trust of the fixture chain (server and its authority) for 10.0.0.7, evaluated at `date`, as a connection would.
    private func evaluatedTrust(at date: Date) throws -> (trust: SecTrust, trusted: Bool) {
        let config = F.config(.remote, "https://10.0.0.7:8443/v1", ca: F.testCA, pins: [F.serverPin])
        let target = try config.validated()
        let certs = LLMServerConfig.ders(fromPEM: F.testServer).compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        var trust: SecTrust?
        SecTrustCreateWithCertificates(certs as CFArray, SecPolicyCreateSSL(true, "10.0.0.7" as CFString), &trust)
        let built = try #require(trust)
        return (built, ServerTrust.evaluate(built, target, at: date))
    }

    @Test func theChainEndsWithItsEarliestCertificate() throws {
        let (trust, trusted) = try evaluatedTrust(at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(trusted)
        let validity = try #require(ServerTrust.validity(of: trust))
        // The server's own certificate ends before its authority's.
        #expect(abs(validity.notAfter.timeIntervalSince(serverEnd)) < 1)
    }

    @Test func anExpiredChainIsRefusedAndStillSaysWhenItEnded() throws {
        let (trust, trusted) = try evaluatedTrust(at: serverEnd + 86_400)
        #expect(!trusted)
        let validity = try #require(ServerTrust.validity(of: trust))
        #expect(validity.state(at: serverEnd + 86_400) == .expired)
        let message = LLMService.expiredCertificateMessage(validity)
        #expect(message.contains("2029") && message.contains("make-server-cert.sh"))
    }
}
