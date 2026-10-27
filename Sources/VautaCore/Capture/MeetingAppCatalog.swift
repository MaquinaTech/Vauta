// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A group of apps whose call audio Vauta can capture as "Others".
///
/// Browsers are grouped by engine because their media runs in shared helper
/// processes (every WebKit client plays through `com.apple.WebKit.GPU`, every
/// Gecko browser uses `org.mozilla.plugincontainer`). Web meetings (Google
/// Meet, Whereby, Jitsi…) and installed web apps (PWAs) are captured through
/// the family of the browser that runs them.
///
/// The raw value is stable and may be persisted.
public enum MeetingAppFamily: String, Sendable, Codable, CaseIterable, Identifiable {
    case webkit
    case chromium
    case firefox
    case zoom
    case teams
    case slack
    case discord
    case webex
    case facetime

    public var id: String { rawValue }

    public enum Kind: Sendable { case browser, app }

    public var kind: Kind {
        switch self {
        case .webkit, .chromium, .firefox: .browser
        default: .app
        }
    }

    public var displayName: String {
        switch self {
        case .webkit: String(localized: "Safari and WebKit browsers", comment: "Audio source family")
        case .chromium: String(localized: "Chrome, Edge and other Chromium browsers", comment: "Audio source family")
        case .firefox: String(localized: "Firefox and Gecko browsers", comment: "Audio source family")
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        case .slack: "Slack"
        case .discord: "Discord"
        case .webex: "Webex"
        case .facetime: "FaceTime"
        }
    }

    /// Known apps of the family (brand names are not localized).
    public var apps: [MeetingApp] { MeetingAppCatalog.apps[self] ?? [] }

    /// Exact bundle IDs given to `CATapDescription.bundleIDs`, so the tap
    /// follows these processes even when they relaunch. Other matching
    /// processes are added by object ID while the tap runs.
    public var tapBundleIDs: [String] {
        switch self {
        // Unchanged from 0.1.0, whose only scope was Safari.
        case .webkit: ["com.apple.Safari", "com.apple.WebKit.GPU", "com.apple.WebKit.WebContent"]
        case .firefox: apps.map(\.bundleID) + ["org.mozilla.plugincontainer"]
        case .facetime: ["com.apple.FaceTime", "com.apple.avconferenced"]
        default: apps.flatMap { [$0.bundleID, $0.bundleID + ".helper"] }
        }
    }

    /// Process matching rules: the apps' rules plus shared helper processes.
    var rules: [BundleIDRule] {
        apps.flatMap(\.rules) + MeetingAppCatalog.sharedRules(self)
    }
}

/// One app of a family.
public struct MeetingApp: Sendable, Hashable {
    public let name: String
    public let bundleID: String
    let rules: [BundleIDRule]

    /// The app and its helper processes (`<id>.helper`, `<id>.helper.renderer`,
    /// Electron's `<id>.helper.Renderer`…); Chromium browsers also own their
    /// installed web-app shims (`<id>.app.<hash>`).
    init(_ name: String, _ bundleID: String, helpers: Bool = true, webApps: Bool = false) {
        self.name = name
        self.bundleID = bundleID
        var rules: [BundleIDRule] = [.exact(bundleID)]
        if helpers { rules.append(.prefix(bundleID + ".helper")) }
        if webApps { rules.append(.prefix(bundleID + ".app.")) }
        self.rules = rules
    }
}

/// How a process bundle ID is matched (ASCII case-insensitive).
enum BundleIDRule: Sendable, Hashable {
    case exact(String)
    case prefix(String)

    /// Length of the matched pattern, or nil. Longer matches are more specific.
    func matchLength(_ lowercasedBundleID: String) -> Int? {
        switch self {
        case .exact(let id): lowercasedBundleID == id.lowercased() ? id.count : nil
        case .prefix(let p): lowercasedBundleID.hasPrefix(p.lowercased()) ? p.count : nil
        }
    }
}

