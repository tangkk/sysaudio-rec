import Foundation
import ScreenCaptureKit
import CoreMedia
import AudioToolbox
import Darwin

enum RecorderError: Error, CustomStringConvertible {
    case ffmpegNotFound
    case noDisplay
    case unsupportedAudioFormat(String)
    case invalidOutputPath(String)
    case unsupportedOS
    case missingOptionValue(String)
    case unknownArgument(String)
    case ffmpegFailed(Int32)
    case outputFileMissing(String)
    case outputFileEmpty(String)

    var description: String {
        switch self {
        case .ffmpegNotFound:
            return "ffmpeg was not found in PATH. Install it with: brew install ffmpeg"
        case .noDisplay:
            return "No display is available for ScreenCaptureKit capture."
        case .unsupportedAudioFormat(let details):
            return "Unsupported audio sample format: \(details)"
        case .invalidOutputPath(let path):
            return "Invalid output path: \(path)"
        case .unsupportedOS:
            return "Native route-independent system audio capture requires macOS 13 or newer."
        case .missingOptionValue(let option):
            return "Missing value for \(option)."
        case .unknownArgument(let argument):
            return "Unknown argument: \(argument)"
        case .ffmpegFailed(let status):
            return "ffmpeg exited with status \(status)."
        case .outputFileMissing(let path):
            return "Recording stopped, but no output file was created at \(path)."
        case .outputFileEmpty(let path):
            return "Recording stopped, but the output file is empty: \(path)"
        }
    }
}

struct Options {
    var outputURL: URL
    var deviceName: String?
    var listDevices = false
    var help = false
}

let defaultFallbackDeviceName = "Loopback Audio"

final class FFMpegMP3Writer {
    private let outputURL: URL
    private let process = Process()
    private let inputPipe = Pipe()
    private var started = false
    private let lock = NSLock()

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func startIfNeeded(sampleRate: Double, channels: Int) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !started else { return }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel", "error",
            "-f", "s16le",
            "-ar", String(Int(sampleRate.rounded())),
            "-ac", String(channels),
            "-i", "pipe:0",
            "-codec:a", "libmp3lame",
            "-b:a", "192k",
            "-y",
            outputURL.path
        ]
        process.standardInput = inputPipe
        try process.run()
        started = true
    }

    func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return }
        inputPipe.fileHandleForWriting.write(data)
    }

    func finish() {
        lock.lock()
        let wasStarted = started
        started = false
        lock.unlock()

        guard wasStarted else { return }
        inputPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
    }
}

final class FFMpegDeviceRecorder {
    private let deviceName: String
    private let outputURL: URL
    private let process = Process()
    private let inputPipe = Pipe()
    private var started = false

    init(deviceName: String, outputURL: URL) {
        self.deviceName = deviceName
        self.outputURL = outputURL
    }

    func start() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel", "error",
            "-thread_queue_size", "4096",
            "-use_wallclock_as_timestamps", "1",
            "-fflags", "+genpts",
            "-f", "avfoundation",
            "-i", ":\(deviceName)",
            "-map", "0:a:0",
            "-vn",
            "-af", "aresample=async=1000:first_pts=0",
            "-ar", "48000",
            "-ac", "2",
            "-codec:a", "libmp3lame",
            "-b:a", "192k",
            "-y",
            outputURL.path
        ]
        process.standardInput = inputPipe
        try process.run()
        started = true
    }

    func stop() {
        guard started else { return }
        started = false
        inputPipe.fileHandleForWriting.write(Data("q\n".utf8))
        inputPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
    }
}

