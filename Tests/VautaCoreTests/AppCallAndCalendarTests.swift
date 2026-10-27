// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("App: detected calls and calendar events")
struct AppCallAndCalendarTests {
    @Test func appNamesComeFromTheCatalog() {
        #expect(CallDescription.appName(bundleID: "com.google.Chrome.helper", family: .chromium) == "Google Chrome")
        #expect(CallDescription.appName(bundleID: "us.zoom.xos", family: .zoom) == "Zoom")
        // A shared WebKit helper belongs to no app: no guess for browsers…
        #expect(CallDescription.appName(bundleID: "com.apple.WebKit.GPU", family: .webkit) == nil)
        // …but native apps fall back to their family name.
        #expect(CallDescription.appName(bundleID: nil, family: .teams) == "Microsoft Teams")
        #expect(CallDescription.appName(bundleID: nil, family: nil) == nil)
    }

    @Test func aServiceInABrowserNamesBoth() {
        let call = CallDescription(appName: "Google Chrome", family: .chromium, service: .googleMeet)
        #expect(call.sentence == "Google Meet in Google Chrome is using the microphone.")
        #expect(call.shortName == "Google Meet")
    }

    @Test func aNativeAppIsNotRepeated() {
        let zoom = CallDescription(appName: "Zoom", family: .zoom, service: .zoom)
        #expect(zoom.sentence == "Zoom is using the microphone.")
        let teams = CallDescription(appName: "Microsoft Teams", family: .teams, service: .teams)
        #expect(teams.sentence == "Microsoft Teams is using the microphone.")
        #expect(teams.shortName == "Microsoft Teams")
    }

    @Test func partialKnowledge() {
        #expect(CallDescription(appName: "Firefox", family: .firefox, service: nil).sentence == "Firefox is using the microphone.")
        #expect(CallDescription(appName: nil, family: .webkit, service: .whereby).sentence == "Whereby is using the microphone.")
        #expect(CallDescription(appName: nil, family: .webkit, service: nil).sentence == "A meeting app is using the microphone.")
        #expect(CallDescription(appName: nil, family: .webkit, service: nil).shortName == nil)
    }

    // MARK: Calendar

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let window: TimeInterval = 600
    private func event(_ startMinutes: Double, _ endMinutes: Double) -> (start: Date, end: Date) {
        (now + startMinutes * 60, now + endMinutes * 60)
    }

    @Test func picksTheEventInProgressOverOneAboutToStart() {
        let events = [event(8, 38), event(-20, 40)]
        #expect(CalendarEventPicker.best(events, now: now, window: window) == 1)
    }

    @Test func backToBackEventsSwitchAtTheBoundary() {
        // 10:00–11:00 and 11:00–12:00; "now" is two minutes before or after 11:00.
        let before = [event(-58, 2), event(2, 62)]
        #expect(CalendarEventPicker.best(before, now: now, window: window) == 0)
        let after = [event(-62, -2), event(-2, 58)]
        #expect(CalendarEventPicker.best(after, now: now, window: window) == 1)
    }

    @Test func tiesGoToTheNewerMeeting() {
        let events = [event(-60, 60), event(-30, 60)]
        #expect(CalendarEventPicker.best(events, now: now, window: window) == 1)
    }

    @Test func ignoresEventsOutsideTheWindow() {
        #expect(CalendarEventPicker.best([event(15, 45), event(-90, -11)], now: now, window: window) == nil)
        #expect(CalendarEventPicker.best([], now: now, window: window) == nil)
        #expect(CalendarEventPicker.best([event(-15, -9)], now: now, window: window) == 0)
        #expect(CalendarEventPicker.best([event(5, 5)], now: now, window: window) == 0)
    }

    @Test func meetingLinksOfEveryPlatformAreRecognized() throws {
        let notes = """
            Join: https://us02web.zoom.us/j/123456789?pwd=abc
            """
        #expect(ConferencingLink.first(in: notes)?.service == .zoom)
        #expect(ConferencingLink.first(in: "https://teams.microsoft.com/l/meetup-join/19%3ameeting")?.service == .teams)
        #expect(ConferencingLink.first(in: "Room 4 / meet.google.com/abc-defg-hij")?.service == .googleMeet)
        #expect(ConferencingLink.first(in: "https://acme.webex.com/meet/jdoe")?.service == .webex)
    }
}
