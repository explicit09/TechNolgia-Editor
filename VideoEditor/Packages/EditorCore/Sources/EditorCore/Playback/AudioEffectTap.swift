import Foundation
import AVFoundation
import MediaToolbox
import Accelerate

/// Creates MTAudioProcessingTap instances that apply AudioEffectChain
/// (EQ, compressor, noise gate) in real-time during playback and export.
///
/// Usage: attach the returned tap to AVMutableAudioMixInputParameters.
public enum AudioEffectTap {

    /// Create a processing tap that applies the given audio effect chain.
    /// Returns nil if the chain is empty (no active effects).
    public static func createTap(for chain: AudioEffectChain) -> MTAudioProcessingTap? {
        guard hasActiveEffects(chain) else { return nil }

        let context = TapContext(chain: chain)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: contextPtr,
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess
        )

        // macOS 26 SDK imports the out-parameter as MTAudioProcessingTap?;
        // earlier SDKs (Xcode 16.x / macOS 15.x) import it as
        // Unmanaged<MTAudioProcessingTap>?. Branch on compiler version so
        // we build cleanly on both.
        #if compiler(>=6.2)
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )

        guard status == noErr, let unwrapped = tap else {
            Unmanaged<TapContext>.fromOpaque(contextPtr).release()
            return nil
        }

        return unwrapped
        #else
        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )

        guard status == noErr, let unwrapped = tap else {
            Unmanaged<TapContext>.fromOpaque(contextPtr).release()
            return nil
        }

        return unwrapped.takeRetainedValue()
        #endif
    }

    private static func hasActiveEffects(_ chain: AudioEffectChain) -> Bool {
        chain.eq != nil || chain.compressor != nil || chain.gate != nil
    }
}

// MARK: - Tap Context

/// Holds the effect chain configuration and per-stream processing state.
private final class TapContext {
    let chain: AudioEffectChain

    // Biquad EQ state (allocated in prepare, freed in unprepare)
    var biquadSetup: vDSP.Biquad<Float>?
    var sampleRate: Double = 48000

    // Compressor envelope state
    var envelopeLevel: Float = 0

    init(chain: AudioEffectChain) {
        self.chain = chain
    }
}

// MARK: - Tap Callbacks (C-compatible)

private func tapInit(
    tap: MTAudioProcessingTap,
    clientInfo: UnsafeMutableRawPointer?,
    tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>
) {
    tapStorageOut.pointee = clientInfo
}

private func tapFinalize(tap: MTAudioProcessingTap) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<TapContext>.fromOpaque(storage).release()
}

private func tapPrepare(
    tap: MTAudioProcessingTap,
    maxFrames: CMItemCount,
    processingFormat: UnsafePointer<AudioStreamBasicDescription>
) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()
    context.sampleRate = processingFormat.pointee.mSampleRate

    // Build biquad cascade for EQ bands
    if let eq = context.chain.eq, !eq.bands.isEmpty {
        context.biquadSetup = buildBiquadCascade(
            bands: eq.bands,
            sampleRate: context.sampleRate,
            channelCount: Int(processingFormat.pointee.mChannelsPerFrame)
        )
    }
}

private func tapUnprepare(tap: MTAudioProcessingTap) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()
    context.biquadSetup = nil
    context.envelopeLevel = 0
}

private func tapProcess(
    tap: MTAudioProcessingTap,
    numberFrames: CMItemCount,
    flags: MTAudioProcessingTapFlags,
    bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
    numberFramesOut: UnsafeMutablePointer<CMItemCount>,
    flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>
) {
    // Get source audio
    var sourceFlags = MTAudioProcessingTapFlags()
    let status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut, &sourceFlags, nil, numberFramesOut
    )
    guard status == noErr else { return }

    let storage = MTAudioProcessingTapGetStorage(tap)
    let context = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()
    let chain = context.chain
    let frameCount = Int(numberFramesOut.pointee)
    guard frameCount > 0 else { return }

    // Process each channel buffer
    let bufferCount = Int(bufferListInOut.pointee.mNumberBuffers)
    withUnsafeMutablePointer(to: &bufferListInOut.pointee.mBuffers) { buffersPtr in
        let buffers = UnsafeMutableBufferPointer(start: buffersPtr, count: bufferCount)

        for i in 0..<bufferCount {
            guard let data = buffers[i].mData else { continue }
            let floatPtr = data.assumingMemoryBound(to: Float.self)
            let samples = UnsafeMutableBufferPointer(start: floatPtr, count: frameCount)

            // 1. Noise gate
            if let gate = chain.gate {
                applyNoiseGate(samples: samples, thresholdDB: gate.thresholdDB)
            }

            // 2. EQ (via biquad cascade)
            if var biquad = context.biquadSetup {
                let input = Array(samples)
                let output = biquad.apply(input: input)
                for j in 0..<frameCount {
                    samples[j] = output[j]
                }
                context.biquadSetup = biquad
            }

            // 3. Compressor
            if let comp = chain.compressor {
                applyCompressor(
                    samples: samples,
                    config: comp,
                    sampleRate: context.sampleRate,
                    envelope: &context.envelopeLevel
                )
            }
        }
    }
}