@available(macOS 13.0, *)
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let writer: FFMpegMP3Writer
    private var stream: SCStream?
    private var sampleRate: Double?
    private var channels: Int?

    init(writer: FFMpegMP3Writer) {
        self.writer = writer
    }

    func start() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw RecorderError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "sysaudio-rec.audio"))
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else {
            writer.finish()
            return
        }

        do {
            try await stream.stopCapture()
        } catch {
            fputs("warning: failed to stop capture cleanly: \(error)\n", stderr)
        }
        writer.finish()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("capture stopped: \(error)\n", stderr)
        writer.finish()
        Foundation.exit(1)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        do {
            let pcm = try convertToInterleavedInt16(sampleBuffer)
            try writer.startIfNeeded(sampleRate: pcm.sampleRate, channels: pcm.channels)
            writer.write(pcm.data)
        } catch {
            fputs("audio conversion failed: \(error)\n", stderr)
        }
    }

    private func convertToInterleavedInt16(_ sampleBuffer: CMSampleBuffer) throws -> (data: Data, sampleRate: Double, channels: Int) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw RecorderError.unsupportedAudioFormat("missing stream description")
        }

        let asbd = asbdPointer.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            throw RecorderError.unsupportedAudioFormat("formatID=\(asbd.mFormatID)")
        }

        let channelCount = Int(asbd.mChannelsPerFrame)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard channelCount > 0, frameCount > 0 else {
            return (Data(), asbd.mSampleRate, max(channelCount, 1))
        }

        var neededSize = 0
        var blockBuffer: CMBlockBuffer?
        let sizingStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &neededSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard sizingStatus == noErr, neededSize > 0 else {
            throw RecorderError.unsupportedAudioFormat("cannot size AudioBufferList, status=\(sizingStatus)")
        }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: neededSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let audioBufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: neededSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            throw RecorderError.unsupportedAudioFormat("cannot read AudioBufferList, status=\(status)")
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let flags = asbd.mFormatFlags
        let isFloat = (flags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (flags & kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = (flags & kAudioFormatFlagIsNonInterleaved) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)

        if isFloat && bitsPerChannel == 32 {
            return (
                convertFloat32(buffers: buffers, frameCount: frameCount, channelCount: channelCount, nonInterleaved: isNonInterleaved),
                asbd.mSampleRate,
                channelCount
            )
        }

        if isSignedInteger && bitsPerChannel == 16 {
            return (
                convertInt16(buffers: buffers, frameCount: frameCount, channelCount: channelCount, nonInterleaved: isNonInterleaved),
                asbd.mSampleRate,
                channelCount
            )
        }

        throw RecorderError.unsupportedAudioFormat("flags=\(flags), bits=\(bitsPerChannel), channels=\(channelCount)")
    }

    private func convertFloat32(
        buffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        channelCount: Int,
        nonInterleaved: Bool
    ) -> Data {
        var output = Data(count: frameCount * channelCount * MemoryLayout<Int16>.size)
        output.withUnsafeMutableBytes { outputBytes in
            let out = outputBytes.bindMemory(to: Int16.self)
            if nonInterleaved {
                for channel in 0..<channelCount {
                    guard channel < buffers.count,
                          let source = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for frame in 0..<frameCount {
                        out[frame * channelCount + channel] = floatToInt16(source[frame])
                    }
                }
            } else if let source = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                for index in 0..<(frameCount * channelCount) {
                    out[index] = floatToInt16(source[index])
                }
            }
        }
        return output
    }

    private func convertInt16(
        buffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        channelCount: Int,
        nonInterleaved: Bool
    ) -> Data {
        var output = Data(count: frameCount * channelCount * MemoryLayout<Int16>.size)
        output.withUnsafeMutableBytes { outputBytes in
            let out = outputBytes.bindMemory(to: Int16.self)
            if nonInterleaved {
                for channel in 0..<channelCount {
                    guard channel < buffers.count,
                          let source = buffers[channel].mData?.assumingMemoryBound(to: Int16.self) else { continue }
                    for frame in 0..<frameCount {
                        out[frame * channelCount + channel] = source[frame]
                    }
                }
            } else if let source = buffers[0].mData?.assumingMemoryBound(to: Int16.self) {
                for index in 0..<(frameCount * channelCount) {
                    out[index] = source[index]
                }
            }
        }
        return output
    }

    private func floatToInt16(_ value: Float) -> Int16 {
        let clipped = min(1.0, max(-1.0, value))
        return Int16(clipped * Float(Int16.max))
    }
}

func ffmpegIsAvailable() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["ffmpeg", "-version"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

func listAVFoundationDevices() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["ffmpeg", "-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", "dummy"]
    try process.run()
    process.waitUntilExit()
}

func defaultOutputURL() -> URL {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let filename = "system-audio-\(formatter.string(from: Date())).mp3"
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads", isDirectory: true)
        .appendingPathComponent(filename)
}

func printUsage() {
    print("""
    Usage: sysaudio-rec [options] [output-file-or-directory]

    Records audio to MP3 until Ctrl-C.

    Options:
      --device NAME      Record from an AVFoundation audio input, such as "Loopback Audio".
      --list-devices     List AVFoundation capture devices visible to ffmpeg.
      -h, --help         Show this help.

    Without --device, macOS 13 or newer uses native route-independent system
    audio capture. macOS 12 and older default to "Loopback Audio".

    If no output path is provided, a timestamped file is created in ~/Downloads.
    """)
}

