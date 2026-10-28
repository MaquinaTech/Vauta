// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI

/// The privacy promises in Settings → Privacy & Security (Welcome sums them up in one card,
/// and the panel header carries a deliberate short form of the first one). All four icons are
/// outline glyphs of one weight, sized so that no promise looks heavier than the others.
enum PrivacyPromise {
    static var audioNeverSaved: Label<Text, PromiseGlyph> {
        Label { Text("Audio is never saved to disk.") } icon: { PromiseGlyph("waveform.slash") }
    }

    static var transcriptsEncryptedDetailed: Label<Text, PromiseGlyph> {
        Label { Text("Meetings (transcripts, minutes, notes and tasks) and context are encrypted (AES-256) on this Mac, with the key in your Keychain.") } icon: { PromiseGlyph("lock") }
    }

    static var noAnalytics: Label<Text, PromiseGlyph> {
        Label { Text("Vauta collects no analytics.") } icon: { PromiseGlyph("hand.raised.slash") }
    }

    static var nothingLeaves: Label<Text, PromiseGlyph> {
        Label { Text("Meeting text leaves this Mac only through a model server on another computer, or in what you choose to add to Reminders, Calendar or an email.") } icon: { PromiseGlyph("icloud.slash") }
    }
}

/// A promise icon. All four are outline glyphs (no filled pupil, no dense meridians) of the regular weight at one point
/// size, in the medium image scale; only the slashed cloud and hand are nudged by half a point, the two whose ink is
/// widest. The label style then puts them in one fixed box.
struct PromiseGlyph: View {
    let name: String
    init(_ name: String) { self.name = name }

    private var size: CGFloat {
        switch name {
        case "waveform.slash": 15
        case "lock": 17
        case "hand.raised.slash": 14.5
        case "icloud.slash": 14
        default: 15
        }
    }

    var body: some View {
        Image(systemName: name)
            .symbolRenderingMode(.monochrome)
            .symbolVariant(.none)
            .font(.system(size: size, weight: .regular))
            .imageScale(.medium)
    }
}

/// One icon rendering for the promises: monochrome, in Vauta's gradient and the same 22 pt column and
/// 10 pt gap as `SetupBulletStyle`, so Settings and the setup pages style their lists alike.
struct PromiseLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon
                .foregroundStyle(Brand.symbolGradient)
                // A fixed square box, so the four glyphs line up in one column whatever their own width.
                .frame(width: 22, height: 20, alignment: .center)
                .accessibilityHidden(true)
            configuration.title
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
