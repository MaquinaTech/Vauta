// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Uses the real Keychain under a unique throwaway service, never Vauta's own.
/// Skipped when no keychain is usable (see `KeychainProbe`).
@Suite("Models: server key and config in the Keychain", .serialized, .enabled(if: KeychainProbe.isUsable))
struct ModelsCredentialsTests {
    let service = "vauta.tests.credentials.\(UUID().uuidString)"

    private func cleanUp() {
        ServerCredentials.delete(ServerCredentials.bearerAccount, service: service)
        ServerCredentials.delete(ServerCredentials.legacyBearerAccount, service: service)
    }

    @Test func legacyKeyIsMigrated() throws {
        defer { cleanUp() }
        try ServerCredentials.write("sk-legacy", account: "mlx-bearer-v1", service: service)
        #expect(try ServerCredentials.readBearer(service: service) == "sk-legacy")
        #expect(try ServerCredentials.read("llm-bearer-v1", service: service) == "sk-legacy")
        #expect(try ServerCredentials.read("mlx-bearer-v1", service: service) == nil)
        #expect(try ServerCredentials.readBearer(service: service) == "sk-legacy")
    }

    @Test func newKeyWinsOverALeftoverLegacyKey() throws {
        defer { cleanUp() }
        try ServerCredentials.write("sk-old", account: ServerCredentials.legacyBearerAccount, service: service)
        try ServerCredentials.write("sk-new", account: ServerCredentials.bearerAccount, service: service)
        #expect(try ServerCredentials.readBearer(service: service) == "sk-new")
    }

    @Test func savingAndDeletingCoverBothAccounts() throws {
        defer { cleanUp() }
        #expect(try ServerCredentials.readBearer(service: service) == nil)
        try ServerCredentials.write("sk-old", account: ServerCredentials.legacyBearerAccount, service: service)
        try ServerCredentials.saveBearer("  sk-1  ", service: service)
        #expect(try ServerCredentials.read(ServerCredentials.legacyBearerAccount, service: service) == nil)
        #expect(try ServerCredentials.readBearer(service: service) == "sk-1")
        try ServerCredentials.saveBearer("sk-2", service: service)   // update in place
        #expect(try ServerCredentials.readBearer(service: service) == "sk-2")
        try ServerCredentials.write("sk-old", account: ServerCredentials.legacyBearerAccount, service: service)
        try ServerCredentials.saveBearer(nil, service: service)
        #expect(try ServerCredentials.readBearer(service: service) == nil, "a deleted key must not come back through the migration")
        #expect(throws: LLMError.invalidStoredToken) { try ServerCredentials.saveBearer("bad key", service: service) }
    }

    @Test func configLoadTellsNotConfiguredApart() throws {
        defer { KeychainSecret.delete(LLMServerConfig.account, service: service) }
        #expect(try LLMServerConfig.load(service: service) == nil, "no item = not configured, without throwing")
        let config = ModelsFixtures.config(.local, "http://127.0.0.1:1234/v1")
        try LLMServerConfig.save(config, service: service)
        #expect(try LLMServerConfig.load(service: service) == config)
        try LLMServerConfig.save(nil, service: service)
        #expect(try LLMServerConfig.load(service: service) == nil)
        try KeychainSecret.write("{not json", account: LLMServerConfig.account, label: "Vauta test", service: service)
        #expect(try LLMServerConfig.load(service: service) == nil, "an unreadable config counts as not configured")
    }

    @Test func accountNames() {
        #expect(ServerCredentials.bearerAccount == "llm-bearer-v1" && ServerCredentials.legacyBearerAccount == "mlx-bearer-v1")
        #expect(LLMClient.bearerAccount == ServerCredentials.bearerAccount)
    }
}
