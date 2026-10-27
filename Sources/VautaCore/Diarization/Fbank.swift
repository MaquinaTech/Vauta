// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Accelerate
import Foundation

/// Kaldi-style log-mel filterbank (80 bins) as the WeSpeaker / pyannote embedding front end expects it: audio
/// scaled by 32768, 25 ms Hamming window, 10 ms shift, snip edges, per-frame DC removal, 0.97 pre-emphasis,
/// 512-point FFT power spectrum, mel 20 Hz to Nyquist (Kaldi mel scale), natural log with a Float32-epsilon
/// floor. The per-window mean subtraction happens inside the Core ML embedding graph, not here.
///
/// Immutable after init and `compute` only uses local buffers, so one instance may be shared by several threads.
public final class Fbank: @unchecked Sendable {
    public static let frameLength = 400
    public static let frameShift = 160
    public static let fftSize = 512
    public static let melBins = 80
    private static let usedBins = 256        // bin 256 (Nyquist) has zero weight in the Kaldi banks

    private let window: [Float]
    private let melT: [Float]                // [usedBins x melBins] row-major, so power[n x 256] * melT = [n x 80]
    private let fft: FFTSetup
    private let log2n = vDSP_Length(9)

    public init() {
        let n = Self.frameLength
        window = (0..<n).map { Float(0.54 - 0.46 * cos(2.0 * Double.pi * Double($0) / Double(n - 1))) }
        melT = Self.melFilterbankTransposed()
        fft = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    /// Number of frames for `samples` samples (snip edges).
    public static func frameCount(samples: Int) -> Int { samples < frameLength ? 0 : 1 + (samples - frameLength) / frameShift }

    /// `[frames x 80]` row-major log-mel features of audio in [-1, 1].
    public func compute(_ audio: [Float]) -> [Float] {
        audio.withUnsafeBufferPointer { compute($0) }
    }

    public func compute(_ audio: UnsafeBufferPointer<Float>) -> [Float] {
        let nFrames = Self.frameCount(samples: audio.count)
        guard nFrames > 0, let samples = audio.baseAddress else { return [] }
        let bins = Self.usedBins, nfft = Self.fftSize, flen = Self.frameLength
        var power = [Float](repeating: 0, count: nFrames * bins)
        var frame = [Float](repeating: 0, count: nfft)
        var re = [Float](repeating: 0, count: nfft / 2)
        var im = [Float](repeating: 0, count: nfft / 2)
        var scale: Float = 32768
        var scaled = [Float](repeating: 0, count: flen)
        var previous = [Float](repeating: 0, count: flen)
        for f in 0..<nFrames {
            // scale to 16-bit range, remove the DC offset
            vDSP_vsmul(samples + f * Self.frameShift, 1, &scale, &scaled, 1, vDSP_Length(flen))
            var mean: Float = 0
            vDSP_meanv(scaled, 1, &mean, vDSP_Length(flen))
            var negMean = -mean
            vDSP_vsadd(scaled, 1, &negMean, &scaled, 1, vDSP_Length(flen))
            // pre-emphasis y[i] = x[i] - 0.97 x[i-1], with y[0] = x[0] - 0.97 x[0]; then the window
            previous[0] = scaled[0]
            for i in 1..<flen { previous[i] = scaled[i - 1] }
            var k: Float = -0.97
            vDSP_vsma(previous, 1, &k, scaled, 1, &frame, 1, vDSP_Length(flen))
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(flen))
            for i in flen..<nfft { frame[i] = 0 }
            // Real FFT. vDSP packs DC in re[0] and Nyquist in im[0], and returns twice the DFT.
            frame.withUnsafeBufferPointer { fp in
                fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nfft / 2) { cp in
                    re.withUnsafeMutableBufferPointer { rp in
                        im.withUnsafeMutableBufferPointer { ip in
                            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(nfft / 2))
                            vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                        }
                    }
                }
            }
            let out = f * bins
            for i in 0..<bins {
                let r = re[i], m = im[i]
                // power = (r^2 + m^2) / 4; bin 0's imaginary slot holds Nyquist, which is not used
                power[out + i] = i == 0 ? (r * r) / 4 : (r * r + m * m) / 4
            }
        }
        var mel = [Float](repeating: 0, count: nFrames * Self.melBins)
        // [frames x 256] * [256 x 80]
        vDSP_mmul(power, 1, melT, 1, &mel, 1, vDSP_Length(nFrames), vDSP_Length(Self.melBins), vDSP_Length(bins))
        let floorValue = Float.ulpOfOne
        for i in 0..<mel.count { mel[i] = logf(max(mel[i], floorValue)) }
        return mel
    }

    private static func melFilterbankTransposed() -> [Float] {
        let sampleRate = 16_000.0, low = 20.0, high = 8_000.0, count = melBins, nfft = fftSize
        func mel(_ f: Double) -> Double { 1127.0 * log(1.0 + f / 700.0) }
        let binCount = nfft / 2, binWidth = sampleRate / Double(nfft)
        let melLow = mel(low), melHigh = mel(high), delta = (melHigh - melLow) / Double(count + 1)
        var t = [Float](repeating: 0, count: usedBins * count)
        for b in 0..<count {
            let left = melLow + Double(b) * delta, centre = melLow + Double(b + 1) * delta, right = melLow + Double(b + 2) * delta
            for i in 0..<min(binCount, usedBins) {
                let m = mel(binWidth * Double(i))
                let up = (m - left) / (centre - left), down = (right - m) / (right - centre)
                t[i * count + b] = Float(max(0, min(up, down)))
            }
        }
        return t
    }
}