func resolveOutputURL(rawPath: String?) throws -> URL {
    guard let rawPath else {
        return defaultOutputURL()
    }

    let expandedPath: String
    if rawPath == "~" {
        expandedPath = FileManager.default.homeDirectoryForCurrentUser.path
    } else if rawPath.hasPrefix("~/") {
        expandedPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(String(rawPath.dropFirst(2)))
            .path
    } else {
        expandedPath = rawPath
    }

    let url = URL(fileURLWithPath: expandedPath)
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return url.appendingPathComponent("system-audio-\(formatter.string(from: Date())).mp3")
    }

    if url.pathExtension.isEmpty {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.appendingPathComponent(defaultOutputURL().lastPathComponent)
    }

    guard url.pathExtension.lowercased() == "mp3" else {
        throw RecorderError.invalidOutputPath("output must be a .mp3 file or a directory")
    }

    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return url
}

func parseOptions(arguments: [String]) throws -> Options {
    var deviceName: String?
    var listDevices = false
    var help = false
    var outputPath: String?

    var index = 1
    while index < arguments.count {
        let argument = arguments[index]

        switch argument {
        case "-h", "--help":
            help = true
        case "--list-devices":
            listDevices = true
        case "--device":
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw RecorderError.missingOptionValue(argument)
            }
            deviceName = arguments[valueIndex]
            index += 1
        default:
            if argument.hasPrefix("-") {
                throw RecorderError.unknownArgument(argument)
            }
            if outputPath != nil {
                throw RecorderError.unknownArgument(argument)
            }
            outputPath = argument
        }

        index += 1
    }

    return Options(
        outputURL: try resolveOutputURL(rawPath: outputPath),
        deviceName: deviceName,
        listDevices: listDevices,
        help: help
    )
}

func interruptSignalSet() -> sigset_t {
    var signals = sigset_t()
    sigemptyset(&signals)
    sigaddset(&signals, SIGINT)
    return signals
}

func blockInterruptSignal() {
    var signals = interruptSignalSet()
    pthread_sigmask(SIG_BLOCK, &signals, nil)
}

func waitForInterrupt() -> Task<Void, Never> {
    Task.detached {
        var signals = interruptSignalSet()
        var receivedSignal: Int32 = 0
        sigwait(&signals, &receivedSignal)
    }
}

func validateOutputFile(_ outputURL: URL) throws {
    guard FileManager.default.fileExists(atPath: outputURL.path) else {
        throw RecorderError.outputFileMissing(outputURL.path)
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
    let size = attributes[.size] as? NSNumber
    if size?.int64Value == 0 {
        throw RecorderError.outputFileEmpty(outputURL.path)
    }
}

@main
struct Main {
    static func main() async {
        do {
            blockInterruptSignal()
            let options = try parseOptions(arguments: CommandLine.arguments)

            if options.help {
                printUsage()
                return
            }

            guard ffmpegIsAvailable() else {
                throw RecorderError.ffmpegNotFound
            }

            if options.listDevices {
                try listAVFoundationDevices()
                return
            }

            if let deviceName = options.deviceName {
                let recorder = FFMpegDeviceRecorder(deviceName: deviceName, outputURL: options.outputURL)
                let interruptTask = waitForInterrupt()

                print("Recording AVFoundation audio device '\(deviceName)' to: \(options.outputURL.path)")
                print("Press Ctrl-C to stop.")

                try recorder.start()
                await interruptTask.value
                print("\nStopping...")
                recorder.stop()
                try validateOutputFile(options.outputURL)
                print("Saved: \(options.outputURL.path)")
                return
            }

            if #available(macOS 13.0, *) {
                let writer = FFMpegMP3Writer(outputURL: options.outputURL)
                let recorder = SystemAudioRecorder(writer: writer)
                let interruptTask = waitForInterrupt()

                print("Recording system audio to: \(options.outputURL.path)")
                print("Press Ctrl-C to stop.")

                try await recorder.start()
                await interruptTask.value
                print("\nStopping...")
                await recorder.stop()
                try validateOutputFile(options.outputURL)
                print("Saved: \(options.outputURL.path)")
            } else {
                let recorder = FFMpegDeviceRecorder(deviceName: defaultFallbackDeviceName, outputURL: options.outputURL)

                print("macOS 13 native capture is unavailable; using AVFoundation audio device '\(defaultFallbackDeviceName)'.")
                print("Recording to: \(options.outputURL.path)")
                print("Press Ctrl-C to stop.")

                let interruptTask = waitForInterrupt()
                try recorder.start()
                await interruptTask.value
                print("\nStopping...")
                recorder.stop()
                try validateOutputFile(options.outputURL)
                print("Saved: \(options.outputURL.path)")
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }
}
