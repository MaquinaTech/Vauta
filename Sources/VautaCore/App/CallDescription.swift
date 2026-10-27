// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The call Vauta detected, as it is described to the user: which app holds
/// the microphone and, when a calendar event has a meeting link, the service.
public struct CallDescription: Equatable, Sendable {
    /// The app holding the microphone ("Google Chrome", "Zoom"), if known.
    public var appName: String?
    /// The family of that app.
    public var family: MeetingAppFamily?
    /// The service of the current calendar event's meeting link.
    public var service: ConferencingService?

    public init(appName: String?, family: MeetingAppFamily?, service: ConferencingService?) {
        self.appName = appName
        self.family = family
        self.service = service
    }

    /// The app's name: the catalog app, else the family name for native apps
    /// (a browser family name would be vaguer than saying nothing).
    public static func appName(bundleID: String?, family: MeetingAppFamily?) -> String? {
        if let bundleID, let app = MeetingAppCatalog.app(forBundleID: bundleID) { return app.name }
        guard let family, family.kind == .app else { return nil }
        return family.displayName
    }

    /// The service runs inside the app (Google Meet in Chrome), rather than
    /// being the app itself (Zoom in Zoom).
    var serviceRunsInApp: Bool {
        guard let service, appName != nil else { return false }
        if let family, service.appFamily == family { return false }
        return service.displayName != appName
    }

    /// One sentence, e.g. "Google Meet in Google Chrome is using the microphone."
    public var sentence: String {
        if serviceRunsInApp, let service, let appName {
            return String(localized: "\(service.displayName) in \(appName) is using the microphone.",
                          comment: "Detected call; the first argument is a service such as Google Meet, the second an app such as Google Chrome")
        }
        if let name = appName ?? service?.displayName {
            return String(localized: "\(name) is using the microphone.",
                          comment: "Detected call; the argument is an app or service name such as Zoom")
        }
        return String(localized: "A meeting app is using the microphone.", comment: "Detected call when the app is unknown")
    }

    /// The name shown on chips and in hang-up prompts ("Google Meet", "Zoom").
    public var shortName: String? {
        serviceRunsInApp ? service?.displayName : appName ?? service?.displayName
    }
}
