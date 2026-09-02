// just-aloud-audio — CoreAudio utilities for Just Aloud
// Usage: just-aloud-audio is-muted     → exit 0 if muted, 1 if not
//        just-aloud-audio unmute       → exit 0 on success, 1 on failure
//        just-aloud-audio play-queue   → gapless, externally controllable audio queue player

import AVFoundation
import CoreAudio
import Foundation

private let playbackStateFile = (NSTemporaryDirectory() as NSString)
    .appendingPathComponent("just_aloud_audio_state")

private func writePlaybackState(_ state: String) {
    try? (state + "\n").write(
        toFile: playbackStateFile,
        atomically: true,
        encoding: .utf8)
}

func getDefaultOutputDevice() -> AudioDeviceID? {
    var deviceID: AudioDeviceID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address) else {
        return nil
    }
    let err = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
    )
    return (err == noErr && deviceID != kAudioObjectUnknown) ? deviceID : nil
}

func isMuted() -> Bool {
    guard let deviceID = getDefaultOutputDevice() else { return false }
    var muted: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &address) else { return false }
    let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
    return err == noErr && muted == 1
}

func unmute() -> Bool {
    guard let deviceID = getDefaultOutputDevice() else { return false }
    var muted: UInt32 = 0
    let size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &address) else { return false }
    let err = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &muted)
    return err == noErr
}

// ── play-queue: gapless audio queue player ───────────────────────
// Reads tab-separated lines from stdin:
//   filepath\tepoch\toffset\tsent_len\tstatus_file\tpause_ms\tplayback_rate
// Outputs to stdout:
//   duration   (float, immediately after prepareToPlay)
//   DONE       (after playback finishes)
// Writes STATUS_FILE with: epoch\nduration\noffset\nsent_len\n

private struct PlayItem {
    let index: Int
    let file: AVAudioFile
    let duration: Double
    let rate: Float
    let epoch: String
    let offset: String
    let sentLen: String
    let statusFile: String
    let pauseMs: Int
}

class QueuePlayer: NSObject {
    private var queue: [PlayItem] = []
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var timePitch: AVAudioUnitTimePitch?
    private var current: PlayItem?
    private var playing = false
    private var paused = false
    private var stdinOpen = true
    private var scheduledStartFrame: AVAudioFramePosition = 0
    private var playbackToken = 0
    private var sentencePauseOverrideMs: Int?
    private var controlTimer: Timer?
    private let controlFile = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("just_aloud_audio_control")

    func start() {
        // Discard commands left behind by an earlier, terminated player.
        try? FileManager.default.removeItem(atPath: controlFile)
        try? FileManager.default.removeItem(atPath: playbackStateFile)
        controlTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.consumeControls()
        }

