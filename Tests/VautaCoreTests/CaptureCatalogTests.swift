// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Capture: meeting app catalog")
struct CaptureCatalogTests {
    @Test(arguments: [
        // WebKit: Safari, its shared media processes and installed web apps.
        ("com.apple.Safari", MeetingAppFamily.webkit),
        ("com.apple.SafariTechnologyPreview", .webkit),
        ("com.apple.WebKit.GPU", .webkit),
        ("com.apple.WebKit.WebContent", .webkit),
        ("com.apple.Safari.WebApp.1F2E3D4C-0000-4000-8000-123456789ABC", .webkit),
        ("com.kagi.kagimacOS", .webkit),
        // Chromium: main app, audio-service helper, renderer/GPU helpers, PWA shims.
        ("com.google.Chrome", .chromium),
        ("com.google.Chrome.helper", .chromium),
        ("com.google.Chrome.helper.renderer", .chromium),
        ("com.google.Chrome.helper.gpu", .chromium),
        ("com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan", .chromium),
        ("com.google.Chrome.beta", .chromium),
        ("com.google.Chrome.canary.helper", .chromium),
        ("com.microsoft.edgemac", .chromium),
        ("com.microsoft.edgemac.helper", .chromium),
        ("com.microsoft.edgemac.app.abcdef", .chromium),
        ("com.brave.Browser.helper", .chromium),
        ("company.thebrowser.Browser.helper", .chromium),
        ("company.thebrowser.dia", .chromium),
        ("com.vivaldi.Vivaldi.helper", .chromium),
        ("com.operasoftware.Opera.helper", .chromium),
        ("org.chromium.Chromium.helper", .chromium),
        // Firefox family and the Gecko content process shared by every fork.
        ("org.mozilla.firefox", .firefox),
        ("org.mozilla.firefoxdeveloperedition", .firefox),
        ("org.mozilla.nightly", .firefox),
        ("org.mozilla.plugincontainer", .firefox),
        ("app.zen-browser.zen", .firefox),
        // Native apps and their (Electron-style) helpers.
        ("us.zoom.xos", .zoom),
        ("com.microsoft.teams2", .teams),
        ("com.microsoft.teams2.helper", .teams),
        ("com.microsoft.teams", .teams),
        ("com.microsoft.teams.helper.Renderer", .teams),
        ("com.tinyspeck.slackmacgap", .slack),
        ("com.tinyspeck.slackmacgap.helper.Renderer", .slack),
        ("com.hnc.Discord", .discord),
        ("com.hnc.Discord.helper.Renderer", .discord),
        ("Cisco-Systems.Spark", .webex),
        ("Cisco-Systems.Spark.helper", .webex),
        ("com.webex.meetingmanager", .webex),
        ("com.apple.FaceTime", .facetime),
        ("com.apple.avconferenced", .facetime),
    ])
    func matchesFamily(bundleID: String, family: MeetingAppFamily) {
        #expect(MeetingAppCatalog.family(forBundleID: bundleID) == family)
    }

    @Test(arguments: [
        "", "com.apple.Music", "com.spotify.client", "com.apple.WebKit.Networking", "com.apple.Mail",
        "com.google.Chromecast", "com.google.Chrome2", "com.microsoft.teams3", "us.zoom.xosx",
        "org.mozilla.thunderbird", "com.tinyspeck.slackmacgapx", "local.vauta.app",
    ])
    func unrelatedBundleIDsDontMatch(bundleID: String) {
        #expect(MeetingAppCatalog.family(forBundleID: bundleID) == nil)
    }

    @Test func matchingIgnoresCase() {
        #expect(MeetingAppCatalog.family(forBundleID: "COM.GOOGLE.CHROME.HELPER") == .chromium)
        #expect(MeetingAppCatalog.family(forBundleID: "cisco-systems.spark") == .webex)
        #expect(MeetingAppCatalog.family(forBundleID: "com.hnc.discord.helper.renderer") == .discord)
    }

    @Test func mostSpecificAppWins() {
        #expect(MeetingAppCatalog.app(forBundleID: "com.google.Chrome.beta.helper")?.name == "Google Chrome Beta")
        #expect(MeetingAppCatalog.app(forBundleID: "com.google.Chrome.helper")?.name == "Google Chrome")
        #expect(MeetingAppCatalog.app(forBundleID: "com.google.Chrome.app.meet")?.name == "Google Chrome")
        #expect(MeetingAppCatalog.app(forBundleID: "com.microsoft.teams2.helper")?.name == "Microsoft Teams")
        #expect(MeetingAppCatalog.app(forBundleID: "com.microsoft.teams.helper")?.name == "Microsoft Teams classic")
        // Shared helper processes belong to the family but to no single app.
        #expect(MeetingAppCatalog.app(forBundleID: "com.apple.WebKit.GPU") == nil)
        #expect(MeetingAppCatalog.app(forBundleID: "org.mozilla.plugincontainer") == nil)
    }

