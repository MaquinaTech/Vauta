// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import ServiceManagement

/// Switches the few places that would otherwise ask this Mac (installed
/// speech models) to answer with sample data while `Vauta render-ui` runs.
@MainActor
enum SnapshotMode {
    static var catalog: SpeechLanguageCatalog?
    static var reservedLanguages: [String] = []
    /// Permission states to report instead of this Mac's (nil = ask the system).
    static var microphone: PermissionState?
    static var notifications: PermissionState?
    /// The login item's state to report instead of this Mac's (nil = ask the system).
    static var loginItem: SMAppService.Status?
    /// Increase Contrast / Reduce Transparency, for the scene being rendered (reset after each image).
    static var highContrast = false
    static var reduceTransparency = false
    /// VoiceOver on or off, instead of this Mac's (nil = ask the system).
    static var voiceOver: Bool?
    /// The list of speech languages is still loading (setup's Language page).
    static var languagesLoading = false
    /// The consent notice is shown whole ("Show Full Notice" pressed).
    static var consentExpanded = false
    /// The encrypted store's size Status reports, so renders don't change with the live store's size.
    static var storeBytes: Int?
}
#endif
