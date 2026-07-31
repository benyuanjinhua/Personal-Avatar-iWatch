// MacAudioCodecPipeline PoC — ESS-25
//
// decode: AAC/M4A（任何 AVAudioFile 可读格式）→ 16kHz 单声道 PCM16LE raw，
//         走 AVAudioConverter mastering 级 SRC（多相抗混叠低通滤波，非线性插值）。
// encode: raw PCM16LE mono @<rate>（24kHz audio.delta 聚合）→ AAC .m4a，
//         Watch/iPhone 可直接播放。
//
// 仅使用库 API（AVFoundation/AudioToolbox），不拼 Shell。

import AVFoundation
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("audiopipe: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func jsonOut(_ dict: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

// Decode any AVAudioFile-readable input to 16 kHz mono Int16 raw PCM.
func decode(input: String, output: String, targetRate: Double) {
    let inURL = URL(fileURLWithPath: input)
    guard let file = try? AVAudioFile(forReading: inURL) else {
        fail("cannot open input: \(input)")
    }
    let srcFormat = file.processingFormat
    guard let dstFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: targetRate,
        channels: 1,
        interleaved: true
    ) else { fail("cannot build target format") }

    guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
        fail("cannot build converter \(srcFormat) -> \(dstFormat)")
    }
    // Высококачественный SRC с анти-алиасинговым НЧ-фильтром.
    converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
    converter.sampleRateConverterQuality = .max
    converter.downmix = true

    let chunkFrames: AVAudioFrameCount = 65536
    guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: chunkFrames) else {
        fail("cannot allocate source buffer")
    }
    let ratio = targetRate / srcFormat.sampleRate
    let dstCapacity = AVAudioFrameCount((Double(chunkFrames) * ratio).rounded(.up) + 4096)

    FileManager.default.createFile(atPath: output, contents: nil)
    guard let outHandle = FileHandle(forWritingAtPath: output) else {
        fail("cannot open output: \(output)")
    }

    var eof = false
    var totalOutFrames: UInt64 = 0
    while true {
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstCapacity) else {
            fail("cannot allocate destination buffer")
        }
        var conversionError: NSError?
        let status = converter.convert(to: dstBuffer, error: &conversionError) { _, outStatus in
            if eof {
                outStatus.pointee = .endOfStream
                return nil
            }
            do {
                srcBuffer.frameLength = 0
                try file.read(into: srcBuffer, frameCount: chunkFrames)
            } catch {
                eof = true
                outStatus.pointee = .endOfStream
                return nil
            }
            if srcBuffer.frameLength == 0 {
                eof = true
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return srcBuffer
        }
        if let conversionError { fail("conversion error: \(conversionError.localizedDescription)") }
        if dstBuffer.frameLength > 0, let channel = dstBuffer.int16ChannelData {
            let byteCount = Int(dstBuffer.frameLength) * MemoryLayout<Int16>.size
            outHandle.write(Data(bytes: channel[0], count: byteCount))
            totalOutFrames += UInt64(dstBuffer.frameLength)
        }
        if status == .endOfStream || (eof && dstBuffer.frameLength == 0) { break }
        if status == .error { fail("converter returned error status") }
    }
    outHandle.closeFile()

    jsonOut([
        "op": "decode",
        "input": input,
        "inputSampleRate": srcFormat.sampleRate,
        "inputChannels": Int(srcFormat.channelCount),
        "outputSampleRate": targetRate,
        "outputChannels": 1,
        "outputFrames": totalOutFrames,
        "outputSeconds": Double(totalOutFrames) / targetRate,
        "resampler": "AVSampleRateConverterAlgorithm_Mastering/max",
    ])
}

// Wrap raw PCM16LE mono @sourceRate into an AAC .m4a container.
func encode(input: String, sourceRate: Double, output: String) {
    guard let raw = FileManager.default.contents(atPath: input) else {
        fail("cannot read input: \(input)")
    }
    let frameCount = raw.count / MemoryLayout<Int16>.size
    guard frameCount > 0 else { fail("input is empty") }

    guard let pcmFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sourceRate,
        channels: 1,
        interleaved: true
    ) else { fail("cannot build PCM format") }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
        fail("cannot allocate PCM buffer")
    }
    raw.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
        let src = ptr.bindMemory(to: Int16.self)
        buffer.int16ChannelData![0].update(from: src.baseAddress!, count: frameCount)
    }
    buffer.frameLength = AVAudioFrameCount(frameCount)

    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sourceRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64000,
    ]
    let outURL = URL(fileURLWithPath: output)
    try? FileManager.default.removeItem(at: outURL)
    do {
        let outFile = try AVAudioFile(
            forWriting: outURL,
            settings: settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        try outFile.write(from: buffer)
    } catch {
        fail("encode error: \(error.localizedDescription)")
    }

    jsonOut([
        "op": "encode",
        "input": input,
        "sourceRate": sourceRate,
        "frames": frameCount,
        "seconds": Double(frameCount) / sourceRate,
        "output": output,
        "codec": "aac-lc 64kbps mono (AVAudioFile/AudioToolbox)",
    ])
}

let args = CommandLine.arguments
switch args.count >= 2 ? args[1] : "" {
case "decode":
    guard args.count == 4 || args.count == 5 else {
        fail("usage: audiopipe decode <in.m4a> <out.raw> [targetRate=16000]")
    }
    decode(input: args[2], output: args[3], targetRate: args.count == 5 ? Double(args[4]) ?? 16000 : 16000)
case "encode":
    guard args.count == 5 else {
        fail("usage: audiopipe encode <in.raw> <sourceRate> <out.m4a>")
    }
    guard let rate = Double(args[3]) else { fail("bad sourceRate") }
    encode(input: args[2], sourceRate: rate, output: args[4])
default:
    fail("usage: audiopipe decode|encode ...")
}
