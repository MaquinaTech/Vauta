// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The "translate into" choices: automatic, then every language Apple can
/// translate into from the meeting language. Used inside menus.
struct TranslationTargetPicker: View {
    let model: LiveTranslationModel

    var body: some View {
        Picker("Translate into", selection: Binding(get: { model.preferences.translationTarget ?? "" },
                                                    set: { model.chooseTarget($0.isEmpty ? nil : $0) })) {
            Text(automaticLabel).tag("")
            ForEach(model.targets) { target in
                if target.availability == .downloadable {
                    Label(target.name, systemImage: "arrow.down.circle").tag(target.id)
                } else {
                    Text(target.name).tag(target.id)
                }
            }
        }
        .pickerStyle(.inline)
    }

    private var automaticLabel: String {
        guard let source = model.sourceLanguage, let target = model.resolvedTarget(for: source) else {
            return String(localized: "Automatic", comment: "Language menu: use the Mac’s language")
        }
        return String(localized: "Automatic (\(TranslationPair.name(of: target)))",
                      comment: "Language menu: use the Mac’s language; the argument is that language")
    }
}