    @Test func webkitTapKeepsTheLegacySafariBundleIDs() {
        // 0.1.0 tapped exactly these: existing users must capture the same audio.
        #expect(MeetingAppFamily.webkit.tapBundleIDs == ["com.apple.Safari", "com.apple.WebKit.GPU", "com.apple.WebKit.WebContent"])
    }

    @Test func tapBundleIDsIncludeHelpersAndSharedProcesses() {
        #expect(MeetingAppFamily.chromium.tapBundleIDs.contains("com.google.Chrome.helper"))
        #expect(MeetingAppFamily.chromium.tapBundleIDs.contains("com.microsoft.edgemac.helper"))
        #expect(MeetingAppFamily.firefox.tapBundleIDs.contains("org.mozilla.plugincontainer"))
        #expect(MeetingAppFamily.zoom.tapBundleIDs.contains("us.zoom.xos"))
        // Every tap bundle ID maps back to its own family.
        for family in MeetingAppFamily.allCases {
            for id in family.tapBundleIDs { #expect(MeetingAppCatalog.family(forBundleID: id) == family, "\(id)") }
        }
    }

    @Test func familyIDsAreStableAndNamed() {
        #expect(MeetingAppFamily.allCases.map(\.rawValue) ==
                ["webkit", "chromium", "firefox", "zoom", "teams", "slack", "discord", "webex", "facetime"])
        for family in MeetingAppFamily.allCases {
            #expect(!family.displayName.isEmpty)
            #expect(!family.apps.isEmpty)
        }
        #expect(MeetingAppFamily.chromium.kind == .browser)
        #expect(MeetingAppFamily.zoom.kind == .app)
    }
}

@Suite("Capture: conferencing links")
struct CaptureConferencingLinkTests {
    @Test(arguments: [
        ("https://us02web.zoom.us/j/81234567890?pwd=abc", ConferencingService.zoom),
        ("https://zoom.us/j/81234567890", .zoom),
        ("https://acme.zoom.us/my/alice", .zoom),
        ("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0", .teams),
        ("https://teams.microsoft.com/meet/1234567?p=abc", .teams),
        ("https://teams.live.com/meet/9876543210", .teams),
        ("https://meet.google.com/abc-defg-hij", .googleMeet),
        ("https://acme.webex.com/meet/alice", .webex),
        ("https://acme.my.webex.com/acme.my/j.php?MTID=m123", .webex),
        ("https://facetime.apple.com/join#v=1&p=abc", .facetime),
        ("https://meet.jit.si/MyRoom", .jitsi),
        ("https://whereby.com/team-room", .whereby),
        ("https://app.slack.com/huddle/T123/C456", .slackHuddle),
        ("https://app.chime.aws/meetings/1234567890", .chime),
        ("https://discord.com/channels/123/456", .discord),
        ("https://discord.gg/abcdef", .discord),
        ("https://meet.goto.com/123456789", .goto),
        ("https://global.gotomeeting.com/join/123456789", .goto),
        ("http://meet.google.com/abc-defg-hij", .googleMeet),
    ])
    func recognizesMeetingLinks(url: String, service: ConferencingService) throws {
        let link = try #require(ConferencingLink(url: URL(string: url)!))
        #expect(link.service == service)
    }

    @Test(arguments: [
        "https://zoom.us/", "https://zoom.us/pricing", "https://evilzoom.us/j/123", "https://zoom.us.example.com/j/1",
        "https://meet.google.com/", "https://meet.google.com", "https://teams.microsoft.com/v2/",
        "https://google.com/meet/abc", "mailto:meet@meet.google.com", "https://notwhereby.com/room",
        "https://app.slack.com/client/T123", "ftp://meet.jit.si/room",
    ])
    func ignoresOtherLinks(url: String) {
        #expect(ConferencingLink(url: URL(string: url)!) == nil)
    }

    @Test func mapsServicesToTheAppThatPlaysTheAudio() {
        #expect(ConferencingService.zoom.appFamily == .zoom)
        #expect(ConferencingService.teams.appFamily == .teams)
        #expect(ConferencingService.webex.appFamily == .webex)
        #expect(ConferencingService.facetime.appFamily == .facetime)
        #expect(ConferencingService.slackHuddle.appFamily == .slack)
        #expect(ConferencingService.discord.appFamily == .discord)
        // Web-only services play in whichever browser runs them.
        for service in [ConferencingService.googleMeet, .jitsi, .whereby, .chime, .goto] { #expect(service.appFamily == nil) }
    }

    @Test func findsTheFirstMeetingLinkInText() {
        let notes = """
        Agenda: https://docs.example.com/agenda
        Join: https://meet.google.com/abc-defg-hij or dial in.
        Backup: https://zoom.us/j/123
        """
        #expect(ConferencingLink.first(in: notes)?.service == .googleMeet)
        #expect(ConferencingLink.first(in: "Room 4B, no link") == nil)
        #expect(ConferencingLink.first(in: "") == nil)
    }
}
