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
    case audioDeviceNotFound(String)
    case coreAudioError(String, OSStatus)

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
        case .audioDeviceNotFound(let name):
            return "Audio input device not found: \(name)"
        case .coreAudioError(let operation, let status):
            return "\(operation) failed with CoreAudio status \(status)."
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
    private let writeQueue = DispatchQueue(label: "sysaudio-rec.ffmpeg-writer")
    private var started = false
    private let lock = NSLock()

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func startIfNeeded(sampleRate: Double, channels: Int, outputChannels: Int? = nil) throws {
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
        ]
        if let outputChannels, channels > 2, outputChannels == 2 {
            process.arguments?.append(contentsOf: ["-filter:a", "pan=stereo|c0=c0|c1=c1"])
        } else if let outputChannels {
            process.arguments?.append(contentsOf: ["-ac", String(outputChannels)])
        }
        process.arguments?.append(contentsOf: [
            "-codec:a", "libmp3lame",
            "-b:a", "192k",
            "-y",
            outputURL.path
        ])
        process.standardInput = inputPipe
        try process.run()
        started = true
    }

    func write(_ data: Data) {
        lock.lock()
        guard started else {
            lock.unlock()
            return
        }
        writeQueue.async { [inputPipe] in
            inputPipe.fileHandleForWriting.write(data)
        }
        lock.unlock()
    }

    func finish() {
        lock.lock()
        let wasStarted = started
        started = false
        lock.unlock()

        guard wasStarted else { return }
        writeQueue.sync {
            inputPipe.fileHandleForWriting.closeFile()
        }
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

struct CoreAudioDevice {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let sampleRate: Double
    let inputChannels: Int
}

func checkAudioStatus(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw RecorderError.coreAudioError(operation, status)
    }
}

func audioObjectPropertyDataSize(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope
) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
    )
    var size: UInt32 = 0
    try checkAudioStatus(
        AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size),
        "AudioObjectGetPropertyDataSize(\(selector))"
    )
    return size
}

func audioObjectStringProperty(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector
) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
        mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
    )
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    try checkAudioStatus(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
        "AudioObjectGetPropertyData(\(selector))"
    )
    return value as String
}

func audioDeviceNominalSampleRate(_ deviceID: AudioDeviceID) throws -> Double {
    var address = AudioObjectPropertyAddress(
        mSelector: AudioObjectPropertySelector(kAudioDevicePropertyNominalSampleRate),
        mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
        mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
    )
    var sampleRate = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.size)
    try checkAudioStatus(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate),
        "AudioObjectGetPropertyData(kAudioDevicePropertyNominalSampleRate)"
    )
    return Double(sampleRate)
}

func audioDeviceInputChannelCount(_ deviceID: AudioDeviceID) throws -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: AudioObjectPropertySelector(kAudioDevicePropertyStreamConfiguration),
        mScope: AudioObjectPropertyScope(kAudioDevicePropertyScopeInput),
        mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
    )
    var size: UInt32 = 0
    try checkAudioStatus(
        AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size),
        "AudioObjectGetPropertyDataSize(kAudioDevicePropertyStreamConfiguration)"
    )
    guard size > 0 else { return 0 }

    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }

    try checkAudioStatus(
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw),
        "AudioObjectGetPropertyData(kAudioDevicePropertyStreamConfiguration)"
    )

    let audioBufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func coreAudioInputDevices() throws -> [CoreAudioDevice] {
    let size = try audioObjectPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        AudioObjectPropertySelector(kAudioHardwarePropertyDevices),
        AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal)
    )
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    var address = AudioObjectPropertyAddress(
        mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDevices),
        mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
        mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
    )
    var mutableSize = size
    try checkAudioStatus(
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &mutableSize,
            &deviceIDs
        ),
        "AudioObjectGetPropertyData(kAudioHardwarePropertyDevices)"
    )

    return try deviceIDs.compactMap { deviceID in
        let channelCount = try audioDeviceInputChannelCount(deviceID)
        guard channelCount > 0 else { return nil }
        return CoreAudioDevice(
            id: deviceID,
            name: try audioObjectStringProperty(deviceID, AudioObjectPropertySelector(kAudioObjectPropertyName)),
            uid: try audioObjectStringProperty(deviceID, AudioObjectPropertySelector(kAudioDevicePropertyDeviceUID)),
            sampleRate: try audioDeviceNominalSampleRate(deviceID),
            inputChannels: channelCount
        )
    }
}

