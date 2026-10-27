// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import MLX
import Metal

/// Process-wide MLX settings. The app owns them (a later on-device language model shares them).
public enum MLXRuntime {
    /// Largest size of MLX's buffer cache. A variable-shape workload grows an unbounded cache past 5 GB (spike 9c).
    public static let cacheLimitBytes = 128 << 20

    private static let configured = ConfiguredOnce()

    /// Sets the cache limit, once per process.
    public static func configure() { configured.run { Memory.cacheLimit = cacheLimitBytes } }

    /// Who is using MLX now: the cache limit is process-wide, so the language model raises it only while it is loaded.
    public enum CacheProfile: Sendable { case encoderOnly, languageModel }

    /// The language model's prefill and decode reuse bigger buffers: 256 MB while it is loaded, 128 MB otherwise. The memory
    /// limit is 75% of the GPU working set, so MLX waits for buffers instead of oversubscribing.
    public static func setCacheLimit(for profile: CacheProfile) {
        switch profile {
        case .encoderOnly:
            Memory.cacheLimit = cacheLimitBytes
            // Back to the memory limit MLX had before the language model raised it.
            if let before = memoryLimits.restore() { Memory.memoryLimit = before }
        case .languageModel:
            Memory.cacheLimit = 256 << 20
            if let device = MTLCreateSystemDefaultDevice() {
                memoryLimits.remember(Memory.memoryLimit)
                Memory.memoryLimit = Int(Double(device.recommendedMaxWorkingSetSize) * 0.75)
            }
        }
    }

    private static let memoryLimits = MemoryLimitMemo()

    /// The GPU working set MLX may use, in bytes (what the load check compares with 8 GiB).
    public static var recommendedWorkingSetBytes: Int { Int(MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize ?? 0) }

    /// A GPU of the Apple7 family (M1) or later is present.
    public static var isSupported: Bool {
        #if arch(arm64)
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return device.supportsFamily(.apple7)
        #else
        return false
        #endif
    }

    public static var deviceName: String { MTLCreateSystemDefaultDevice()?.name ?? "none" }

    /// Frees MLX's cached buffers.
    public static func clearCache() { Memory.clearCache() }

    /// MLX's cached (unused) buffers, in bytes.
    public static var cacheBytes: Int { Memory.cacheMemory }

    /// Process memory as the OS accounts it (`phys_footprint` includes MLX/Metal buffers, unlike resident size), in MB.
    public static func physFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Int(info.phys_footprint >> 20) : -1
    }
}

/// The memory limit in force before the language model changed it (the first value seen, so loading twice does not forget it).
private final class MemoryLimitMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var before: Int?
    func remember(_ limit: Int) { lock.lock(); defer { lock.unlock() }; if before == nil { before = limit } }
    func restore() -> Int? { lock.lock(); defer { lock.unlock() }; defer { before = nil }; return before }
}

private final class ConfiguredOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
