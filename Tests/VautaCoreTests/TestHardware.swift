// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreGraphics
import Foundation
import Metal
import Testing
@testable import VautaCore

/// What this Mac can really do, found by trying it. A virtual machine (the CI runners) may have no GPU for Metal and MLX, too little
/// memory for the integrated language model, no Vision text recognition, and no GPU utilisation counters. A test that needs one of
/// these checks it here and, when it is missing, records a warning and returns (or asserts the documented fallback). Nothing here
/// reads an environment variable: the answer is always what the machine does.
enum TestHardware {
    /// The GPU that MLX needs: a Metal device of the Apple7 family or later (the check the install path makes first).
    static var hasMLXGPU: Bool {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return device.supportsFamily(.apple7)
    }

    /// The reason the integrated language model cannot be made available on this Mac (too little memory, or no usable GPU), or nil.
    /// Installing it ends in `LanguageModelAccess.refresh`, which makes this very check.
    static var integratedModelRefusal: String? {
        hasMLXGPU ? LanguageModelGate.refusal(gpuSupported: true) : LanguageModelGate.refusal(gpuSupported: false)
    }

    /// The GPU utilisation counter of the IORegistry returns a value.
    static var hasGPUUtilisation: Bool { LLMEvaluation.gpuUtilization() != nil }

    /// Vision reads a line of large black text on white. Probed once per process.
    static func visionCanReadText() async -> Bool { await visionProbe.value }

    private static let visionProbe = Task<Bool, Never> {
        guard let image = PDFFixtures.textImage("Probe", size: CGSize(width: 600, height: 200)) else { return false }
        do { return try await VisionOCR.recognize(image).isEmpty == false } catch { return false }
    }

    /// After an install that went through: the integrated model is available when this Mac qualifies, and otherwise says why not.
    static func expectIntegratedModelAvailability(of access: LanguageModelAccess, sourceLocation: SourceLocation = #_sourceLocation) {
        if let reason = integratedModelRefusal {
            Issue.record("the integrated language model is not available on this Mac (\(reason)); checking the documented fallback",
                         severity: .warning, sourceLocation: sourceLocation)
            #expect(access.availability == .unavailable(reason), "a Mac that does not qualify gets the reason, not the model", sourceLocation: sourceLocation)
        } else {
            #expect(access.availability == .installed, sourceLocation: sourceLocation)
        }
    }

    /// True when Vision can read text here; otherwise records the skip warning.
    static func requireVision(sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        if await visionCanReadText() { return true }
        Issue.record("Vision text recognition is not available on this Mac (a probe could not read a line of text); skipping the OCR check",
                     severity: .warning, sourceLocation: sourceLocation)
        return false
    }
}