// MARK: - DSP: Noise Gate

private func applyNoiseGate(
    samples: UnsafeMutableBufferPointer<Float>,
    thresholdDB: Double
) {
    let threshold = Float(pow(10.0, thresholdDB / 20.0))
    for i in 0..<samples.count {
        if abs(samples[i]) < threshold {
            samples[i] = 0
        }
    }
}

// MARK: - DSP: Compressor

private func applyCompressor(
    samples: UnsafeMutableBufferPointer<Float>,
    config: CompressorConfig,
    sampleRate: Double,
    envelope: inout Float
) {
    let thresholdLinear = Float(pow(10.0, config.thresholdDB / 20.0))
    let ratio = Float(max(config.ratio, 1.0))
    let makeupGain = Float(pow(10.0, config.makeupGainDB / 20.0))
    let attackSec = config.attackMS / 1000.0
    let releaseSec = config.releaseMS / 1000.0
    let attackCoeff = Float(exp(-1.0 / (attackSec * sampleRate)))
    let releaseCoeff = Float(exp(-1.0 / (releaseSec * sampleRate)))

    for i in 0..<samples.count {
        let inputAbs = abs(samples[i])

        // Envelope follower
        if inputAbs > envelope {
            envelope = attackCoeff * envelope + (1 - attackCoeff) * inputAbs
        } else {
            envelope = releaseCoeff * envelope + (1 - releaseCoeff) * inputAbs
        }

        // Gain computation
        if envelope > thresholdLinear {
            let overDB = 20.0 * log10(envelope / thresholdLinear)
            let reducedDB = overDB / ratio
            let gainReduction = pow(10.0, (reducedDB - overDB) / 20.0)
            samples[i] *= gainReduction * makeupGain
        } else {
            samples[i] *= makeupGain
        }
    }
}

// MARK: - DSP: Biquad EQ

/// Build a cascaded biquad filter from EQ bands using vDSP.
private func buildBiquadCascade(
    bands: [EQBand],
    sampleRate: Double,
    channelCount: Int
) -> vDSP.Biquad<Float>? {
    // Each band needs 5 coefficients: [b0, b1, b2, a1, a2]
    var allCoeffs: [Double] = []
    for band in bands {
        let coeffs = peakingEQCoefficients(
            frequency: band.freqHz,
            gain: band.gainDB,
            q: band.q,
            sampleRate: sampleRate
        )
        allCoeffs.append(contentsOf: coeffs)
    }

    guard !allCoeffs.isEmpty else { return nil }

    let sectionCount = bands.count
    return vDSP.Biquad(
        coefficients: allCoeffs,
        channelCount: vDSP_Length(max(channelCount, 1)),
        sectionCount: vDSP_Length(sectionCount),
        ofType: Float.self
    )
}

/// Peaking EQ biquad coefficients (Audio EQ Cookbook by Robert Bristow-Johnson).
private func peakingEQCoefficients(
    frequency: Double,
    gain: Double,
    q: Double,
    sampleRate: Double
) -> [Double] {
    let A = pow(10.0, gain / 40.0)
    let w0 = 2.0 * Double.pi * frequency / sampleRate
    let sinW0 = sin(w0)
    let cosW0 = cos(w0)
    let alpha = sinW0 / (2.0 * max(q, 0.1))

    let b0 = 1.0 + alpha * A
    let b1 = -2.0 * cosW0
    let b2 = 1.0 - alpha * A
    let a0 = 1.0 + alpha / A
    let a1 = -2.0 * cosW0
    let a2 = 1.0 - alpha / A

    // Normalize by a0, output as [b0, b1, b2, a1, a2]
    return [
        b0 / a0,
        b1 / a0,
        b2 / a0,
        a1 / a0,
        a2 / a0,
    ]
}
