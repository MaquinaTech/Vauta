// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension LLMClient {
    // MARK: Trust and peer checks

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        trust(challenge)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        trust(challenge)
    }

    /// The configured endpoints' trust, keeping how long the presented certificates stay valid for Status.
    private func trust(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let (disposition, credential, validity) = ServerTrust.evaluate(challenge, allEndpoints)
        if let validity { recordCertificate(validity) }
        return (disposition, credential)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        nil
    }

    /// For hosts given by name, the address actually connected to must be
    /// private (or loopback in local mode); otherwise later requests are refused
    /// until the configuration is applied again. This catches, once its request
    /// completes, a connection the probe did not check (`LLMClient+PeerCheck.swift`).
    public func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let url = task.originalRequest?.url, let host = url.host()?.lowercased(),
              let mode = config?.mode, !ServerAddress.isIPLiteral(host) else { return }
        for address in peerAddresses(metrics) where !Self.peerAllowed(address, mode: mode) {
            recordPeerViolation(address)
        }
    }

    /// In remote mode the peer may also be a global IPv6 address on a subnet this
    /// Mac is directly attached to (e.g. a `.local` name answered over IPv6); an
    /// IPv4 peer must always be private.
    static func peerAllowed(_ address: String, mode: LLMServerConfig.Mode,
                            onLink: (String) -> Bool = { ServerAddress.isOnLink($0) }) -> Bool {
        switch mode {
        case .local: ServerAddress.isLoopback(address)
        case .remote:
            ServerAddress.isIPLiteral(address) && !ServerAddress.isLoopback(address)
                && (ServerAddress.isPrivateOrLoopbackPeer(address) || (ServerAddress.isIPv6(address) && onLink(address)))
        }
    }
}
