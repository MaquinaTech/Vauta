// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A video-conferencing service recognized from a meeting link.
public enum ConferencingService: String, Sendable, Codable, CaseIterable {
    case zoom
    case teams
    case googleMeet
    case webex
    case facetime
    case jitsi
    case whereby
    case slackHuddle
    case chime
    case discord
    case goto

    public var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        case .googleMeet: "Google Meet"
        case .webex: "Webex"
        case .facetime: "FaceTime"
        case .jitsi: "Jitsi Meet"
        case .whereby: "Whereby"
        case .slackHuddle: "Slack"
        case .chime: "Amazon Chime"
        case .discord: "Discord"
        case .goto: "GoTo Meeting"
        }
    }

    /// The native app family that usually plays this service's audio when it
    /// is installed. Nil: the meeting runs in a web browser, whose family is
    /// the one that holds the microphone (see `MeetingPresence`).
    public var appFamily: MeetingAppFamily? {
        switch self {
        case .zoom: .zoom
        case .teams: .teams
        case .webex: .webex
        case .facetime: .facetime
        case .slackHuddle: .slack
        case .discord: .discord
        case .googleMeet, .jitsi, .whereby, .chime, .goto: nil
        }
    }
}

/// A meeting link found in a calendar event.
public struct ConferencingLink: Sendable, Equatable {
    public let service: ConferencingService
    public let url: URL

    /// Recognizes `url` as a meeting link, or returns nil.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host()?.lowercased() else { return nil }
        // A bare domain is a product page, not a meeting.
        let path = url.path(percentEncoded: false).lowercased()
        guard path.count > 1, let service = Self.patterns.first(where: { $0.matches(host: host, path: path) })?.service else { return nil }
        self.service = service
        self.url = url
    }

    /// The first meeting link in free text (event URL, location or notes).
    public static func first(in text: String) -> ConferencingLink? {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            if let url = match.url, let link = ConferencingLink(url: url) { return link }
        }
        return nil
    }

    private struct Pattern {
        let service: ConferencingService
        /// Matches the host itself or any of its subdomains.
        let domain: String
        /// Empty: any path.
        let pathPrefixes: [String]

        func matches(host: String, path: String) -> Bool {
            guard host == domain || host.hasSuffix("." + domain) else { return false }
            return pathPrefixes.isEmpty || pathPrefixes.contains { path.hasPrefix($0) }
        }
    }

    /// Ordered: the first match wins.
    private static let patterns: [Pattern] = [
        Pattern(service: .zoom, domain: "zoom.us", pathPrefixes: ["/j/", "/my/", "/w/", "/wc/", "/s/"]),
        Pattern(service: .zoom, domain: "zoomgov.com", pathPrefixes: ["/j/", "/my/", "/w/", "/wc/", "/s/"]),
        Pattern(service: .teams, domain: "teams.microsoft.com", pathPrefixes: ["/l/meetup-join/", "/meet/"]),
        Pattern(service: .teams, domain: "teams.live.com", pathPrefixes: []),
        Pattern(service: .googleMeet, domain: "meet.google.com", pathPrefixes: []),
        Pattern(service: .webex, domain: "webex.com", pathPrefixes: []),
        Pattern(service: .facetime, domain: "facetime.apple.com", pathPrefixes: ["/join"]),
        Pattern(service: .jitsi, domain: "meet.jit.si", pathPrefixes: []),
        Pattern(service: .whereby, domain: "whereby.com", pathPrefixes: []),
        Pattern(service: .slackHuddle, domain: "app.slack.com", pathPrefixes: ["/huddle/"]),
        Pattern(service: .chime, domain: "chime.aws", pathPrefixes: []),
        Pattern(service: .discord, domain: "discord.com", pathPrefixes: ["/channels/", "/invite/"]),
        Pattern(service: .discord, domain: "discord.gg", pathPrefixes: []),
        Pattern(service: .goto, domain: "meet.goto.com", pathPrefixes: []),
        Pattern(service: .goto, domain: "gotomeeting.com", pathPrefixes: []),
        Pattern(service: .goto, domain: "goto.com", pathPrefixes: ["/meeting/", "/join/"]),
    ]
}