func coreAudioInputDevice(named name: String) throws -> CoreAudioDevice {
    if let exact = try coreAudioInputDevices().first(where: { $0.name == name }) {
        return exact
    }
    if let caseInsensitive = try coreAudioInputDevices().first(where: { $0.name.lowercased() == name.lowercased() }) {
        return caseInsensitive
    }
    throw RecorderError.audioDeviceNotFound(name)
}

final class CoreAudioDeviceRecorder {
    private let deviceName: String
    private let writer: FFMpegMP3Writer
    private var queue: AudioQueueRef?
    private var isRunning = false
    private let lock = NSLock()

    init(deviceName: String, outputURL: URL) {
        self.deviceName = deviceName
        self.writer = FFMpegMP3Writer(outputURL: outputURL)
    }

    func start() throws {
        let device = try coreAudioInputDevice(named: deviceName)
        let channels = min(max(device.inputChannels, 1), 2)
        let sampleRate = device.sampleRate > 0 ? device.sampleRate : 44_100

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * MemoryLayout<Int16>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * MemoryLayout<Int16>.size),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(MemoryLayout<Int16>.size * 8),
            mReserved: 0
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        var newQueue: AudioQueueRef?
        try checkAudioStatus(
            AudioQueueNewInput(
                &format,
                { userData, queue, buffer, _, numberPackets, _ in
                    guard let userData else { return }
                    let recorder = Unmanaged<CoreAudioDeviceRecorder>
                        .fromOpaque(userData)
                        .takeUnretainedValue()
                    recorder.handleInputBuffer(queue: queue, buffer: buffer, numberPackets: numberPackets)
                },
                userData,
                nil,
                nil,
                0,
                &newQueue
            ),
            "AudioQueueNewInput"
        )
        guard let newQueue else {
            throw RecorderError.coreAudioError("AudioQueueNewInput", -1)
        }

        var deviceUID = device.uid as CFString
        try checkAudioStatus(
            withUnsafePointer(to: &deviceUID) { pointer in
                AudioQueueSetProperty(
                    newQueue,
                    kAudioQueueProperty_CurrentDevice,
                    pointer,
                    UInt32(MemoryLayout<CFString>.size)
                )
            },
            "AudioQueueSetProperty(kAudioQueueProperty_CurrentDevice)"
        )

        var actualFormat = AudioStreamBasicDescription()
        var actualFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkAudioStatus(
            AudioQueueGetProperty(
                newQueue,
                kAudioQueueProperty_StreamDescription,
                &actualFormat,
                &actualFormatSize
            ),
            "AudioQueueGetProperty(kAudioQueueProperty_StreamDescription)"
        )
        try validatePCMFormat(actualFormat)

        let inputChannels = Int(actualFormat.mChannelsPerFrame)
        try writer.startIfNeeded(
            sampleRate: actualFormat.mSampleRate,
            channels: inputChannels,
            outputChannels: min(inputChannels, 2)
        )

        let framesPerBuffer = UInt32(actualFormat.mSampleRate / 4)
        let bufferByteSize = max(UInt32(16_384), framesPerBuffer * actualFormat.mBytesPerFrame)
        for _ in 0..<8 {
            var buffer: AudioQueueBufferRef?
            try checkAudioStatus(
                AudioQueueAllocateBuffer(newQueue, bufferByteSize, &buffer),
                "AudioQueueAllocateBuffer"
            )
            if let buffer {
                try checkAudioStatus(
                    AudioQueueEnqueueBuffer(newQueue, buffer, 0, nil),
                    "AudioQueueEnqueueBuffer"
                )
            }
        }

        lock.lock()
        queue = newQueue
        isRunning = true
        lock.unlock()

