// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import SwiftUI

/// The sidebar's mode switch: a segmented control whose segments share the width equally, so it spans the
/// sidebar in every language (SwiftUI's segmented Picker sizes itself to its labels).
struct ModePicker: NSViewRepresentable {
    @Binding var selection: MeetingsModel.Mode
    /// The width the control is laid out at (the sidebar's), measured by the owner: the font and distribution come from it alone.
    var width: CGFloat = 300

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let modes = MeetingsModel.Mode.allCases
        let control = NSSegmentedControl(labels: modes.map(\.label), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentStyle = .automatic
        control.controlSize = .small
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (index, mode) in modes.enumerated() {
            control.setToolTip("\(mode.label) (⌘\(String(mode.shortcut)))", forSegment: index)
        }
        control.setAccessibilityLabel(String(localized: "View", comment: "Accessibility label of the Meetings mode switch"))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        let index = MeetingsModel.Mode.allCases.firstIndex(of: selection) ?? 0
        if control.selectedSegment != index { control.selectedSegment = index }
        context.coordinator.layout(forWidth: width)
        context.coordinator.apply(to: control)
    }

    /// The control spans the proposed width. Its font size and segment distribution come from the width alone
    /// (never from which segment is selected), so every mode shows the same control: equal segments when four
    /// times the widest label fits, else proportional segments, and then a smaller font.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        guard let available = proposal.width, available.isFinite else {
            return CGSize(width: nsView.fittingSize.width, height: nsView.fittingSize.height)
        }
        // Only a size here: SwiftUI asks for several proposals while laying out, and the control itself is configured in updateNSView.
        return CGSize(width: available, height: nsView.fittingSize.height)
    }

    @MainActor final class Coordinator: NSObject {
        var parent: ModePicker
        private var chosen: (distribution: NSSegmentedControl.Distribution, size: CGFloat) = (.fillEqually, NSFont.systemFontSize(for: .small))
        private var chosenWidth: CGFloat = -1
        init(_ parent: ModePicker) { self.parent = parent }

        /// Width of the label text at a size, in the bold weight of a selected segment.
        private func textWidth(_ label: String, size: CGFloat) -> CGFloat {
            ceil((label as NSString).size(withAttributes: [.font: NSFont.boldSystemFont(ofSize: size)]).width)
        }

        func layout(forWidth available: CGFloat) {
            guard abs(available - chosenWidth) > 0.5 else { return }
            chosenWidth = available
            // Real label widths (not character counts) plus the segment's own padding; never below 10 pt.
            let segmentPadding: CGFloat = 18
            let labels = MeetingsModel.Mode.allCases.map(\.label)
            let sizes: [CGFloat] = [NSFont.systemFontSize(for: .small), 10.5, 10]
            var result = (distribution: NSSegmentedControl.Distribution.fillEqually, size: sizes[0])
            search: for size in sizes {
                let widths = labels.map { textWidth($0, size: size) + segmentPadding }
                let equal = (widths.max() ?? 0) * CGFloat(widths.count)
                let proportional = widths.reduce(0, +)
                if equal <= available { result = (.fillEqually, size); break search }
                if proportional <= available { result = (.fillProportionally, size); break search }
                result = (.fillProportionally, size)
            }
            chosen = result
        }

        func apply(to control: NSSegmentedControl) {
            if control.segmentDistribution != chosen.distribution { control.segmentDistribution = chosen.distribution }
            if control.font?.pointSize != chosen.size { control.font = .systemFont(ofSize: chosen.size) }
        }

        @MainActor @objc func changed(_ sender: NSSegmentedControl) {
            let modes = MeetingsModel.Mode.allCases
            guard modes.indices.contains(sender.selectedSegment) else { return }
            parent.selection = modes[sender.selectedSegment]
        }
    }
}
