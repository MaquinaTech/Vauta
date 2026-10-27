// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI

/// What every "problem as a title, what to do as a secondary line" notice shares, in the panel, Meetings, Settings and
/// Welcome: a semibold title, a fixed gap and the detail in the secondary colour. Each window passes its own text views
/// (and fonts), so a banner has the same hierarchy wherever it appears.
enum NoticeMetrics {
    /// The gap between a notice's title and its detail.
    static let gap: CGFloat = 2
}

extension View {
    /// The title of a notice that has a detail under it.
    func noticeTitle() -> some View { fontWeight(.semibold) }
}

/// A notice's text: the title and, when there is one, the detail under it.
struct NoticeStack<Title: View, Detail: View>: View {
    let title: Title
    var detail: Detail?

    var body: some View {
        VStack(alignment: .leading, spacing: NoticeMetrics.gap) {
            title.noticeTitle()
            if let detail { detail.foregroundStyle(.secondary) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A notice of a window: the problem as the semibold title, what to do about it as the secondary line. The buttons that
/// fix it (`trailing`) sit on the title's line, so the detail has the whole width and never wraps next to them.
struct NoticeText<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: NoticeMetrics.gap) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(wrapping: title.droppingFinalStop).noticeTitle().fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                trailing
            }
            if let detail { Text(wrapping: detail.avoidingWidow).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

extension NoticeText where Trailing == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}