        try checkAudioStatus(AudioQueueStart(newQueue, nil), "AudioQueueStart")
    }

    func stop() {
        lock.lock()
        let activeQueue = queue
        isRunning = false
        queue = nil
        lock.unlock()

        if let activeQueue {
            AudioQueueStop(activeQueue, true)
            AudioQueueDispose(activeQueue, true)
        }
        writer.finish()
    }

    private func handleInputBuffer(queue: AudioQueueRef, buffer: AudioQueueBufferRef, numberPackets: UInt32) {
        lock.lock()
        let shouldContinue = isRunning
        lock.unlock()
        guard shouldContinue else { return }

        let byteCount = Int(buffer.pointee.mAudioDataByteSize)
        if numberPackets > 0, byteCount > 0 {
            writer.write(Data(bytes: buffer.pointee.mAudioData, count: byteCount))
        }

        lock.lock()
        let shouldRequeue = isRunning
        lock.unlock()
        if shouldRequeue {
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
    }

    private func validatePCMFormat(_ format: AudioStreamBasicDescription) throws {
        let flags = format.mFormatFlags
        let isSignedInteger = (flags & kAudioFormatFlagIsSignedInteger) != 0
        let isPacked = (flags & kAudioFormatFlagIsPacked) != 0
        let isNonInterleaved = (flags & kAudioFormatFlagIsNonInterleaved) != 0

        guard format.mFormatID == kAudioFormatLinearPCM,
              isSignedInteger,
              isPacked,
              !isNonInterleaved,
              format.mBitsPerChannel == 16,
              format.mChannelsPerFrame > 0,
              format.mBytesPerFrame == format.mChannelsPerFrame * UInt32(MemoryLayout<Int16>.size)
        else {
            throw RecorderError.unsupportedAudioFormat(
                "CoreAudio queue formatID=\(format.mFormatID), flags=\(flags), bits=\(format.mBitsPerChannel), channels=\(format.mChannelsPerFrame), bytesPerFrame=\(format.mBytesPerFrame)"
            )
        }
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

func listCoreAudioInputDevices() throws {
    for (index, device) in try coreAudioInputDevices().enumerated() {
        print("[\(index)] \(device.name) (\(Int(device.sampleRate.rounded())) Hz, \(device.inputChannels) input channels)")
        print("    uid: \(device.uid)")
    }
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

    Records audio to MP3 until Esc or Ctrl-C.

    Options:
      --device NAME      Record from a CoreAudio input device, such as "Loopback Audio".
      --list-devices     List CoreAudio input devices.
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

final class TerminalInputMode {
    private var original = termios()
    private var enabled = false

    init() {
        guard isatty(STDIN_FILENO) == 1, tcgetattr(STDIN_FILENO, &original) == 0 else {
            return
        }

        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        withUnsafeMutableBytes(of: &raw.c_cc) { controlCharacters in
            controlCharacters[Int(VMIN)] = 1
            controlCharacters[Int(VTIME)] = 0
        }

        if tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 {
            enabled = true
        }
    }

    func restore() {
        guard enabled else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
        enabled = false
    }

    deinit {
        restore()
    }
}

final class StopContinuationState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<Void, Never>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resumeOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume()
    }
}

func waitForStopKeyOrInterrupt() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let state = StopContinuationState(continuation)

        Thread.detachNewThread {
            var signals = interruptSignalSet()
            var receivedSignal: Int32 = 0
            sigwait(&signals, &receivedSignal)
            state.resumeOnce()
        }

        Thread.detachNewThread {
            var byte: UInt8 = 0
            while true {
                let count = read(STDIN_FILENO, &byte, 1)
                if count == 1, byte == 27 {
                    state.resumeOnce()
                    return
                }
                if count <= 0 {
                    return
                }
            }
        }
    }
}

func withStopControls(_ operation: () async throws -> Void) async rethrows {
    let terminalMode = TerminalInputMode()
    defer { terminalMode.restore() }
    try await operation()
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
                try listCoreAudioInputDevices()
                return
            }

            if let deviceName = options.deviceName {
                let recorder = CoreAudioDeviceRecorder(deviceName: deviceName, outputURL: options.outputURL)

                print("Recording CoreAudio input device '\(deviceName)' to: \(options.outputURL.path)")
                print("Press Esc or Ctrl-C to stop.")

                try recorder.start()
                await withStopControls {
                    await waitForStopKeyOrInterrupt()
                }
                print("\nStopping...")
                recorder.stop()
                try validateOutputFile(options.outputURL)
                print("Saved: \(options.outputURL.path)")
                return
            }

            if #available(macOS 13.0, *) {
                let writer = FFMpegMP3Writer(outputURL: options.outputURL)
                let recorder = SystemAudioRecorder(writer: writer)

                print("Recording system audio to: \(options.outputURL.path)")
                print("Press Esc or Ctrl-C to stop.")

                try await recorder.start()
                await withStopControls {
                    await waitForStopKeyOrInterrupt()
                }
                print("\nStopping...")
                await recorder.stop()
                try validateOutputFile(options.outputURL)
                print("Saved: \(options.outputURL.path)")
            } else {
                let recorder = CoreAudioDeviceRecorder(deviceName: defaultFallbackDeviceName, outputURL: options.outputURL)

                print("macOS 13 native capture is unavailable; using CoreAudio input device '\(defaultFallbackDeviceName)'.")
                print("Recording to: \(options.outputURL.path)")
                print("Press Esc or Ctrl-C to stop.")

                try recorder.start()
                await withStopControls {
                    await waitForStopKeyOrInterrupt()
                }
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
