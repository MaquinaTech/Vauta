// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
@testable import VautaCore

/// A fake model server behind `URLProtocol`: no socket is opened and nothing
/// leaves the process. Each test registers a handler on its own port, so
/// tests can run in parallel.
final class StubServer: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body = Data()

        static func json(_ object: Any, status: Int = 200) -> Reply {
            Reply(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }
        static func text(_ s: String, status: Int = 200, contentType: String = "text/event-stream") -> Reply {
            Reply(status: status, headers: ["Content-Type": contentType], body: Data(s.utf8))
        }
    }

    struct Received: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?

        var json: [String: Any]? { body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    }

    typealias Handler = @Sendable (Received) -> Reply?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [Int: Handler] = [:]
    nonisolated(unsafe) private static var log: [Int: [Received]] = [:]
    nonisolated(unsafe) private static var nextPort = 40_000

    /// A fresh port with `handler`; nil replies become 404.
    static func register(_ handler: @escaping Handler) -> Int {
        lock.withLock {
            nextPort += 1
            handlers[nextPort] = handler
            return nextPort
        }
    }

    static func register(port: Int, _ handler: @escaping Handler) {
        lock.withLock { handlers[port] = handler }
    }

    static func requests(_ port: Int) -> [Received] { lock.withLock { log[port] ?? [] } }

    static func unregister(_ port: Int) {
        lock.withLock {
            handlers[port] = nil
            log[port] = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let received = Received(method: request.httpMethod ?? "GET", url: url,
                                headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody ?? Self.read(request.httpBodyStream))
        let handler = Self.lock.withLock {
            Self.log[port, default: []].append(received)
            return Self.handlers[port]
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let reply = handler(received) ?? Reply.json(["error": "not found"], status: 404)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        // A redirect is offered to the session as a server's would be: its delegate decides whether the new request is made.
        if (300..<400).contains(reply.status), let location = reply.headers["Location"].flatMap({ URL(string: $0, relativeTo: url) }) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: location.absoluteURL), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

enum ModelsFixtures {
    static func config(_ mode: LLMServerConfig.Mode = .local, _ url: String, ca: String? = nil, pins: [String] = [],
                       profile: ServerProfile? = nil, embedding: EmbeddingSettings? = nil,
                       embeddingModel: String = "emb") -> LLMServerConfig {
        LLMServerConfig(mode: mode, baseURL: url, caPEM: ca, pins: pins, fastModel: "fast-model", deepModel: "deep-model",
                        embeddingModel: embeddingModel, profile: profile, embedding: embedding)
    }

    static func client(port: Int, profile: ServerProfile? = nil, embedding: EmbeddingSettings? = nil, embeddingModel: String = "emb",
                       log: NetworkActivityLog = .shared,
                       bearer: @escaping @Sendable () throws -> String? = { nil }) -> LLMClient {
        LLMClient(config: config(.local, "http://127.0.0.1:\(port)/v1", profile: profile, embedding: embedding, embeddingModel: embeddingModel),
                  bearer: bearer, protocolClasses: [StubServer.self], log: log)
    }

    static func sse(_ chunks: [Any], done: Bool = true) -> String {
        chunks.map { chunk -> String in
            let data = (try? JSONSerialization.data(withJSONObject: chunk)) ?? Data()
            return "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
        }.joined() + (done ? "data: [DONE]\n\n" : "")
    }

    static func delta(_ content: String, finish: String? = nil) -> [String: Any] {
        var choice: [String: Any] = ["index": 0, "delta": ["content": content]]
        if let finish { choice["finish_reason"] = finish }
        return ["choices": [choice]]
    }

    static var usage: [String: Any] { ["choices": [], "usage": ["prompt_tokens": 120, "completion_tokens": 7,
                                                                "prompt_tokens_details": ["cached_tokens": 100]]] }

    // Disposable test material (private keys destroyed): an EC P-256 CA (scripts/make-server-cert.sh), a
    // server certificate it issued (SAN IP:10.0.0.7 and DNS:vauta-test.local,
    // valid Oct 2026–Jan 2029) and a self-signed RSA certificate.
    static let testCA = """
        -----BEGIN CERTIFICATE-----
        MIIBhzCCAS2gAwIBAgIUU5Hv5K/DeUn0zBkDQRe7G0efJ18wCgYIKoZIzj0EAwIw
        IDEeMBwGA1UEAwwVVmF1dGEgTW9kZWwgU2VydmVyIENBMB4XDTI2MTAyNzA3Mzk0
        NVoXDTM2MTAyNDA3Mzk0NVowIDEeMBwGA1UEAwwVVmF1dGEgTW9kZWwgU2VydmVy
        IENBMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEotGiVANQtmYx1yEy0VcYsP9F
        ElyQIit/aIfIRZfFgu6ARX7GHQaoLOlVp4rZ/+I65V5Q2Nea4dI4gBhRSiiePqNF
        MEMwEgYDVR0TAQH/BAgwBgEB/wIBADAOBgNVHQ8BAf8EBAMCAQYwHQYDVR0OBBYE
        FOovkp3oTU4Tw9EZOWAXgtqiUeckMAoGCCqGSM49BAMCA0gAMEUCIA83on5UkCl5
        sPqZg7zDGM+x059PwmlvyU0BU3kzEq+UAiEA9YfZkckdsG707EjGObLVCxwLYihG
        5NG5xlBo2xzXp5Q=
        -----END CERTIFICATE-----
        """
    static let testServer = """
        -----BEGIN CERTIFICATE-----
        MIIBjjCCATOgAwIBAgIUGsXG8vhV2RPaoahtsohL2rECbG4wCgYIKoZIzj0EAwIw
        IDEeMBwGA1UEAwwVVmF1dGEgTW9kZWwgU2VydmVyIENBMB4XDTI2MTAyNzA3Mzk0
        NVoXDTI5MDEwNDA3Mzk0NVowEzERMA8GA1UEAwwIMTAuMC4wLjcwWTATBgcqhkjO
        PQIBBggqhkjOPQMBBwNCAAQ4tJ3RHsTQ4p855Tn+7cJwG4WAtejofSfn6oxthPUH
        aU1hOusxo5nZSYp3xPll5bAANzeXN8FS84IRx4QqVvUuo1gwVjAMBgNVHRMBAf8E
        AjAAMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDATAhBgNVHREE
        GjAYhwQKAAAHghB2YXV0YS10ZXN0LmxvY2FsMAoGCCqGSM49BAMCA0kAMEYCIQDf
        TfS8NCnE5H4rwfly+LJJ8KYzVSIHO/9EWD7FLLUhxAIhALOukCgRrQyIZitPjnsm
        PnOFs+b4glIY+cCcB2bPp240
        -----END CERTIFICATE-----
        """
    static let testRSA = """
        -----BEGIN CERTIFICATE-----
        MIIC/TCCAeWgAwIBAgIUOpElpxKTGplfm9Xb1a+CcBPsoF0wDQYJKoZIhvcNAQEL
        BQAwDjEMMAoGA1UEAwwDcnNhMB4XDTI2MTAwNzEwNTM0MFoXDTI4MTIxNTEwNTM0
        MFowDjEMMAoGA1UEAwwDcnNhMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKC
        AQEArKn70iZNhNQXsg0hMbW/2W6r/GVpBz9dRMsAXsOeFzqWN6SbqH5c04Sr5rON
        99bXIDYouGq95WdmIQMHzuNA5Qv49sp30GrqpyMnwxEVMtyREgfDSYUCRgw2IG0I
        zLJ426nwW/zlzATLsRG9DvG3csDibVAUPYHwwg53seKz5K1O3/R8QZdHdcWwtedg
        qelqO9GmehQYXSbvCaKNtAcub+A2+MO6NS8NN90YHgZ1YuZfv7J/+Vb26NobxOKO
        UzeHlZN5ANnJbBZUrssfKwqJJasq1BnWAxZHZnl6Lvf8EKSNU/JL/Xnk4Vdpt6DB
        R80uk7Xg/gs6IQVMimcHJIM5uwIDAQABo1MwUTAdBgNVHQ4EFgQUunJO9dErVW3h
        wK+ccWc+1l902ncwHwYDVR0jBBgwFoAUunJO9dErVW3hwK+ccWc+1l902ncwDwYD
        VR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAoMFnHKiY5e8aB0366evI
        UkEqQtr8EUGNQkQHqgm03G2YKSa+Mpsf/lkUpHbqeVbwRgpHu5GVTgj6iJsF4c3r
        SQpIyWJcYZiyhL4VK+lxCUoeQXG4LcGtzXLiFkGaDCoWnZo1Nh4XzhBUllH9SNcA
        DNPyyQKhJd5oM3pvmhH9yvJS4i0+ljECCdP/1W61ALvJ1VZ1OZRh1RSeXkR+1Mnh
        evh8QvCiwnBOZI1hgSGxPDHCvb3/I4FmUqUYoSCby6kwZ45kXj74PQ4kcC5xNdw5
        TvJo4mjwiSf6Rj+CRS4LqD1SxY1asSDn/m5ve2QmdoZhdoT5mtmaEGWIb8+mJPU0
        eA==
        -----END CERTIFICATE-----
        """
    static let caPin = "hIf8GxuhiN9CM+hpSCuiC63L4iwKoeiMPeQQGVf1NV4="
    static let serverPin = "W7ECLfQGJbixIYA8w2zmASwh+wP1lM07gbAxCyYfVpo="
    static let rsaPin = "C6NLsry/2ThXyZCGFfJNCd8ULZ4yGLq/QEoP9/6R1e4="
}
