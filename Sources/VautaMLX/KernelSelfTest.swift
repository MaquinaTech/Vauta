// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import MLX
import MLXFFT
import MLXFast
import MLXNN

/// What a self-test run found. Counts, timings and the device name only: no content.
public struct SelfTestReport: Sendable, Equatable {
    public var total = 0
    public var passed = 0
    public var failed: [String] = []
    public var seconds: Double = 0
    /// Seconds the very first check took (it compiles the kernels it needs).
    public var firstCheckSeconds: Double = 0
    public var deviceName = ""
    public var ok: Bool { total > 0 && failed.isEmpty }
}

/// Numeric GPU-versus-CPU checks of the kernel families the encoder (and a later language model) uses. The kernels are
/// compiled from embedded sources at run time (no metallib), so this proves they compile and compute the right thing in
/// this build, on this Mac. The 59 checks exercise all 9 embedded kernel groups (arg_reduce, conv, dot, layer_norm, random,
/// rms_norm, rope, scaled_dot_product_attention, fence). The CPU reference of an f16 softmax is inaccurate, so softmax is
/// compared against an f32 CPU reference.
public enum KernelSelfTest {
    public enum Scope: Sendable {
        /// All the checks.
        case full
        /// The checks that cover the ops of the text encoder (about 0.3 s once the kernels are compiled).
        case encoder
        /// The checks of the language model's ops (4-bit matmul, proportional RoPE, head dimensions 256 and 512, windowed masks,
        /// the soft cap, top-k, sampling).
        case llm
    }

