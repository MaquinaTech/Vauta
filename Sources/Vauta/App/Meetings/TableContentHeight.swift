// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import SwiftUI

extension View {
    /// Reports the height a `Table` needs to show all its rows exactly (header, border and every row, wrapped rows
    /// included), read from the table itself, so a card sized to it ends under the last row in any language and width.
    /// `token` changes whenever the rows can change height (their text, the table's width).
    func measuredTableHeight(token: Int, _ report: @escaping (CGFloat) -> Void) -> some View {
        background(TableHeightProbe(token: token, report: report))
    }
}

private struct TableHeightProbe: NSViewRepresentable {
    let token: Int
    let report: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        context.coordinator.report = report
        context.coordinator.schedule(from: view)
    }

    /// Never takes a click away from the table it sits behind.
    final class ProbeView: NSView {
        weak var coordinator: Coordinator?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.schedule(from: self)
        }
    }

    @MainActor
    final class Coordinator {
        var report: (CGFloat) -> Void = { _ in }
        private weak var table: NSTableView?
        private var observers: [NSObjectProtocol] = []
        private var last: CGFloat = 0
        private var pending = false
        private weak var anchor: ProbeView?

        /// Measures after SwiftUI and AppKit finished the layout that follows the change. A row whose height is not
        /// known yet counts as a plain row until it is on screen, so a change of the answer measures again (a few
        /// times at most) until the rows settle.
        func schedule(from probe: ProbeView, attempt: Int = 0) {
            anchor = probe
            guard !pending || attempt > 0 else { return }
            pending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.05)) { [weak self, weak probe] in
                guard let self else { return }
                self.pending = false
                guard let probe else { return }
                if self.measure(from: probe), attempt < 8 { self.schedule(from: probe, attempt: attempt + 1) }
            }
        }

        /// Returns whether the measured height changed.
        private func measure(from probe: ProbeView) -> Bool {
            guard let window = probe.window else { return false }
            if table == nil || table?.window !== window { attach(to: Self.table(near: probe, in: window)) }
            guard let table, let scroll = table.enclosingScrollView, table.numberOfRows > 0 else { return false }
            let rows = table.rect(ofRow: table.numberOfRows - 1).maxY
            // The scroll view's border and the header, which floats over the top of the row area instead of sitting
            // above it.
            let chrome = scroll.frame.height - scroll.contentView.frame.height + (table.headerView?.frame.height ?? 0)
            let height = ceil(chrome + rows)
            guard abs(height - last) >= 0.5 else { return false }
            last = height
            report(height)
            return true
        }

        private func attach(to table: NSTableView?) {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            self.table = table
            guard let table else { return }
            table.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: table, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self, let anchor = self.anchor { self.schedule(from: anchor) } }
            })
        }

        /// The table that overlaps the probe most (the window can hold others, such as the sidebar list).
        private static func table(near probe: NSView, in window: NSWindow) -> NSTableView? {
            let mine = probe.convert(probe.bounds, to: nil)
            var best: (NSTableView, CGFloat)?
            func visit(_ view: NSView) {
                if let table = view as? NSTableView {
                    let frame = table.convert(table.visibleRect, to: nil).intersection(mine)
                    let area = frame.isNull ? 0 : frame.width * frame.height
                    if area > (best?.1 ?? 0) { best = (table, area) }
                }
                view.subviews.forEach(visit)
            }
            if let content = window.contentView { visit(content) }
            return best?.0
        }
    }
}
