// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Where the suggested agenda would be written.
public enum BriefBackend: String, Sendable, Equatable, CaseIterable {
    /// Apple's on-device model (4K window).
    case apple
    /// The integrated Gemma 4 E4B.
    case integrated
    /// A model server (this Mac or the network).
    case server

    /// Items offered to the model at most.
    public var itemLimit: Int {
        switch self {
        case .apple: 12
        case .integrated: 20
        case .server: 30
        }
    }

    /// Seconds before a request is given up; only the agenda is hidden then.
    public var timeoutSeconds: Double { self == .apple ? 60 : 90 }
}

extension ContextBudget {
    /// The suggested agenda: a short answer (4 to 6 lines).
    var briefOutput: Int { isSmall ? 450 : 600 }
    /// The whole prompt (instructions and items) of the agenda: on Apple's 4K about 3,300 tokens, of which the instructions take about 650
    /// and the items (12 at about 70 tokens) about 840. A large window takes a share of its size.
    var briefInput: Int { isSmall ? contextTokens - briefOutput - safety : scaled(6_000) }
}

extension BriefPolicy {
    /// The brief leaves out the items the minutes' ranking put in "Other possible items" (Apple's model: about nine in ten of them are not
    /// real), as the Minutes tab does. Decided on 2026-10-25.
    public static let leavesOutRankedOutItems = true
}

/// What the Mac is doing, as far as a brief cares.
public struct BriefEnvironment: Sendable, Equatable {
    public var isRecording = false
    public var lowPowerMode = false
    public var thermalState: ProcessInfo.ThermalState = .nominal
    public var onBattery = false
    public var highMemoryPressure = false

    public init(isRecording: Bool = false, lowPowerMode: Bool = false, thermalState: ProcessInfo.ThermalState = .nominal,
                onBattery: Bool = false, highMemoryPressure: Bool = false) {
        self.isRecording = isRecording
        self.lowPowerMode = lowPowerMode
        self.thermalState = thermalState
        self.onBattery = onBattery
        self.highMemoryPressure = highMemoryPressure
    }
}

/// What a brief may do right now. The deterministic brief never depends on the model, and a recording
/// has priority: no new model call, not even a query embedding, is started while one runs.
public struct BriefPolicy: Sendable, Equatable {
    public enum Agenda: Sendable, Equatable {
        case run
        /// Waits until the recording ends (skipped if the event starts first).
        case waitForRecording
        case skip(Reason)
    }

    public enum Reason: String, Sendable, Equatable {
        case lowPower, thermal, notLoaded, memoryPressure, noModel
    }

    /// The brief is built at all (the Mac is not critically hot).
    public var build = true
    public var pausedForHeat = false
    /// Query and text embeddings with the search model may run; otherwise keywords rank.
    public var embeddings = true
    public var agenda = Agenda.run

    public static func decide(_ env: BriefEnvironment, backend: BriefBackend?, integratedLoaded: Bool = false) -> BriefPolicy {
        var policy = BriefPolicy()
        if env.thermalState == .critical {
            policy.build = false
            policy.pausedForHeat = true
            policy.embeddings = false
            policy.agenda = .skip(.thermal)
            return policy
        }
        if env.isRecording {
            policy.embeddings = false
            policy.agenda = .waitForRecording
            return policy
        }
        if env.lowPowerMode {
            policy.embeddings = false
            policy.agenda = .skip(.lowPower)
            return policy
        }
        if env.thermalState == .serious {
            policy.embeddings = false
            policy.agenda = .skip(.thermal)
            return policy
        }
        guard let backend else {
            policy.agenda = .skip(.noModel)
            return policy
        }
        if backend == .integrated, !integratedLoaded {
            // The model is not loaded for a brief when memory is short, nor on battery.
            if env.highMemoryPressure { policy.agenda = .skip(.memoryPressure) } else if env.onBattery { policy.agenda = .skip(.notLoaded) }
        }
        return policy
    }
}