    public static func run(_ scope: Scope = .full) -> SelfTestReport {
        MLXRuntime.configure()
        var report = SelfTestReport()
        report.deviceName = MLXRuntime.deviceName
        let t0 = Date()
        var first = true
        func record(_ name: String, _ ok: Bool, started: Date) {
            report.total += 1
            if ok { report.passed += 1 } else { report.failed.append(name) }
            if first { report.firstCheckSeconds = Date().timeIntervalSince(started); first = false }
        }
        func cmp(_ name: String, _ tags: Set<String> = [], tol: Float, ref: (() -> MLXArray)? = nil, _ f: () -> MLXArray) {
            if scope == .encoder, !tags.contains("encoder") { return }
            if scope == .llm, !tags.contains("llm") { return }
            if scope != .llm, tags.contains("llm") { return }   // the language model's checks run only in their own scope
            let started = Date()
            let g = Device.withDefaultDevice(.gpu) { () -> MLXArray in
                let r = f().asType(.float32)
                eval(r)
                return r
            }
            let c = Device.withDefaultDevice(.cpu) { () -> MLXArray in
                let r = (ref?() ?? f()).asType(.float32)
                eval(r)
                return r
            }
            let scale = max(c.abs().max().item(Float.self), 1e-6)
            let bad = (g - c).abs().max().item(Float.self)
            let nan = isNaN(g).any().item(Bool.self)
            if ProcessInfo.processInfo.environment["VAUTA_SELFTEST_VERBOSE"] != nil { print("  \(name): relative error \(bad / scale) (limit \(tol))") }
            record(name, !nan && bad / scale <= tol && g.shape == c.shape, started: started)
        }
        MLXRandom.seed(7)
        func R(_ s: [Int], _ dt: DType = .float16) -> MLXArray {
            let x = MLXRandom.normal(s).asType(dt)
            eval(x)
            return x
        }
        let H: Float = 4e-3, F: Float = 2e-5
        let E: Set<String> = ["encoder"]

        do { let a = R([128, 1024]), b = R([1024, 1024]); cmp("gemm f16", E, tol: H) { matmul(a, b) } }
        do { let a = R([128, 1024], .float32), b = R([1024, 1024], .float32); cmp("gemm f32", E, tol: F * 5) { matmul(a, b) } }
        do { let a = R([128, 1024], .bfloat16), b = R([1024, 1024], .bfloat16); cmp("gemm bf16", tol: 2e-2) { matmul(a, b) } }
        do { let a = R([1, 1024]), b = R([1024, 2048]); cmp("gemv f16 (x @ W)", E, tol: H) { matmul(a, b) } }
        do { let a = R([2048, 1024]), b = R([1024, 1]); cmp("gemv f16 (W @ x)", tol: H) { matmul(a, b) } }
        do { let a = R([4, 2048, 512]), b = R([4, 512, 64]); cmp("batched gemm f16", E, tol: H) { matmul(a, b) } }
        do { let a = R([1, 1000]), b = R([1000, 1]); cmp("dot f16", tol: H) { matmul(a, b) } }
        do { let a = R([1, 5000], .float32), b = R([5000, 1], .float32); cmp("dot f32", tol: F * 5) { matmul(a, b) } }
        do { let a = R([1, 3000], .bfloat16), b = R([3000, 1], .bfloat16); cmp("dot bf16", tol: 2e-2) { matmul(a, b) } }
        do {
            let w = R([2048, 1024]), x1 = R([1, 1024]), x8 = R([128, 1024])
            for bits in [4, 8] {
                let (wq, sc, bi) = quantized(w, groupSize: 64, bits: bits)
                eval([wq, sc] + (bi.map { [$0] } ?? []))
                cmp("qmv \(bits)-bit", tol: H) { quantizedMM(x1, wq, scales: sc, biases: bi, transpose: true, groupSize: 64, bits: bits) }
                cmp("qmm \(bits)-bit", tol: H) { quantizedMM(x8, wq, scales: sc, biases: bi, transpose: true, groupSize: 64, bits: bits) }
            }
        }
        do { let x = R([8, 4096]), w = R([4096]); cmp("rms_norm f16 single row", E, tol: H) { MLXFast.rmsNorm(x, weight: w, eps: 1e-6) } }
        do { let x = R([4, 16384]), w = R([16384]); cmp("rms_norm f16 looped", tol: H) { MLXFast.rmsNorm(x, weight: w, eps: 1e-6) } }
        do { let x = R([8, 4096], .float32), w = R([4096], .float32); cmp("rms_norm f32", E, tol: F * 5) { MLXFast.rmsNorm(x, weight: w, eps: 1e-6) } }
        do { let x = R([8, 4096]), w = R([4096]), b = R([4096]); cmp("layer_norm f16 w+b", tol: H) { MLXFast.layerNorm(x, weight: w, bias: b, eps: 1e-5) } }
        do { let x = R([4, 16384]), w = R([16384]); cmp("layer_norm f16 looped", tol: H) { MLXFast.layerNorm(x, weight: w, bias: nil, eps: 1e-5) } }
        do { let x = R([1, 8, 1, 128]); cmp("rope decode offset", tol: H) { MLXFast.RoPE(x, dimensions: 128, traditional: false, base: 10000, scale: 1, offset: 37) } }
        do { let x = R([2, 8, 64, 128]); cmp("rope prefill", E, tol: H) { MLXFast.RoPE(x, dimensions: 128, traditional: false, base: 10000, scale: 1, offset: 0) } }
        do { let x = R([2, 8, 64, 128]); cmp("rope traditional partial", tol: H) { MLXFast.RoPE(x, dimensions: 64, traditional: true, base: 500000, scale: 0.5, offset: 5) } }
        do { let q = R([1, 8, 1, 128]), k = R([1, 2, 512, 128]), v = R([1, 2, 512, 128]); cmp("sdpa vector GQA", tol: H) { MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: 0.088, mask: nil) } }
        do { let q = R([1, 8, 1, 128]), k = R([1, 2, 8192, 128]), v = R([1, 2, 8192, 128]); cmp("sdpa 2-pass", tol: H) { MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: 0.088, mask: nil) } }
        do { let q = R([1, 8, 512, 128]), k = R([1, 2, 512, 128]), v = R([1, 2, 512, 128]); cmp("sdpa steel causal", tol: H) { MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: 0.088, mask: .causal) } }
        do { let q = R([2, 4, 300, 64]), k = R([2, 4, 300, 64]), v = R([2, 4, 300, 64]); cmp("sdpa steel no mask", E, tol: H) { MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: 0.125, mask: nil) } }
        do {
            let q = R([2, 4, 300, 64]), k = R([2, 4, 300, 64]), v = R([2, 4, 300, 64]), m = R([300, 300])
            cmp("sdpa steel additive mask", E, tol: H) { MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: 0.125, mask: .array(m)) }
        }
        // The ops the encoder runs beyond the ones above: full-attention layers (head dimensions 256 and 512) with a boolean
        // key-padding mask, the GELU of the MLP and of the per-layer inputs, the reductions of pooling and normalisation, the
        // non-finite check and the casts between the checkpoint's bf16 and the compute dtype.
        for hd in [256, 512] {
            let q = R([2, 4, 48, hd]), k = R([2, 4, 48, hd]), v = R([2, 4, 48, hd])
            let valid = MLXArray((0..<(2 * 48)).map { $0 % 48 < 37 }).reshaped([2, 1, 1, 48])
            cmp("sdpa bool key-padding mask hd\(hd)", E, tol: H) { MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: 1.0, mask: valid) }
        }
        do { let x = R([8, 1024]); cmp("gelu approximate f16", E, tol: H) { geluApproximate(x) } }
        do { let x = R([4, 64, 768]); cmp("sum and mean over an axis f16", E, tol: H) { x.sum(axis: 1) + x.mean(axis: 1) } }
        do { let x = R([4, 256], .float32); cmp("isNaN or isInf, any", E, tol: 0) { logicalOr(isNaN(x), isInf(x)).any(axis: -1).asType(.float32) } }
        do { let x = R([8, 1024], .bfloat16); cmp("cast bf16 to f16 and back", E, tol: 1e-2) { x.asType(.float16).asType(.bfloat16) } }
        do { let q = R([1, 8, 1, 256], .float32), k = R([1, 2, 1000, 256], .float32), v = R([1, 2, 1000, 256], .float32); cmp("sdpa vector f32 hd256", tol: F * 10) { MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: 0.0625, mask: nil) } }
        do { let x = R([4, 32000]); cmp("argmax f16", tol: 0) { argMax(x, axis: -1).asType(.float32) } }
        do { let x = R([4, 32000], .float32); cmp("argmin f32", tol: 0) { argMin(x, axis: -1).asType(.float32) } }
        do { let x = R([2, 20000], .float32); cmp("argsort f32", tol: 0) { argSort(x, axis: -1).asType(.float32) } }
        do { let x = R([2, 20000], .float32); cmp("sort f32", tol: 0) { sorted(x, axis: -1) } }
        do { let x = R([4, 32000], .float32); cmp("cumsum f32", tol: 1e-4) { cumsum(x, axis: -1) } }
        do {
            let x = R([4, 32000])
            cmp("softmax f16 against f32 reference", E, tol: H, ref: { softmax(x.asType(.float32), axis: -1) }) { softmax(x, axis: -1) }
            cmp("softmax f16 precise", tol: H) { softmax(x, axes: [-1], precise: true) }
            cmp("logsumexp f16", tol: H) { logSumExp(x, axis: -1) }
        }
        do {
            let t = R([32000, 256], .float32), idx = MLXArray((0..<64).map { Int32($0 * 311 % 32000) })
            cmp("gather rows", E, tol: 0) { t[idx] }
        }
        do {
            let t = R([1000, 64], .float32), idx = MLXArray((0..<100).map { Int32($0 * 7 % 1000) }), u = R([100, 64], .float32)
            cmp("scatter rows", tol: 1e-5) { let z = t; z[idx] = u; return z }
        }
        do { let x = R([1024], .float32); cmp("fft", tol: 1e-4) { MLXFFT.fft(x).abs() } }
        do { let k = MLXRandom.key(42); cmp("random uniform", tol: 0) { MLXRandom.uniform(0 ..< 1, [100000], key: k) } }
        do { let k = MLXRandom.key(9); cmp("random normal", tol: 1e-5) { MLXRandom.normal([50001], key: k) } }
        do { let k = MLXRandom.key(3), lg = R([4, 32000], .float32); cmp("categorical", tol: 0) { MLXRandom.categorical(lg, key: k).asType(.float32) } }
        do { let x = R([1, 100, 16]), w = R([32, 3, 16]); cmp("conv1d f16", tol: H) { conv1d(x, w) } }
        do { let x = R([2, 200, 32], .float32), w = R([64, 5, 32], .float32); cmp("conv1d f32 strided dilated", tol: F * 10) { conv1d(x, w, stride: 2, padding: 2, dilation: 2) } }
        do { let x = R([2, 200, 32]), w = R([32, 4, 1]); cmp("depthwise conv1d", tol: H) { conv1d(x, w, groups: 32) } }
        do { let x = R([2, 200, 32], .float32), w = R([64, 3, 8], .float32); cmp("grouped conv1d", tol: F * 10) { conv1d(x, w, groups: 4) } }
        do { let x = R([1, 32, 32, 16]), w = R([32, 3, 3, 16]); cmp("conv2d f16", tol: H) { conv2d(x, w, padding: 1) } }
        do { let x = R([1, 64, 64, 64]), w = R([64, 3, 3, 64]); cmp("conv2d winograd", tol: 8e-3) { conv2d(x, w, padding: 1) } }
        do { let x = R([1, 17, 19, 8], .float32), w = R([12, 5, 3, 8], .float32); cmp("conv2d f32 odd", tol: F * 10) { conv2d(x, w, stride: [2, 2], padding: [1, 2]) } }
        do { let x = R([1, 32, 32, 16]), w = R([16, 3, 3, 1]); cmp("depthwise conv2d", tol: H) { conv2d(x, w, padding: 1, groups: 16) } }
        do { let x = R([1, 8, 12, 12, 4], .float32), w = R([6, 3, 3, 3, 4], .float32); cmp("conv3d", tol: F * 10) { conv3d(x, w, padding: 1) } }
        do { let x = R([1, 50, 8], .float32), w = R([6, 3, 8], .float32); cmp("conv transpose 1d", tol: F * 10) { convTransposed1d(x, w, stride: 2) } }
        do { let x = R([1, 12, 12, 8], .float32), w = R([6, 3, 3, 8], .float32); cmp("conv transpose 2d", tol: F * 10) { convTransposed2d(x, w, stride: [2, 2]) } }
        // The language model (Gemma 4 E4B, 4-bit): bf16 activations, group 64.
        let L: Set<String> = ["llm"]
        let B: Float = 3e-2
        do {
            let w = R([512, 2560], .bfloat16), x1 = R([1, 2560], .bfloat16), x8 = R([32, 2560], .bfloat16)
            let (wq, sc, bi) = quantized(w, groupSize: 64, bits: 4)
            eval([wq, sc] + (bi.map { [$0] } ?? []))
            // The reference is dequantise then an fp32 product: the CPU kernel accumulates a bf16 product in bf16, which is the
            // inaccurate side of this comparison (as with the f16 softmax above).
            func ref(_ x: MLXArray, _ w: MLXArray, _ s: MLXArray, _ b: MLXArray?) -> () -> MLXArray {
                { matmul(x.asType(.float32), dequantized(w, scales: s, biases: b, groupSize: 64, bits: 4).asType(.float32).T) }
            }
            cmp("llm qmv 4-bit bf16 g64", L, tol: B, ref: ref(x1, wq, sc, bi)) { quantizedMM(x1, wq, scales: sc, biases: bi, transpose: true, groupSize: 64, bits: 4) }
            cmp("llm qmm 4-bit bf16 g64 (prefill chunk)", L, tol: B, ref: ref(x8, wq, sc, bi)) { quantizedMM(x8, wq, scales: sc, biases: bi, transpose: true, groupSize: 64, bits: 4) }
            let ids = MLXArray((0..<40).map { Int32($0 * 61 % 512) })
            cmp("llm dequantize gathered rows", L, tol: B) { dequantized(wq[ids], scales: sc[ids], biases: bi![ids], groupSize: 64, bits: 4) }
            let tied = R([2048, 2560], .bfloat16)
            let (tq, ts, tb) = quantized(tied, groupSize: 64, bits: 4)
            eval([tq, ts] + (tb.map { [$0] } ?? []))
            cmp("llm tied head qmv (2048 rows)", L, tol: B, ref: { matmul(x1.asType(.float32), dequantized(tq, scales: ts, biases: tb, groupSize: 64, bits: 4).asType(.float32).T) }) { quantizedMM(x1, tq, scales: ts, biases: tb, transpose: true, groupSize: 64, bits: 4) }
        }
        do {
            // Proportional RoPE: 64 rotated pairs of a 512-dimension head, the rest left alone (frequency infinity).
            var f = [Float](repeating: .infinity, count: 256)
            for i in 0..<64 { f[i] = Float(pow(1_000_000.0, Double(2 * i) / 512.0)) }
            let freqs = MLXArray(f)
            let x = R([1, 8, 16, 512], .bfloat16), y = R([1, 2, 1, 512], .bfloat16)
            cmp("llm rope proportional freqs prefill", L, tol: B) { MLXFast.RoPE(x, dimensions: 512, traditional: false, base: nil, scale: 1, offset: 0, freqs: freqs) }
            cmp("llm rope proportional freqs offset", L, tol: B) { MLXFast.RoPE(y, dimensions: 512, traditional: false, base: nil, scale: 1, offset: 1234, freqs: freqs) }
            let z = R([1, 8, 16, 256], .bfloat16)
            cmp("llm rope default hd256 offset", L, tol: B) { MLXFast.RoPE(z, dimensions: 256, traditional: false, base: 10000, scale: 1, offset: 700) }
        }
        for hd in [256, 512] {
            let q1 = R([1, 8, 1, hd], .bfloat16), k = R([1, 2, 700, hd], .bfloat16), v = R([1, 2, 700, hd], .bfloat16)
            cmp("llm sdpa vector decode hd\(hd)", L, tol: B, ref: { MLXFast.scaledDotProductAttention(queries: q1.asType(.float32), keys: k.asType(.float32), values: v.asType(.float32), scale: 1.0, mask: nil) }) { MLXFast.scaledDotProductAttention(queries: q1, keys: k, values: v, scale: 1.0, mask: nil) }
            let q = R([1, 8, 64, hd], .bfloat16), k2 = R([1, 2, 200, hd], .bfloat16), v2 = R([1, 2, 200, hd], .bfloat16)
            cmp("llm sdpa causal chunk with cache hd\(hd)", L, tol: B) { MLXFast.scaledDotProductAttention(queries: q, keys: k2, values: v2, scale: 1.0, mask: .causal) }
            let rows = (MLXArray(0..<Int32(64)) + Int32(136)).reshaped([64, 1]), cols = MLXArray(0..<Int32(200)).reshaped([1, 200])
            let window = logicalAnd(rows .>= cols, (rows - cols) .< Int32(100))
            cmp("llm sdpa windowed bool mask hd\(hd)", L, tol: B) { MLXFast.scaledDotProductAttention(queries: q, keys: k2, values: v2, scale: 1.0, mask: .array(window)) }
        }
        do { let x = R([1, 1, 65_536], .bfloat16); cmp("llm tanh soft cap", L, tol: B) { tanh(x / MLXArray(Float(30)).asType(.bfloat16)) * MLXArray(Float(30)).asType(.bfloat16) } }
        do {
            let x = R([65_536], .float32)
            cmp("llm top-k partition (k = 64)", L, tol: 0) { sorted(x[argPartition(-x, kth: 63)[0..<64]], axis: -1) }
            cmp("llm argmax of a vocabulary", L, tol: 0) { argMax(x).asType(.float32) }
        }
        do { let x = R([20, 64], .bfloat16); cmp("llm gelu approximate and product bf16", L, tol: B) { geluApproximate(x) * x } }
        do {
            // Categorical sampling follows its distribution: 20,000 draws from three tokens.
            let started = Date()
            let g = Device.withDefaultDevice(.gpu) { () -> Bool in
                let logits = MLXArray([Float(log(0.5)), Float(log(0.3)), Float(log(0.2))])
                let draws = MLXRandom.categorical(broadcast(logits, to: [20_000, 3]), key: MLXRandom.key(5))
                let counts = (0..<3).map { c in (draws .== Int32(c)).asType(.float32).mean().item(Float.self) }
                return abs(counts[0] - 0.5) < 0.02 && abs(counts[1] - 0.3) < 0.02 && abs(counts[2] - 0.2) < 0.02
            }
            if scope == .llm { record("llm categorical sampling distribution", g, started: started) }
        }
        if scope == .full {
            // A chain across streams (the fence kernels when fast synchronisation is on).
            let started = Date()
            let a = R([512, 512], .float32)
            let g = Device.withDefaultDevice(.gpu) { () -> MLXArray in
                let u = matmul(a, a)
                let c = Device.withDefaultDevice(.cpu) { matmul(u, a) }
                let r = matmul(c, a)
                eval(r)
                return r
            }
            let c = Device.withDefaultDevice(.cpu) { () -> MLXArray in
                let r = matmul(matmul(matmul(a, a), a), a)
                eval(r)
                return r
            }
            record("cross-stream chain", (g - c).abs().max().item(Float.self) / c.abs().max().item(Float.self) < 1e-4, started: started)
        }
        report.seconds = Date().timeIntervalSince(t0)
        return report
    }

    /// Runs `count` matrix products and attention calls of random shapes, the load that grows MLX's buffer cache when it is
    /// not bounded (used by the cache-limit test).
    public static func exerciseRandomShapes(count: Int) {
        MLXRuntime.configure()
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<count {
            let m = Int.random(in: 8...160, using: &rng), k = Int.random(in: 8...160, using: &rng), n = Int.random(in: 8...160, using: &rng)
            let product = matmul(MLXRandom.normal([m, k]).asType(.float16), MLXRandom.normal([k, n]).asType(.float16))
            let t = Int.random(in: 8...200, using: &rng)
            let q = MLXRandom.normal([1, 4, t, 64]).asType(.float16)
            let attention = MLXFast.scaledDotProductAttention(queries: q, keys: q, values: q, scale: 0.125, mask: nil)
            eval(product, attention)
        }
    }
}
