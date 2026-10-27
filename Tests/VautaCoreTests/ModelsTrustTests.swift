// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Models: TLS trust")
struct ModelsTrustTests {
    typealias F = ModelsFixtures
    /// Inside the validity of the fixture certificates.
    let when = Date(timeIntervalSince1970: 1_800_000_000)

    private func trusted(_ url: String, ca: String?, pins: [String] = [], cert: String = F.testServer) -> Bool {
        (try? LLMClient.verifyServerCertificate(pem: cert, config: F.config(.remote, url, ca: ca, pins: pins), at: when).trusted) ?? false
    }

    @Test func spkiPinsMatchOpenSSL() {
        #expect(LLMClient.spkiPin(pem: F.testCA) == F.caPin)
        #expect(LLMClient.spkiPin(pem: F.testServer) == F.serverPin)
        #expect(LLMClient.spkiPin(pem: F.testRSA) == F.rsaPin)
        #expect(LLMClient.spkiPin(pem: "not a certificate") == nil)
    }

    @Test func certificateFromTheConfiguredCAIsAccepted() {
        #expect(trusted("https://10.0.0.7:8443/v1", ca: F.testCA, pins: [F.serverPin]))
        #expect(trusted("https://vauta-test.local/v1", ca: F.testCA))
    }

    @Test func caBundleAnchorsEveryCertificate() {
        // The issuing CA is the second certificate of the bundle.
        #expect(trusted("https://10.0.0.7:8443/v1", ca: F.testRSA + "\n" + F.testCA))
        #expect(!trusted("https://10.0.0.7:8443/v1", ca: F.testRSA))
    }

    @Test func mismatchesAreRejected() {
        #expect(!trusted("https://10.0.0.8:8443/v1", ca: F.testCA), "IP outside the SAN")
        #expect(!trusted("https://10.0.0.7:8443/v1", ca: F.testCA, pins: [F.rsaPin]), "pin of another key")
        #expect(!trusted("https://10.0.0.7:8443/v1", ca: nil), "system anchors do not know the private CA")
        #expect(!trusted("https://10.0.0.7:8443/v1", ca: F.testCA, cert: F.testCA), "a CA certificate is not a server certificate")
    }

    @Test func pinOnlyWithoutCAStillNeedsAValidChain() {
        #expect(!trusted("https://10.0.0.7:8443/v1", ca: nil, pins: [F.serverPin]))
    }
}