/// Pure lookup tables: bundle ID → family/app, conferencing URL → service.
public enum MeetingAppCatalog {
    static let apps: [MeetingAppFamily: [MeetingApp]] = [
        .webkit: [
            MeetingApp("Safari", "com.apple.Safari", helpers: false),
            MeetingApp("Safari Technology Preview", "com.apple.SafariTechnologyPreview", helpers: false),
            MeetingApp("Orion", "com.kagi.kagimacOS", helpers: false),
            MeetingApp("DuckDuckGo", "com.duckduckgo.macos.browser", helpers: false),
        ],
        .chromium: [
            MeetingApp("Google Chrome", "com.google.Chrome", webApps: true),
            MeetingApp("Google Chrome Beta", "com.google.Chrome.beta", webApps: true),
            MeetingApp("Google Chrome Dev", "com.google.Chrome.dev", webApps: true),
            MeetingApp("Google Chrome Canary", "com.google.Chrome.canary", webApps: true),
            MeetingApp("Microsoft Edge", "com.microsoft.edgemac", webApps: true),
            MeetingApp("Microsoft Edge Beta", "com.microsoft.edgemac.Beta", webApps: true),
            MeetingApp("Microsoft Edge Dev", "com.microsoft.edgemac.Dev", webApps: true),
            MeetingApp("Microsoft Edge Canary", "com.microsoft.edgemac.Canary", webApps: true),
            MeetingApp("Brave", "com.brave.Browser", webApps: true),
            MeetingApp("Brave Beta", "com.brave.Browser.beta", webApps: true),
            MeetingApp("Brave Nightly", "com.brave.Browser.nightly", webApps: true),
            MeetingApp("Arc", "company.thebrowser.Browser"),
            MeetingApp("Dia", "company.thebrowser.dia"),
            MeetingApp("Vivaldi", "com.vivaldi.Vivaldi", webApps: true),
            MeetingApp("Opera", "com.operasoftware.Opera", webApps: true),
            MeetingApp("Opera GX", "com.operasoftware.OperaGX", webApps: true),
            MeetingApp("Chromium", "org.chromium.Chromium", webApps: true),
            MeetingApp("Comet", "ai.perplexity.comet"),
            MeetingApp("Helium", "net.imput.helium"),
        ],
        .firefox: [
            MeetingApp("Firefox", "org.mozilla.firefox", helpers: false),
            MeetingApp("Firefox Developer Edition", "org.mozilla.firefoxdeveloperedition", helpers: false),
            MeetingApp("Firefox Nightly", "org.mozilla.nightly", helpers: false),
            MeetingApp("LibreWolf", "org.mozilla.librewolf", helpers: false),
            MeetingApp("LibreWolf", "io.gitlab.librewolf-community", helpers: false),
            MeetingApp("Zen", "app.zen-browser.zen", helpers: false),
            MeetingApp("Floorp", "one.ablaze.floorp", helpers: false),
            MeetingApp("Waterfox", "net.waterfox.waterfox", helpers: false),
        ],
        .zoom: [MeetingApp("Zoom", "us.zoom.xos")],
        .teams: [
            MeetingApp("Microsoft Teams", "com.microsoft.teams2"),
            MeetingApp("Microsoft Teams classic", "com.microsoft.teams"),
        ],
        .slack: [MeetingApp("Slack", "com.tinyspeck.slackmacgap")],
        .discord: [
            MeetingApp("Discord", "com.hnc.Discord"),
            MeetingApp("Discord PTB", "com.hnc.DiscordPTB"),
            MeetingApp("Discord Canary", "com.hnc.DiscordCanary"),
        ],
        .webex: [
            MeetingApp("Webex", "Cisco-Systems.Spark"),
            MeetingApp("Webex Meetings", "com.webex.meetingmanager"),
            MeetingApp("Webex Meetings", "com.cisco.webexmeetingsapp"),
        ],
        .facetime: [MeetingApp("FaceTime", "com.apple.FaceTime", helpers: false)],
    ]

    /// Processes shared by every app of a family (no app of their own).
    static func sharedRules(_ family: MeetingAppFamily) -> [BundleIDRule] {
        switch family {
        // WebKit's out-of-process media; installed Safari web apps (Dock apps).
        case .webkit: [.exact("com.apple.WebKit.GPU"), .exact("com.apple.WebKit.WebContent"),
                       .prefix("com.apple.Safari.WebApp.")]
        // Gecko media and content processes, shared by every Gecko browser.
        case .firefox: [.exact("org.mozilla.plugincontainer")]
        // FaceTime call audio runs in this daemon, which may report no bundle ID.
        case .facetime: [.exact("com.apple.avconferenced")]
        default: []
        }
    }

    /// The family whose rules match `bundleID` most specifically.
    public static func family(forBundleID bundleID: String) -> MeetingAppFamily? {
        bestMatch(bundleID)?.family
    }

    /// The known app that owns `bundleID` (its helpers included), if any.
    public static func app(forBundleID bundleID: String) -> MeetingApp? {
        bestMatch(bundleID)?.app
    }

    /// Whether `bundleID` belongs to any of `families`.
    static func matches(_ bundleID: String, in families: Set<MeetingAppFamily>) -> Bool {
        family(forBundleID: bundleID).map(families.contains) ?? false
    }

    private static func bestMatch(_ bundleID: String) -> (family: MeetingAppFamily, app: MeetingApp?)? {
        guard !bundleID.isEmpty else { return nil }
        let id = bundleID.lowercased()
        var best: (length: Int, family: MeetingAppFamily, app: MeetingApp?)?
        for family in MeetingAppFamily.allCases {
            for app in family.apps {
                for rule in app.rules {
                    if let n = rule.matchLength(id), n > (best?.length ?? 0) { best = (n, family, app) }
                }
            }
            for rule in sharedRules(family) {
                if let n = rule.matchLength(id), n > (best?.length ?? 0) { best = (n, family, nil) }
            }
        }
        return best.map { ($0.family, $0.app) }
    }
}
