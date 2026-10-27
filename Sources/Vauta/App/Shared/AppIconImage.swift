// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit

/// The app's icon from one fixed source, the bundle's icon file, at the best size for `points`.
/// `NSApp.applicationIconImage` can hand out a representation that carries a square backing plate, so no view uses it.
enum AppIconImage {
    @MainActor
    static func image(points: CGFloat) -> NSImage {
        let source = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        // Twice the points: the representation for a 2x display.
        let size = NSRect(x: 0, y: 0, width: points * 2, height: points * 2)
        guard let representation = source.bestRepresentation(for: size, context: nil, hints: nil) else { return source }
        let image = NSImage(size: NSSize(width: points, height: points))
        image.addRepresentation(representation)
        return image
    }
}