        DispatchQueue.global().async { [self] in
            var receivedItems = 0
            while let line = readLine() {
                let parts = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false)
                guard parts.count >= 5 else { continue }
                let path = String(parts[0])
                let url = URL(fileURLWithPath: path)
                guard let file = try? AVAudioFile(forReading: url) else {
                    fputs("ERROR: cannot open \(path)\n", stderr)
                    continue
                }
                let requestedRate = Float(parts.count >= 7 ? (Double(parts[6]) ?? 1.0) : 1.0)
                let rate = min(max(requestedRate, 0.5), 4.0)
                let sourceDuration = Double(file.length) / file.processingFormat.sampleRate
                let effectiveDuration = sourceDuration / Double(rate)
                let pauseMs = parts.count >= 6 ? (Int(parts[5]) ?? 0) : 0
                receivedItems += 1
                let item = PlayItem(
                    index: receivedItems,
                    file: file,
                    duration: effectiveDuration,
                    rate: rate,
                    epoch: String(parts[1]),
                    offset: String(parts[2]),
                    sentLen: String(parts[3]),
                    statusFile: String(parts[4]),
                    pauseMs: pauseMs
                )
                DispatchQueue.main.async { [self] in
                    // Print duration immediately so bash can generate the next sentence
                    print(String(format: "%.3f", effectiveDuration))
                    fflush(stdout)
                    self.queue.append(item)
                    if !self.playing { self.playNext() }
                }
            }
            DispatchQueue.main.async { [self] in
                self.stdinOpen = false
                if !self.playing { CFRunLoopStop(CFRunLoopGetMain()) }
            }
        }
    }

    private func playNext() {
        // Sentence generation and configured inter-sentence pauses are standby,
        // not active audio playback.
        writePlaybackState("idle")
        guard !queue.isEmpty else {
            engine?.stop()
            engine = nil
            playerNode = nil
            timePitch = nil
            current = nil
            playing = false
            paused = false
            if !stdinOpen { CFRunLoopStop(CFRunLoopGetMain()) }
            return
        }
        playing = true
        let item = queue.removeFirst()
        current = item

        let startPlaying = { [weak self] in
            guard let self = self else { return }
            let status = "\(item.epoch)\n\(String(format: "%.3f", item.duration))\n\(item.offset)\n\(item.sentLen)\n"
            try? status.write(toFile: item.statusFile, atomically: true, encoding: .utf8)
            self.play(item)
        }

        let effectivePause = sentencePauseOverrideMs ?? item.pauseMs
        if let directory = ProcessInfo.processInfo.environment["JUST_ALOUD_RECORDING_DIR"] {
            let path = URL(fileURLWithPath: directory).appendingPathComponent("pause-\(item.index).txt")
            try? String(effectivePause).write(to: path, atomically: true, encoding: .utf8)
        }
        let delay = Double(effectivePause) / 1000.0
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: startPlaying)
        } else {
            startPlaying()
        }
    }

    private func play(_ item: PlayItem) {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.rate = item.rate
        pitch.pitch = 0

        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: item.file.processingFormat)
        engine.connect(pitch, to: engine.mainMixerNode, format: item.file.processingFormat)

        self.engine = engine
        self.playerNode = player
        self.timePitch = pitch
        scheduledStartFrame = 0
        playbackToken += 1
        let token = playbackToken

        do {
            try engine.start()
            schedule(item, from: 0, token: token)
            if paused {
                writePlaybackState("paused")
            } else {
                player.play()
                writePlaybackState("playing")
            }
        } catch {
            writePlaybackState("idle")
            fputs("ERROR: playback failed: \(error)\n", stderr)
            print("DONE")
            fflush(stdout)
            playNext()
        }
    }

    private func schedule(_ item: PlayItem, from frame: AVAudioFramePosition, token: Int) {
        let remaining = max(0, item.file.length - frame)
        guard remaining > 0 else {
            finishCurrent(token: token)
            return
        }
        let frameCount = AVAudioFrameCount(min(remaining, AVAudioFramePosition(UInt32.max)))
        playerNode?.scheduleSegment(
            item.file,
            startingFrame: frame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.finishCurrent(token: token) }
        }
    }

    private func finishCurrent(token: Int) {
        guard token == playbackToken else { return }
        writePlaybackState("idle")
        engine?.stop()
        print("DONE")
        fflush(stdout)
        playNext()
    }

    private func currentSourceFrame() -> AVAudioFramePosition {
        guard let player = playerNode,
              let renderTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: renderTime) else {
            return scheduledStartFrame
        }
        return scheduledStartFrame + max(0, playerTime.sampleTime)
    }

    private func setPaused(_ shouldPause: Bool) {
        guard playing, current != nil else {
            paused = shouldPause
            return
        }
        if shouldPause && !paused {
            playerNode?.pause()
            paused = true
            writePlaybackState("paused")
        } else if !shouldPause && paused {
            playerNode?.play()
            paused = false
            writePlaybackState("playing")
        }
    }

    private func seek(byOutputSeconds seconds: Double) {
        guard let item = current,
              let player = playerNode,
              item.file.length > 1 else { return }

        let sampleRate = item.file.processingFormat.sampleRate
        let sourceDelta = seconds * sampleRate * Double(item.rate)
        let currentFrame = currentSourceFrame()
        let target = min(
            max(AVAudioFramePosition(0), currentFrame + AVAudioFramePosition(sourceDelta.rounded())),
            item.file.length - 1
        )

        playbackToken += 1
        let token = playbackToken
        player.stop()
        scheduledStartFrame = target
        schedule(item, from: target, token: token)
        if paused {
            writePlaybackState("paused")
        } else {
            player.play()
            writePlaybackState("playing")
        }
    }

    private func consumeControls() {
        guard let data = FileManager.default.contents(atPath: controlFile),
              let commands = String(data: data, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: controlFile)

        for rawCommand in commands.components(separatedBy: .newlines) {
            let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            switch command {
            case "pause":
                setPaused(true)
            case "play":
                setPaused(false)
            case "toggle":
                setPaused(!paused)
            case "seek:-10":
                seek(byOutputSeconds: -10)
            case "seek:10":
                seek(byOutputSeconds: 10)
            default:
                if command.hasPrefix("sentence-pause:"),
                   let value = Int(command.dropFirst("sentence-pause:".count)),
                   value >= 0, value <= 5_000 {
                    sentencePauseOverrideMs = value
                }
                continue
            }
        }
    }
}

