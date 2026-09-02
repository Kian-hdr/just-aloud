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
                let item = PlayItem(
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

        let delay = Double(sentencePauseOverrideMs ?? item.pauseMs) / 1000.0
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

// ── Main ─────────────────────────────────────────────────────────

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: just-aloud-audio <is-muted|unmute|play-queue>\n", stderr)
    exit(2)
}

switch CommandLine.arguments[1] {
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
