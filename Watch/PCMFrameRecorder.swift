import AVFoundation
import Foundation

/// ESS-321 microphone tap that produces continuous 16 kHz mono PCM16 frames
/// during recording — the streaming path can no longer wait for the full M4A
/// to finish. Runs alongside the existing `AudioRecorder` (which keeps the
/// AAC file on disk as the one-shot fallback body).
///
/// Design goals:
///
///  * emit frames every ~100 ms so the bridge sees continuous audio
///  * resample the microphone's native rate down to 16 kHz mono PCM16
///  * emit strictly monotonic frames — the coordinator assigns sequence
///  * refuse to start twice; refuse to emit after stop
///
/// Real-device acceptance for this class is scoped to ESS-265 (per the R-02
/// runtime-evidence rule); this file provides deterministic client code that
/// the coordinator can drive from a simulated microphone stream in tests.
@MainActor
final class PCMFrameRecorder: WatchRealtimeMediaAdapter.Recorder {
    struct Configuration {
        var format: RealtimeMediaFormat
        var frameDurationMs: Int

        init(format: RealtimeMediaFormat = .uplinkPCM16, frameDurationMs: Int = 100) {
            self.format = format
            self.frameDurationMs = frameDurationMs
        }
    }

    private let configuration: Configuration
    private let audioEngine: AVAudioEngine
    private let tapBus: AVAudioNodeBus
    /// ESS-554：`.conversation` 时引擎生命周期归 ConversationAudioController
    /// （会话级一次性起停），本类每回合只装卸 tap；`.turn` 为旧路径
    /// （每回合 prepare+start / stop）。运行期动态读取，出厂默认旧路径。
    private let lifecycleOwner: () -> RealtimeAudioLifecycleOwner
    private var converter: AVAudioConverter?
    private var isRunning = false
    private var accumulated = Data()

    /// Emits each fully-formed frame. Set by the coordinator wiring.
    var onFrame: ((Data) -> Void)?
    /// Emits when the tap detects the recorder cannot deliver audio for the
    /// negotiated format — the coordinator treats this as a transport-failure
    /// signal and hands off to the one-shot fallback.
    var onFailure: ((Error) -> Void)?

    init(configuration: Configuration = Configuration(), audioEngine: AVAudioEngine = AVAudioEngine(), bus: AVAudioNodeBus = 0,
         lifecycleOwner: @escaping () -> RealtimeAudioLifecycleOwner = { .turn }) {
        self.configuration = configuration
        self.audioEngine = audioEngine
        self.tapBus = bus
        self.lifecycleOwner = lifecycleOwner
    }

    var frameByteSize: Int {
        configuration.format.bytes(forMilliseconds: configuration.frameDurationMs)
    }

    /// ESS-362: `installTap(onBus:bufferSize:format:)` throws an uncatchable
    /// Objective-C exception when the input format is invalid — most commonly
    /// when the shared `AVAudioSession` hasn't been configured for
    /// `.playAndRecord`. `inputNode.outputFormat` then reports a 0-channel /
    /// 0-Hz format, `bufferSize` computes to 0, and the ObjC precondition
    /// terminates the app before any Swift `throw`/`catch` can save it. This
    /// helper converts the invalid state into a real Swift error the adapter
    /// can catch and fall back on. The check is deliberately conservative
    /// (channels + sample rate + non-zero buffer size) — every failure mode we
    /// observed on device passes at least one of the three.
    static func inputFormatValidationError(
        format: AVAudioFormat, bufferSize: AVAudioFrameCount
    ) -> Error? {
        if format.channelCount == 0 {
            return NSError(domain: "PCMFrameRecorder", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Input node reports 0 channels — audio session not configured for recording"
            ])
        }
        if format.sampleRate <= 0 {
            return NSError(domain: "PCMFrameRecorder", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Input node reports invalid sample rate \(format.sampleRate)"
            ])
        }
        if bufferSize == 0 {
            return NSError(domain: "PCMFrameRecorder", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Computed tap buffer size is 0"
            ])
        }
        return nil
    }

    func start() throws {
        guard !isRunning else { return }
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: tapBus)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(configuration.format.sampleRate),
            channels: AVAudioChannelCount(configuration.format.channelCount),
            interleaved: true
        ) else {
            throw NSError(domain: "PCMFrameRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unable to build target format"
            ])
        }
        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate / 10) // ~100 ms
        if let error = Self.inputFormatValidationError(format: inputFormat, bufferSize: bufferSize) {
            throw error
        }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.installTap(onBus: tapBus, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            Task { @MainActor in self?.consume(buffer: buffer, targetFormat: targetFormat) }
        }
        // ESS-554：会话级模式下引擎由 ConversationAudioController 在
        // acquire 时启动并跨回合保持运行——此处只在它不在跑时兜底启动
        // （例如首回合与 acquire 竞态），绝不在回合边界起停引擎。
        let conversationOwned = lifecycleOwner() == .conversation
        if conversationOwned, audioEngine.isRunning {
            // 引擎已在跑：tap 装上即开始产出帧，无引擎启动开销。
        } else {
            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                inputNode.removeTap(onBus: tapBus)
                converter = nil
                throw error
            }
        }
        isRunning = true
        accumulated.removeAll(keepingCapacity: true)
    }

    func stop() {
        guard isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: tapBus)
        // ESS-554：会话级模式下回合结束只摘 tap（AI 回答期间无上行帧），
        // 引擎与会话都由 ConversationAudioController 继续持有。
        if lifecycleOwner() == .turn {
            audioEngine.stop()
        }
        converter = nil
        isRunning = false
        if !accumulated.isEmpty {
            onFrame?(accumulated)
            accumulated.removeAll(keepingCapacity: false)
        }
    }

    private func consume(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }
        var providedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if providedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            providedInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let error = conversionError {
            onFailure?(error)
            return
        }
        guard status != .error, output.frameLength > 0 else { return }
        let byteCount = Int(output.frameLength) * Int(targetFormat.streamDescription.pointee.mBytesPerFrame)
        guard let bytes = output.int16ChannelData?.pointee else { return }
        let payload = Data(bytes: bytes, count: byteCount)
        accumulated.append(payload)
        let target = frameByteSize
        while accumulated.count >= target {
            let head = accumulated.prefix(target)
            accumulated.removeFirst(target)
            onFrame?(Data(head))
        }
    }
}