func runPlayQueue() -> Never {
    signal(SIGTERM) { _ in exit(0) }
    signal(SIGINT) { _ in exit(0) }
    let qp = QueuePlayer()
    qp.start()
    CFRunLoopRun()
    exit(0)
}

// Offline export reads only already-generated local files. No provider calls.
private struct RecordingChunk {
    let url: URL
    let rate: Float
    let pauseMs: Int
}

private enum RecordingError: Error { case invalidManifest, renderFailed }

private func recordingChunks(at directory: URL) throws -> [RecordingChunk] {
    let manifest = try String(contentsOf: directory.appendingPathComponent("manifest.tsv"), encoding: .utf8)
    let lines = manifest.split(separator: "\n")
    guard !lines.isEmpty else { throw RecordingError.invalidManifest }
    return try lines.enumerated().map { index, line in
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        let expectedName = "chunk-\(index + 1).audio"
        guard fields.count == 3, fields[0] == expectedName,
              let pause = Int(fields[1]), (0...5_000).contains(pause),
              let rate = Float(fields[2]), rate.isFinite, (0.5...4).contains(rate)
        else { throw RecordingError.invalidManifest }
        let url = directory.appendingPathComponent(expectedName)
        guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true
        else { throw RecordingError.invalidManifest }
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { throw RecordingError.invalidManifest }
        let appliedPause = (try? String(contentsOf: directory.appendingPathComponent("pause-\(index + 1).txt"), encoding: .utf8)).flatMap(Int.init) ?? pause
        return RecordingChunk(url: url, rate: rate,
                              pauseMs: index == 0 ? 0 : min(max(appliedPause, 0), 5_000))
    }
}

private func exportRecording(from directory: URL, to destination: URL) throws {
    guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("complete").path),
          !FileManager.default.fileExists(atPath: destination.path)
    else { throw RecordingError.invalidManifest }
    let chunks = try recordingChunks(at: directory)
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let output = try AVAudioFile(forWriting: destination, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
    ])
    let capacity: AVAudioFrameCount = 4096
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
    for chunk in chunks {
        var silenceFrames = Int64((Double(chunk.pauseMs) * 44.1).rounded())
        while silenceFrames > 0 {
            buffer.frameLength = AVAudioFrameCount(min(Int64(capacity), silenceFrames))
            memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
            try output.write(from: buffer)
            silenceFrames -= Int64(buffer.frameLength)
        }
        let source = try AVAudioFile(forReading: chunk.url)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.rate = chunk.rate
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: source.processingFormat)
        engine.connect(pitch, to: engine.mainMixerNode, format: source.processingFormat)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: capacity)
        player.scheduleFile(source, at: nil)
        try engine.start()
        player.play()
        defer { engine.stop() }
        var remaining = Int64((Double(source.length) / source.processingFormat.sampleRate
                               / Double(chunk.rate) * format.sampleRate).rounded())
        var retries = 0
        while remaining > 0 {
            let count = AVAudioFrameCount(min(Int64(capacity), remaining))
            let status = try engine.renderOffline(count, to: buffer)
            switch status {
            case .success:
                guard buffer.frameLength > 0 else { throw RecordingError.renderFailed }
                try output.write(from: buffer)
                remaining -= Int64(buffer.frameLength)
                retries = 0
            case .cannotDoInCurrentContext:
                retries += 1
                if retries > 100 { throw RecordingError.renderFailed }
            default:
                throw RecordingError.renderFailed
            }
        }
    }
}

// ── Main ─────────────────────────────────────────────────────────

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: just-aloud-audio <is-muted|unmute|play-queue>\n", stderr)
    exit(2)
}

switch CommandLine.arguments[1] {
case "check-recording", "export-recording":
    do {
        guard CommandLine.arguments.count >= 3 else { throw RecordingError.invalidManifest }
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        if CommandLine.arguments[1] == "check-recording" {
            _ = try recordingChunks(at: directory)
        } else {
            guard CommandLine.arguments.count == 4 else { throw RecordingError.invalidManifest }
            try exportRecording(from: directory, to: URL(fileURLWithPath: CommandLine.arguments[3]))
        }
        exit(0)
    } catch {
        // No transcript, voice identifier, credential, or private path in errors.
        fputs("Recording could not be exported. The complete original audio is required.\n", stderr)
        exit(1)
    }
case "is-muted":
    exit(isMuted() ? 0 : 1)
case "unmute":
    exit(unmute() ? 0 : 1)
case "play-queue":
    runPlayQueue()
default:
    fputs("Unknown command: \(CommandLine.arguments[1])\n", stderr)
    exit(2)
}
