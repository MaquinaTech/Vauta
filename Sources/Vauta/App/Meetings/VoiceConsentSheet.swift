// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Who a “Remember this voice” sheet is about.
struct VoiceConsentRequest: Identifiable, Equatable {
    let speakerID: Int64
    let name: String
    var id: Int64 { speakerID }
}

/// The consent attestation for “Remember this voice”. Saving a voice fingerprint of somebody is the user's decision and
/// responsibility: the sheet says what is stored and where, asks the user to confirm that the person agreed, and the
/// moment of that confirmation is stored with the voice.
struct VoiceConsentSheet: View {
    let name: String
    /// The attestation box starts unchecked; only the snapshot scenes start with it checked.
    @ViewLocalState private var agreed: Bool
    let remember: () -> Void
    let cancel: () -> Void

    init(name: String, agreed: Bool = false, remember: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.name = name
        _agreed = ViewLocalState(initialValue: agreed)
        self.remember = remember
        self.cancel = cancel
    }

    static func title(_ name: String) -> Text {
        Text("Remember \(name)’s voice?", comment: "Consent sheet title for saving a person’s voice; the argument is the person’s name")
    }

    static func storesNotice(_ name: String) -> Text {
        Text("Stores a voice fingerprint of \(name) on this Mac only. Only do this if \(name) agreed.",
             comment: "Consent sheet: what saving a voice does and the condition for doing it; both arguments are the same person’s name")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(Self.title(name), symbol: "waveform.badge.plus", tint: .accentColor)
            Self.storesNotice(name)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("The fingerprint is a list of numbers, not a recording. It stays in your encrypted data and your encrypted backups, is never sent anywhere by Vauta and is never in exports.",
                         comment: "Consent sheet: what the voice fingerprint is and where it stays")
                } icon: { Image(systemName: "lock").accessibilityHidden(true) }
                Label {
                    Text("Later meetings can then suggest this person when they hear this voice. You can delete it at any time in Settings\u{00A0}→\u{00A0}Speakers or on the person’s card.",
                         comment: "Consent sheet: what the saved voice is used for and how to remove it")
                } icon: { Image(systemName: "person.wave.2").accessibilityHidden(true) }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $agreed) {
                Text("\(name) agreed to this.", comment: "Consent sheet checkbox: the user confirms the person agreed; the argument is the person’s name")
            }
            .toggleStyle(.checkbox)
            // One wrapped paragraph at the full width of the sheet (SheetFootnote would put each sentence on its own line).
            Text("Vauta stores the time you confirm this next to the voice. Consent is your responsibility as the person recording. Organizations should note voice recognition in their data protection impact assessment.",
                 comment: "Consent sheet footnote: the time of the confirmation is stored; consent is the recording user’s responsibility; organizations are advised to cover it in a data protection impact assessment")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Remember This Voice", comment: "Consent sheet; button that saves the voice fingerprint after the user confirmed the person agreed"), action: remember)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!agreed)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
