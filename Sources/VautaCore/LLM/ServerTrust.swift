// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Security

/// TLS trust for the model server: host name (IP or DNS in the SAN), the
/// private CA bundle as the only anchors (system anchors when there is none),
/// and the SPKI pins when configured. Evaluation never fetches anything from
/// the network: no missing intermediates (AIA) and no OCSP or CRL requests to a
/// certificate authority, with or without a private CA. A publicly trusted
/// server must therefore send its full chain (leaf and intermediates), which
/// `tailscale cert`, Caddy and Let's Encrypt's `fullchain.pem` do.
enum ServerTrust {
    /// Evaluates a server-trust challenge against the configured endpoints.
    static func evaluate(_ challenge: URLAuthenticationChallenge, _ targets: [LLMServerConfig.Endpoint])
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        let host = space.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let target = targets.first(where: { $0.secure && $0.host == host && $0.port == space.port }),
              let trust = space.serverTrust, evaluate(trust, target) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// `date` is only for tests (fixture certificates have fixed validity).
    static func evaluate(_ trust: SecTrust, _ target: LLMServerConfig.Endpoint, at date: Date? = nil) -> Bool {
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, target.host as CFString))
        if let date { SecTrustSetVerifyDate(trust, date as CFDate) }
        // Revocation stays best-effort (the SSL policy does not require it), so this only stops the fetches.
        SecTrustSetNetworkFetchAllowed(trust, false)
        if !target.caDERs.isEmpty {
            let anchors = target.caDERs.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            guard anchors.count == target.caDERs.count else { return false }
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first
        else { return false }
        return target.pins.isEmpty || target.pins.contains(spkiPin(leaf) ?? "")
    }

    /// SHA-256 (base64) of the SubjectPublicKeyInfo, the same as
    /// `openssl x509 -pubkey | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`.
    /// EC P-256/P-384/P-521 and RSA keys.
    static func spkiPin(_ cert: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(cert),
              let attrs = SecKeyCopyAttributes(key) as? [CFString: Any],
              let type = attrs[kSecAttrKeyType] as? String,
              let raw = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { return nil }
        let algorithm: Data
        if type == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            let curve: [UInt8]
            switch attrs[kSecAttrKeySizeInBits] as? Int {
            case 256: curve = [0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]
            case 384: curve = [0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22]
            case 521: curve = [0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x23]
            default: return nil
            }
            algorithm = der(0x30, Data([0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01] + curve))
        } else if type == (kSecAttrKeyTypeRSA as String) {
            algorithm = der(0x30, Data([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]))
        } else {
            return nil
        }
        let spki = der(0x30, algorithm + der(0x03, Data([0x00]) + raw))
        return Data(SHA256.hash(data: spki)).base64EncodedString()
    }

    /// DER TLV with short or long length form.
    private static func der(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let n = content.count
        if n < 0x80 {
            out.append(UInt8(n))
        } else {
            var bytes: [UInt8] = []
            var v = n
            while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        return out + content
    }
}

extension LLMClient {
    /// SPKI pin of a certificate.
    public static func spkiPin(_ cert: SecCertificate) -> String? { ServerTrust.spkiPin(cert) }

    /// SPKI pin of a PEM certificate (for Settings and the CLI).
    public static func spkiPin(pem: String) -> String? {
        guard let der = LLMServerConfig.der(fromPEM: pem), let cert = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        return ServerTrust.spkiPin(cert)
    }

    /// Offline diagnosis: validates a PEM server certificate (leaf first, then
    /// any intermediates) with the same logic as a real connection.
    public static func verifyServerCertificate(pem: String, config: LLMServerConfig, at date: Date? = nil) throws -> (pin: String?, trusted: Bool) {
        let target = try config.validated()
        let certs = LLMServerConfig.ders(fromPEM: pem).compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard let leaf = certs.first else { return (nil, false) }
        var trust: SecTrust?
        SecTrustCreateWithCertificates(certs as CFArray, SecPolicyCreateSSL(true, target.host as CFString), &trust)
        return (ServerTrust.spkiPin(leaf), trust.map { ServerTrust.evaluate($0, target, at: date) } ?? false)
    }
}
