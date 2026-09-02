import Cocoa
import ApplicationServices
import CoreAudio
import Darwin
import Security

// MARK: - Config paths

private let configDir: String = {
    if let override = ProcessInfo.processInfo.environment["JUST_ALOUD_CONFIG_DIR"],
       !override.isEmpty { return override }
    return (NSHomeDirectory() as NSString).appendingPathComponent(".config/just-aloud")
}()
private let configPath = (configDir as NSString).appendingPathComponent("config")
private let speakPath: String = {
    let userInstall = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".local/bin/just-aloud")
    if FileManager.default.isExecutableFile(atPath: userInstall) { return userInstall }
    return Bundle.main.path(forResource: "just-aloud", ofType: nil) ?? userInstall
}()
private let audioControlPath = (NSTemporaryDirectory() as NSString)
    .appendingPathComponent("just_aloud_audio_control")
private let speechPIDPath = (NSTemporaryDirectory() as NSString)
    .appendingPathComponent("just_aloud_tts.pid")
private let playbackStatePath = (NSTemporaryDirectory() as NSString)
    .appendingPathComponent("just_aloud_audio_state")
private let welcomeCompletionKey = "welcomeCompleted"
private let welcomeDefaults: UserDefaults = {
    if let suite = ProcessInfo.processInfo.environment["JUST_ALOUD_DEFAULTS_SUITE"],
       !suite.isEmpty,
       let isolatedDefaults = UserDefaults(suiteName: suite) {
        return isolatedDefaults
    }
    return .standard
}()

// MARK: - Config model

struct Config {
    // Backend selection
    var ttsBackend:         String = "auto"          // "auto", "elevenlabs", or "local"
    var backendsInstalled:  String = "elevenlabs"   // "elevenlabs", "local", or "both"

    // ElevenLabs settings
    var voiceId:         String = "pFZP5JQG7iQjIQuC4Bku"
    var customVoiceIds:  [String] = []
    var customVoiceNames: [String: String] = [:]
    var modelId:         String = "eleven_flash_v2_5"
    var stability:       Double = 0.5
    var similarityBoost: Double = 0.75
    var style:           Double = 0.0
    var useSpeakerBoost: Bool   = true

    // Local TTS settings
    var localVoice:      String = "bf_lily"
    var localSpeed:      Double = 1.0

    // ElevenLabs speed (shared name kept for config compat)
    var speed:           Double = 1.0

    // Pitch-preserving local playback multiplier. The effective cloud speed is
    // SPEED × PLAYBACK_SPEED and is exposed as one native slider.
    var playbackSpeed:   Double = 1.0

    // Inter-sentence pause in real elapsed milliseconds at every speech speed
    var sentencePause:   Int    = 400

    static func load(from path: String = configPath) -> Config {
        var c = Config()
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return c }
        for line in raw.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let eqRange = line.range(of: "=") else { continue }
            let key = String(line[line.startIndex..<eqRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            var value = String(line[eqRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'")  && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "TTS_BACKEND":          c.ttsBackend        = value
            case "TTS_BACKENDS_INSTALLED":c.backendsInstalled = value
            case "VOICE_ID":             c.voiceId            = value
            case "CUSTOM_VOICE_IDS":
                c.customVoiceIds = value.split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            case "CUSTOM_VOICE_NAMES_B64":
                for entry in value.split(separator: ",") {
                    guard let separator = entry.firstIndex(of: ":") else { continue }
                    let id = String(entry[..<separator])
                    let encodedName = String(entry[entry.index(after: separator)...])
                    guard !id.isEmpty,
                          let data = Data(base64Encoded: encodedName),
                          let name = String(data: data, encoding: .utf8),
                          !name.isEmpty else { continue }
                    c.customVoiceNames[id] = name
                }
            case "MODEL_ID":             c.modelId            = value
            case "STABILITY":            c.stability          = Double(value) ?? c.stability
            case "SIMILARITY_BOOST":     c.similarityBoost    = Double(value) ?? c.similarityBoost
            case "STYLE":                c.style              = Double(value) ?? c.style
            case "USE_SPEAKER_BOOST":    c.useSpeakerBoost    = value == "true" || value == "1"
            case "SPEED":                c.speed              = Double(value) ?? c.speed
            case "PLAYBACK_SPEED":       c.playbackSpeed      = Double(value) ?? c.playbackSpeed
            case "LOCAL_VOICE":          c.localVoice         = value
            case "LOCAL_SPEED":          c.localSpeed         = Double(value) ?? c.localSpeed
            case "SENTENCE_PAUSE":       c.sentencePause      = Int(value) ?? c.sentencePause
            default: break
            }
        }
        if !c.voiceId.isEmpty,
           !knownVoices.contains(where: { $0.id == c.voiceId }),
           !c.customVoiceIds.contains(c.voiceId) {
            c.customVoiceIds.append(c.voiceId)
        }
        var seen = Set<String>()
        c.customVoiceIds = c.customVoiceIds.filter { seen.insert($0).inserted }
        c.customVoiceNames = c.customVoiceNames.filter { c.customVoiceIds.contains($0.key) }
        return c
    }

    func save() {
        try? FileManager.default.createDirectory(
            atPath: configDir, withIntermediateDirectories: true, attributes: nil)
        let encodedVoiceNames = customVoiceIds.compactMap { id -> String? in
            guard let name = customVoiceNames[id], !name.isEmpty else { return nil }
            return "\(id):\(Data(name.utf8).base64EncodedString())"
        }.joined(separator: ",")
        let lines = [
            "TTS_BACKEND=\"\(ttsBackend)\"",
            "TTS_BACKENDS_INSTALLED=\"\(backendsInstalled)\"",
            "VOICE_ID=\"\(voiceId)\"",
            "CUSTOM_VOICE_IDS=\"\(customVoiceIds.joined(separator: ","))\"",
            "CUSTOM_VOICE_NAMES_B64=\"\(encodedVoiceNames)\"",
            "MODEL_ID=\"\(modelId)\"",
            "STABILITY=\"\(String(format: "%.2f", stability))\"",
            "SIMILARITY_BOOST=\"\(String(format: "%.2f", similarityBoost))\"",
            "STYLE=\"\(String(format: "%.2f", style))\"",
            "USE_SPEAKER_BOOST=\"\(useSpeakerBoost ? "true" : "false")\"",
            "SPEED=\"\(String(format: "%.2f", speed))\"",
            "PLAYBACK_SPEED=\"\(String(format: "%.2f", playbackSpeed))\"",
            "LOCAL_VOICE=\"\(localVoice)\"",
            "LOCAL_SPEED=\"\(String(format: "%.2f", localSpeed))\"",
            "SENTENCE_PAUSE=\"\(sentencePause)\"",
        ]
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: configPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - Static data

// Public preset voices preserved from the stable upstream Speak11 release.
private let knownVoices: [(name: String, id: String)] = [
    ("Lily — British, raspy",      "pFZP5JQG7iQjIQuC4Bku"),
    ("Alice — British, confident", "Xb7hH8MSUJpSbSDYk0k2"),
    ("Rachel — calm",              "21m00Tcm4TlvDq8ikWAM"),
    ("Adam — deep",                "pNInz6obpgDQGcFmaJgB"),
    ("Domi — strong",              "AZnzlk1XvdvUeBnXmlld"),
    ("Josh — young, deep",         "TxGEqnHWrfWFTfGW9XjX"),
    ("Sam — raspy",                "yoZ06aMxZJJ28mfd3POQ"),
]

// Kokoro voices (curated English subset)
private let kokoroVoices: [(name: String, id: String)] = [
    ("Lily — British, bright", "bf_lily"),
    ("Heart — warm",           "af_heart"),
    ("Bella — soft",           "af_bella"),
    ("Nova — confident",       "af_nova"),
    ("Sarah — gentle",         "af_sarah"),
    ("Sky — bright",           "af_sky"),
    ("Adam — deep",            "am_adam"),
    ("Echo — clear",           "am_echo"),
    ("Eric — steady",          "am_eric"),
    ("Michael — warm",         "am_michael"),
    ("Emma — British, warm",   "bf_emma"),
    ("George — British, deep", "bm_george"),
]

private let knownModels: [(name: String, id: String)] = [
    ("v3 — best quality",         "eleven_v3"),
    ("Flash v2.5 — fastest",      "eleven_flash_v2_5"),
    ("Turbo v2.5 — fast, ½ cost", "eleven_turbo_v2_5"),
    ("Multilingual v2 — 29 langs","eleven_multilingual_v2"),
]

// ElevenLabs synthesis accepts up to 1.2×. Faster effective speeds use the
// pitch-preserving AVAudioUnitTimePitch stage in just-aloud-audio.
private let minEffectiveSpeed = 0.7
private let maxEffectiveSpeed = 3.0
private let speedStep = 0.05

// Kokoro accepts a wider speed range
private let localSpeedSteps: [(label: String, value: Double)] = [
    ("0.5×", 0.5), ("0.75×", 0.75), ("1×", 1.0), ("1.25×", 1.25), ("1.5×", 1.5), ("2×", 2.0),
]

private let sentencePauseSteps: [(label: String, value: Int)] = [
    ("None", 0),
    ("Very Short — 250 ms", 250),
    ("Natural — 400 ms", 400),
    ("Short — 500 ms", 500),
    ("Medium — 750 ms", 750),
    ("Long — 1 second", 1_000),
    ("Very Long — 1.5 seconds", 1_500),
    ("Extra Long — 2 seconds", 2_000),
]

private let stabilitySteps: [(label: String, value: Double)] = [
    ("0.0 — expressive", 0.0), ("0.25", 0.25), ("0.5 — default", 0.5),
    ("0.75", 0.75), ("1.0 — steady", 1.0),
]

private let similaritySteps: [(label: String, value: Double)] = [
    ("0.0 — low", 0.0), ("0.25", 0.25), ("0.5", 0.5),
    ("0.75 — default", 0.75), ("1.0 — high", 1.0),
]

private let styleSteps: [(label: String, value: Double)] = [
    ("0.0 — none (default)", 0.0), ("0.25", 0.25), ("0.5", 0.5),
    ("0.75", 0.75), ("1.0 — max", 1.0),
]

// MARK: - CoreAudio mute check (in-process, microseconds)

private func getDefaultOutputDevice() -> AudioDeviceID? {
    var deviceID: AudioDeviceID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address) else { return nil }
    let err = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
    )
    return (err == noErr && deviceID != kAudioObjectUnknown) ? deviceID : nil
}

func isOutputMuted() -> Bool {
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

func unmuteOutput() {
    guard let deviceID = getDefaultOutputDevice() else { return }
    var muted: UInt32 = 0
    let size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectHasProperty(deviceID, &address) else { return }
    AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &muted)
}

// MARK: - Global hotkey ⌥⇧/ → speak.sh
//
// Keycode 44 = forward slash on ANSI/ISO keyboards (US and most layouts).
// Option+Shift must be set — no Control or Command.

private let kHotkeyCode: Int64 = 44

// Module-level tap reference so the C callback can re-enable it after a timeout.
private var globalTap: CFMachPort?
// Weak ref so the C callback can update the menu bar icon.
private weak var appDelegateRef: AppDelegate?

private let hotkeyCallback: CGEventTapCallBack = { _, type, event, _ in
    // If the tap was disabled (e.g. callback was too slow), re-enable it.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = globalTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passRetained(event)
    }

    guard type == .keyDown else { return Unmanaged.passRetained(event) }

    let code  = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags.intersection([.maskAlternate, .maskShift, .maskControl, .maskCommand])

    guard code == kHotkeyCode, flags == [.maskAlternate, .maskShift] else {
        return Unmanaged.passRetained(event)
    }

    // Fire on a background thread — never block the event tap.
    DispatchQueue.global(qos: .userInitiated).async {
        appDelegateRef?.handleHotkey()
    }
    return nil  // consume the keystroke
}

// MARK: - App delegate

private final class VoiceActionButton: NSButton {
    var voiceId = ""
}

@objc final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var config         = Config.load()
    private var accessTimer: Timer?
    private var animTimer:   Timer?
    private var animPhase:   Double = 0
    private var indicatorMode = "idle"
    private var playbackMonitorTimer: Timer?

    // Respeak state — synchronized via speakLock
    private var speakGeneration = 0
    private var currentSpeakProcess: Process?
    private var isSpeakingFlag = false
    private var isPlaybackPaused = false
    private weak var playPauseButton: NSButton?
    private var playbackButtons: [NSButton] = []
    private var respeakTimer: Timer?
    private let speakLock = NSLock()

    // Credits cache (fetched from ElevenLabs API)
    private var cachedCredits: (used: Int, limit: Int, fetchedAt: Date)?
    private var voiceNameFetchesInFlight = Set<String>()
    private var voiceNameFetchFailures = Set<String>()
    private var cloudVoiceIndicators: [String: NSImageView] = [:]
    private var cloudVoiceSelectionButtons: [VoiceActionButton] = []
    private var aboutWindow: NSWindow?
    private var welcomeWindow: NSWindow?

    // TTS daemon process (managed mode — started by this app)
    private var ttsDaemonProcess: Process?

    private func idleMenuBarImage() -> NSImage {
        let image = NSImage(
            systemSymbolName: "play.circle.fill",
            accessibilityDescription: "Just Aloud") ?? NSImage()
        image.isTemplate = true
        return image
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "space.exlumina.justaloud.status-item"
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = idleMenuBarImage()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "Just Aloud"
            button.setAccessibilityLabel("Just Aloud menu")
        }
        appDelegateRef = self
        installStandardEditMenu()
        installHotkey()
        refreshVoiceNames(force: true)
        rebuildMenu()
        let showWelcome = shouldShowWelcomeOnLaunch
        updateTTSDaemon()
        fetchCredits()
        let monitor = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.refreshPlaybackIndicator()
        }
        playbackMonitorTimer = monitor
        RunLoop.main.add(monitor, forMode: .common)
        refreshPlaybackIndicator()
        if showWelcome {
            DispatchQueue.main.async { [weak self] in self?.showWelcome() }
        } else if ProcessInfo.processInfo.environment["JUST_ALOUD_SHOW_ABOUT"] == "1" {
            DispatchQueue.main.async { [weak self] in self?.showAbout() }
        }
    }

    private var shouldShowWelcomeOnLaunch: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["JUST_ALOUD_SKIP_WELCOME"] == "1" { return false }
        if environment["JUST_ALOUD_FORCE_WELCOME"] == "1" { return true }
        return !welcomeDefaults.bool(forKey: welcomeCompletionKey)
    }

    private func installStandardEditMenu() {
        let mainMenu = NSMenu()
        let editRoot = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        let undo = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        undo.target = nil
        editMenu.addItem(undo)
        editMenu.addItem(.separator())
        for (title, action, key) in [
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a")
        ] {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
            menuItem.target = nil
            editMenu.addItem(menuItem)
        }
        editRoot.submenu = editMenu
        mainMenu.addItem(editRoot)
        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        playbackMonitorTimer?.invalidate()
        killCurrentProcess()
        stopTTSDaemon()
    }

    // Re-read config every time the menu opens so we pick up changes from
    // speak.sh (e.g. when the 429 handler installs local TTS and updates the
    // config file).
    func menuWillOpen(_ menu: NSMenu) {
        let fresh = Config.load()
        if fresh.backendsInstalled != config.backendsInstalled ||
           fresh.ttsBackend != config.ttsBackend {
            config = fresh
            rebuildMenu()
            updateTTSDaemon()
        }
        updateMediaControls()
        refreshVoiceNames()
        fetchCredits()
    }

    func setSpeaking(_ active: Bool) {
        let requestedMode = active ? (isPlaybackPaused ? "paused" : "playing") : "idle"
        guard requestedMode != indicatorMode else {
            updateMediaControls()
            return
        }
        indicatorMode = requestedMode
        // Always stop any existing animation first (prevents leaked timers
        // when the hotkey fires while a previous speak.sh is still running).
        animTimer?.invalidate()
        animTimer = nil

        if active && isPlaybackPaused {
            statusItem.button?.image = NSImage(
                systemSymbolName: "pause.fill", accessibilityDescription: "Just Aloud paused")
        } else if active {
            animPhase = 0
            statusItem.button?.image = waveformFrame(phase: 0)
            animTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.animPhase += 0.5
                self.statusItem.button?.image = self.waveformFrame(phase: self.animPhase)
            }
        } else {
            isPlaybackPaused = false
            statusItem.button?.image = idleMenuBarImage()
        }
        updateMediaControls()
    }

    private func refreshPlaybackIndicator() {
        guard isSpeechActive,
              let rawState = try? String(contentsOfFile: playbackStatePath, encoding: .utf8) else {
            isPlaybackPaused = false
            setSpeaking(false)
            return
        }
        switch rawState.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "playing":
            isPlaybackPaused = false
            setSpeaking(true)
        case "paused":
            isPlaybackPaused = true
            setSpeaking(true)
        default:
            isPlaybackPaused = false
            setSpeaking(false)
        }
    }

    private func waveformFrame(phase: Double) -> NSImage {
        let w: CGFloat = 18, h: CGFloat = 18
        let barCount   = 5
        let barWidth:  CGFloat = 2
        let gap:       CGFloat = 1.5
        let totalW     = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
        let startX     = (w - totalW) / 2

        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        for i in 0..<barCount {
            let t = phase + Double(i) * 0.8
            let norm = (sin(t) + 1) / 2          // 0…1
            let minH: CGFloat = 3
            let maxH: CGFloat = 14
            let barH = minH + CGFloat(norm) * (maxH - minH)
            let x = startX + CGFloat(i) * (barWidth + gap)
            let y = (h - barH) / 2
            let rect = NSRect(x: x, y: y, width: barWidth, height: barH)
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    // MARK: - Hotkey

    func handleHotkey() {
        speakLock.lock()
        let speaking = isSpeakingFlag
        speakLock.unlock()

        if speaking {
            stopSpeaking()
        } else {
            // Simulate ⌘C directly via CGEvent so the settings app's own
            // Accessibility grant is used.
            let src = CGEventSource(stateID: .hidSystemState)
            let cDown = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true)
            cDown?.flags = .maskCommand
            let cUp   = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
            cUp?.flags = .maskCommand
            cDown?.post(tap: .cgAnnotatedSessionEventTap)
            cUp?.post(tap: .cgAnnotatedSessionEventTap)
            // Wait for the clipboard to be updated before speak.sh reads it.
            Thread.sleep(forTimeInterval: 0.2)

            runSpeak()
        }
    }

    private func installHotkey() {
        guard AXIsProcessTrusted() else { return }
        guard globalTap == nil else { return }  // already installed

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let tap  = CGEvent.tapCreate(
            tap:              .cgSessionEventTap,
            place:            .headInsertEventTap,
            options:          .defaultTap,
            eventsOfInterest: mask,
            callback:         hotkeyCallback,
            userInfo:         nil)
        guard let tap = tap else { return }

        globalTap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // Poll until Accessibility is granted (e.g. after user clicks Allow).
    private func startAccessibilityPolling() {
        accessTimer?.invalidate()
        accessTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard AXIsProcessTrusted() else { return }
            t.invalidate()
            self?.installHotkey()
            self?.rebuildMenu()
        }
    }

    @objc private func requestAccessibility() {
        guard !AXIsProcessTrusted() else {
            installHotkey()
            rebuildMenu()
            return
        }
        let key  = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        startAccessibilityPolling()
    }

    // MARK: - Speak process management

    func runSpeak(withText text: String? = nil) {
        // In-process mute check via CoreAudio (microseconds, no fork).
        if isOutputMuted() {
            let alert = NSAlert()
            alert.messageText = "Your Mac is muted."
            alert.addButton(withTitle: "Unmute & Play")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            if alert.runModal() == .alertFirstButtonReturn {
                unmuteOutput()
            } else {
                return
            }
        }

        speakLock.lock()
        speakGeneration += 1
        let gen = speakGeneration
        isSpeakingFlag = true
        speakLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments    = [speakPath]
            task.environment  = ProcessInfo.processInfo.environment.merging(
                ["JUST_ALOUD_MUTE_CHECKED": "1"]) { _, new in new }

            if let text = text {
                let pipe = Pipe()
                pipe.fileHandleForWriting.write(text.data(using: .utf8) ?? Data())
                pipe.fileHandleForWriting.closeFile()
                task.standardInput = pipe
            } else {
                task.standardInput = FileHandle.nullDevice
            }

            speakLock.lock()
            currentSpeakProcess = task
            speakLock.unlock()

            do { try task.run() } catch {
                speakLock.lock()
                currentSpeakProcess = nil
                if speakGeneration == gen { isSpeakingFlag = false }
                speakLock.unlock()
                DispatchQueue.main.async {
                    self.speakLock.lock()
                    let current = self.speakGeneration
                    self.speakLock.unlock()
                    if current == gen { self.setSpeaking(false) }
                }
                return
            }

            task.waitUntilExit()

            speakLock.lock()
            currentSpeakProcess = nil
            let currentGen = speakGeneration
            if currentGen == gen { isSpeakingFlag = false }
            speakLock.unlock()

            DispatchQueue.main.async {
                if currentGen == gen { self.setSpeaking(false) }
            }
        }
    }

    func killCurrentProcess() {
        speakLock.lock()
        speakGeneration += 1
        let process = currentSpeakProcess
        currentSpeakProcess = nil  // prevent duplicate kill attempts
        speakLock.unlock()

        guard let process = process, process.isRunning else { return }
        let pid = process.processIdentifier

        // Kill child processes first (afplay, curl, python3).
        // bash 3.2 defers SIGTERM while a foreground child is running,
        // so we kill children first to let bash process the signal.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-P", String(pid)]
        try? pkill.run()
        pkill.waitUntilExit()

        process.terminate()
    }

    // MARK: - TTS daemon lifecycle

    private var needsDaemon: Bool {
        let b = config.ttsBackend
        return (b == "local" || b == "auto") && isLocalInstalled
    }

    private var venvPythonPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".local/share/just-aloud/venv/bin/python3")
    }

    private var ttsServerPath: String {
        ((speakPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("just-aloud-tts-server.py")
    }

    private func startTTSDaemon() {
        guard needsDaemon else { return }
        if let existing = ttsDaemonProcess, existing.isRunning { return }

        let python = venvPythonPath
        let server = ttsServerPath

        guard FileManager.default.isExecutableFile(atPath: python),
              FileManager.default.fileExists(atPath: server) else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = [server, "--managed"]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            ttsDaemonProcess = task
        } catch {
            // Daemon failed to start — speak.sh will fall back to direct invocation
        }
    }

    private func stopTTSDaemon() {
        guard let process = ttsDaemonProcess, process.isRunning else {
            ttsDaemonProcess = nil
            return
        }
        process.terminate()  // sends SIGTERM → daemon cleans up and exits
        ttsDaemonProcess = nil
    }

    private func updateTTSDaemon() {
        if needsDaemon {
            startTTSDaemon()
        } else {
            stopTTSDaemon()
        }
    }

    private func stopSpeaking() {
        try? FileManager.default.removeItem(atPath: audioControlPath)
        killCurrentProcess()
        terminateExternalSpeech()
        speakLock.lock()
        isSpeakingFlag = false
        speakLock.unlock()
        DispatchQueue.main.async { self.setSpeaking(false) }
    }

    private func sendAudioControl(_ command: String) {
        try? (command + "\n").write(
            toFile: audioControlPath, atomically: true, encoding: .utf8)
    }

    @objc private func togglePlaybackPause() {
        guard isSpeechActive else { return }
        isPlaybackPaused.toggle()
        sendAudioControl(isPlaybackPaused ? "pause" : "play")
        setSpeaking(true)
    }

    @objc private func seekBackward() { sendAudioControl("seek:-10") }
    @objc private func seekForward()  { sendAudioControl("seek:10") }
    @objc private func stopPlayback() { stopSpeaking() }

    private var isSpeechActive: Bool {
        speakLock.lock()
        let managed = isSpeakingFlag
        speakLock.unlock()
        if managed { return true }
        guard let rawPID = try? String(contentsOfFile: speechPIDPath, encoding: .utf8),
              let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else { return false }
        return Darwin.kill(pid, 0) == 0
    }

    private func terminateExternalSpeech() {
        guard let rawPID = try? String(contentsOfFile: speechPIDPath, encoding: .utf8),
              let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else { return }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(pid), "-o", "command="]
        let output = Pipe()
        ps.standardOutput = output
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return }
        ps.waitUntilExit()
        let command = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard command.contains("just-aloud") else { return }
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-P", String(pid)]
        try? pkill.run()
        pkill.waitUntilExit()
        Darwin.kill(pid, SIGTERM)
    }

    private func mediaButton(symbol: String, pointSize: CGFloat, label: String, action: Selector) -> NSButton {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 36),
            button.heightAnchor.constraint(equalToConstant: 36)
        ])
        return button
    }

    private func buildMediaControlsItem() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 252, height: 52))
        let back = mediaButton(symbol: "gobackward.10", pointSize: 18, label: "Back 10 seconds", action: #selector(seekBackward))
        let playPause = mediaButton(symbol: isPlaybackPaused ? "play.circle.fill" : "pause.circle.fill", pointSize: 25, label: isPlaybackPaused ? "Resume" : "Pause", action: #selector(togglePlaybackPause))
        let forward = mediaButton(symbol: "goforward.10", pointSize: 18, label: "Forward 10 seconds", action: #selector(seekForward))
        let stop = mediaButton(symbol: "stop.fill", pointSize: 15, label: "Stop", action: #selector(stopPlayback))
        playPauseButton = playPause
        playbackButtons = [back, playPause, forward, stop]
        let stack = NSStackView(views: playbackButtons)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        let menuItem = NSMenuItem()
        menuItem.view = container
        updateMediaControls()
        return menuItem
    }

    private func updateMediaControls() {
        playbackButtons.forEach { $0.isEnabled = isSpeechActive }
        let symbol = isPlaybackPaused ? "play.circle.fill" : "pause.circle.fill"
        let label = isPlaybackPaused ? "Resume" : "Pause"
        let configuration = NSImage.SymbolConfiguration(pointSize: 25, weight: .medium)
        playPauseButton?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(configuration)
        playPauseButton?.toolTip = label
        playPauseButton?.setAccessibilityLabel(label)
    }

    func calculateRemainingText() -> String? {
        let tmpDir = NSTemporaryDirectory()
        let textPath = (tmpDir as NSString).appendingPathComponent("just_aloud_text")
        let statusPath = (tmpDir as NSString).appendingPathComponent("just_aloud_status")

        guard let text = try? String(contentsOfFile: textPath, encoding: .utf8),
              !text.isEmpty else {
            return nil
        }

        guard let statusStr = try? String(contentsOfFile: statusPath, encoding: .utf8) else {
            return text  // no status file (still generating) → restart from beginning
        }

        let lines = statusStr.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        guard lines.count >= 2,
              let startTime = TimeInterval(lines[0]),
              let duration = TimeInterval(lines[1]),
              duration > 0 else {
            return text  // invalid status → restart from beginning
        }

        let elapsed = Date().timeIntervalSince1970 - startTime
        let ratio = min(max(elapsed / duration, 0), 1)

        // For short texts, restart from beginning
        if text.count < 100 { return text }

        // Use per-sentence offset from 4-line STATUS_FILE when available
        let approxCharPos: Int
        if lines.count >= 4,
           let charOffset = Int(lines[2]),
           let sentenceLen = Int(lines[3]),
           sentenceLen > 0 {
            approxCharPos = charOffset + Int(Double(sentenceLen) * ratio)
        } else {
            approxCharPos = Int(Double(text.count) * ratio)
        }

        // Near the end of the full text — restart from beginning
        if approxCharPos >= text.count - 50 { return text }

        // Find the nearest sentence boundary at or after approxCharPos
        let searchStart = max(0, approxCharPos - 20)
        let startIdx = text.index(text.startIndex, offsetBy: min(searchStart, text.count))
        let searchStr = String(text[startIdx...])

        // Look for sentence boundaries: .!? followed by whitespace, or newline
        var bestOffset: Int? = nil
        let chars = Array(searchStr.unicodeScalars)
        for i in 0..<chars.count {
            let absPos = searchStart + i
            guard absPos >= approxCharPos else { continue }
            if i > 0 && (chars[i-1] == "." || chars[i-1] == "!" || chars[i-1] == "?") &&
               (chars[i] == " " || chars[i] == "\n" || chars[i] == "\t") {
                bestOffset = absPos
                break
            }
            if chars[i] == "\n" && i + 1 < chars.count {
                bestOffset = absPos + 1
                break
            }
            // Don't search too far — 200 chars max
            if absPos - approxCharPos > 200 {
                bestOffset = approxCharPos
                break
            }
        }

        let resumePos = bestOffset ?? approxCharPos
        guard resumePos < text.count else { return text }
        let resumeIdx = text.index(text.startIndex, offsetBy: resumePos)
        let remaining = String(text[resumeIdx...]).trimmingCharacters(in: .whitespaces)
        return remaining.isEmpty ? text : remaining
    }

    func respeak() {
        let remainingText = calculateRemainingText()
        killCurrentProcess()
        // Brief delay to let the old process clean up
        Thread.sleep(forTimeInterval: 0.05)
        runSpeak(withText: remainingText)
    }

    func scheduleRespeak() {
        speakLock.lock()
        let speaking = isSpeakingFlag
        speakLock.unlock()
        guard speaking else { return }

        DispatchQueue.main.async { [self] in
            respeakTimer?.invalidate()
            respeakTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                DispatchQueue.global(qos: .userInitiated).async {
                    self?.respeak()
                }
            }
        }
    }

    // MARK: - Keychain helpers

    private func readAPIKey() -> String? {
        guard let data = keychainData(account: "just-aloud", service: "just-aloud-api-key") else {
            return nil
        }
        let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (key?.isEmpty ?? true) ? nil : key
    }

    private func saveAPIKey(_ key: String) {
        saveKeychainData(Data(key.utf8), account: "just-aloud", service: "just-aloud-api-key")
    }

    private func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "just-aloud",
            kSecAttrService as String: "just-aloud-api-key",
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func keychainData(account: String, service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private func saveKeychainData(_ data: Data, account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
        ]
        let update = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(buildMediaControlsItem())
        menu.addItem(.separator())

        // Backend submenu — always visible so users can discover and switch
        menu.addItem(submenuItem("Backend", items: buildBackendItems()))
        menu.addItem(.separator())

        let showEl      = config.ttsBackend == "auto" || config.ttsBackend == "elevenlabs"
        let showLocal   = config.ttsBackend == "local" ||
                          (config.ttsBackend == "auto" && isLocalInstalled)
        let showHeaders = showEl && showLocal

        // ── ElevenLabs section ──
        if showEl {
            if showHeaders { menu.addItem(hintItem("ElevenLabs")) }
            menu.addItem(submenuItem("Voice", items: buildVoiceItems()))
            menu.addItem(buildElSpeedSliderItem())
            menu.addItem(submenuItem("Model", items: buildModelItems()))
            menu.addItem(submenuItem("Stability", items: buildStabilityItems()))
            menu.addItem(submenuItem("Similarity", items: buildSimilarityItems()))
            menu.addItem(submenuItem("Style", items: buildStyleItems()))
            let boost = NSMenuItem(
                title:  "Speaker Boost",
                action: #selector(toggleSpeakerBoost),
                keyEquivalent: "")
            boost.target = self
            boost.state = config.useSpeakerBoost ? .on : .off
            menu.addItem(boost)
            menu.addItem(.separator())
        }

        // ── Local (Kokoro) section ──
        if showLocal {
            if showHeaders { menu.addItem(hintItem("Local (Kokoro)")) }
            menu.addItem(submenuItem("Voice", items: buildLocalVoiceItems()))
            menu.addItem(submenuItem("Speed", items: buildLocalSpeedItems()))
            menu.addItem(.separator())
        }

        // Playback-level setting shared by all backends. The selected value is
        // real elapsed silence and does not shrink at faster playback speeds.
        menu.addItem(submenuItem(
            "Sentence Pause: \(config.sentencePause) ms",
            items: buildSentencePauseItems()))
        menu.addItem(.separator())

        // API Key + Credits — when ElevenLabs is active
        if showEl {
            // Credits display (hidden until successfully fetched)
            let creditsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            creditsItem.tag = 999
            creditsItem.isEnabled = false
            creditsItem.isHidden = true
            menu.addItem(creditsItem)

            let apiItem = NSMenuItem(
                title:  "API Key\u{2026}",
                action: #selector(manageAPIKey),
                keyEquivalent: "")
            apiItem.target = self
            menu.addItem(apiItem)
        }

        menu.addItem(.separator())

        if !AXIsProcessTrusted() {
            let warn = NSMenuItem(
                title:          "⚠️  Enable Accessibility for ⌥⇧/",
                action:         #selector(requestAccessibility),
                keyEquivalent:  "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let about = NSMenuItem(title: "About Just Aloud",
                               action: #selector(showAbout),
                               keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit Just Aloud",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    // MARK: Menu builders

    private func buildBackendItems() -> [NSMenuItem] {
        [
            item("Auto", #selector(pickBackend(_:)),
                 repr: "auto", on: config.ttsBackend == "auto"),
            item("ElevenLabs", #selector(pickBackend(_:)),
                 repr: "elevenlabs", on: config.ttsBackend == "elevenlabs"),
            item("Local (Kokoro)", #selector(pickBackend(_:)),
                 repr: "local", on: config.ttsBackend == "local"),
        ]
    }

    private func buildVoiceItems() -> [NSMenuItem] {
        cloudVoiceIndicators.removeAll()
        cloudVoiceSelectionButtons.removeAll()
        var items = knownVoices.map { voice in
            defaultVoiceItem(id: voice.id, name: voice.name, on: voice.id == config.voiceId)
        }
        items.append(contentsOf: config.customVoiceIds.map { id in
            customVoiceItem(id: id, name: config.customVoiceNames[id], on: id == config.voiceId)
        })
        items.append(.separator())
        items.append(item("Add Custom Voice ID…", #selector(customVoice), repr: "", on: false))
        return items
    }

    private func defaultVoiceItem(id: String, name: String, on: Bool) -> NSMenuItem {
        let menuItem = NSMenuItem()
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 344, height: 28))

        let indicator = NSImageView(frame: NSRect(x: 16, y: 7, width: 14, height: 14))
        indicator.image = voiceRadioImage(active: on)
        indicator.contentTintColor = on ? .controlAccentColor : .tertiaryLabelColor
        indicator.imageScaling = .scaleProportionallyDown
        row.addSubview(indicator)
        cloudVoiceIndicators[id] = indicator

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.frame = NSRect(x: 38, y: 5, width: 286, height: 18)
        nameLabel.font = NSFont.menuFont(ofSize: 13)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        row.addSubview(nameLabel)

        let selectButton = VoiceActionButton(frame: NSRect(x: 10, y: 0, width: 324, height: 28))
        selectButton.voiceId = id
        selectButton.target = self
        selectButton.action = #selector(pickCloudVoice(_:))
        selectButton.isBordered = false
        selectButton.title = ""
        selectButton.toolTip = "Use \(name)"
        selectButton.setAccessibilityLabel("\(on ? "Active" : "Inactive") voice \(name)")
        row.addSubview(selectButton)
        cloudVoiceSelectionButtons.append(selectButton)

        menuItem.view = row
        return menuItem
    }

    private func customVoiceItem(id: String, name: String?, on: Bool) -> NSMenuItem {
        let menuItem = NSMenuItem()
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 344, height: 44))

        let displayName: String
        if let name, !name.isEmpty {
            displayName = name
        } else if voiceNameFetchesInFlight.contains(id) {
            displayName = "Fetching voice name…"
        } else {
            displayName = "Voice name unavailable"
        }
        let indicator = NSImageView(frame: NSRect(x: 16, y: 25, width: 14, height: 14))
        indicator.image = voiceRadioImage(active: on)
        indicator.contentTintColor = on ? .controlAccentColor : .tertiaryLabelColor
        indicator.imageScaling = .scaleProportionallyDown
        row.addSubview(indicator)
        cloudVoiceIndicators[id] = indicator

        let nameLabel = NSTextField(labelWithString: displayName)
        nameLabel.frame = NSRect(x: 38, y: 23, width: 250, height: 18)
        nameLabel.font = NSFont.menuFont(ofSize: 13)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.toolTip = displayName
        row.addSubview(nameLabel)

        let selectButton = VoiceActionButton(frame: NSRect(x: 10, y: 20, width: 282, height: 23))
        selectButton.voiceId = id
        selectButton.target = self
        selectButton.action = #selector(pickCloudVoice(_:))
        selectButton.isBordered = false
        selectButton.title = ""
        selectButton.toolTip = "Use \(displayName)"
        selectButton.setAccessibilityLabel(
            "\(on ? "Active" : "Inactive") voice \(displayName), ID \(id)")
        row.addSubview(selectButton)
        cloudVoiceSelectionButtons.append(selectButton)

        let copyButton = VoiceActionButton(frame: NSRect(x: 38, y: 4, width: 250, height: 18))
        copyButton.voiceId = id
        copyButton.target = self
        copyButton.action = #selector(copyCustomVoiceID(_:))
        copyButton.isBordered = false
        copyButton.alignment = .left
        copyButton.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.title = id
        copyButton.image = NSImage(
            systemSymbolName: "doc.on.doc",
            accessibilityDescription: "Copy voice ID")
        copyButton.imagePosition = .imageLeading
        copyButton.toolTip = "Copy voice ID"
        copyButton.setAccessibilityLabel("Copy voice ID \(id)")
        row.addSubview(copyButton)

        let removeButton = VoiceActionButton(frame: NSRect(x: 308, y: 10, width: 20, height: 24))
        removeButton.voiceId = id
        removeButton.target = self
        removeButton.action = #selector(removeCustomVoice(_:))
        removeButton.isBordered = false
        removeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Remove custom voice")
        removeButton.imagePosition = .imageOnly
        removeButton.contentTintColor = .tertiaryLabelColor
        removeButton.toolTip = "Remove \(displayName)"
        removeButton.setAccessibilityLabel("Remove voice \(displayName)")
        row.addSubview(removeButton)

        menuItem.view = row
        return menuItem
    }

    private func buildLocalVoiceItems() -> [NSMenuItem] {
        kokoroVoices.map { v in
            voiceChoiceItem(v.name, #selector(pickLocalVoice(_:)),
                            repr: v.id, on: v.id == config.localVoice)
        }
    }

    private func buildModelItems() -> [NSMenuItem] {
        knownModels.map { m in
            item(m.name, #selector(pickModel(_:)), repr: m.id, on: m.id == config.modelId)
        }
    }

    private func buildElSpeedSliderItem() -> NSMenuItem {
        let menuItem = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 66))
        let effectiveSpeed = min(max(config.speed * config.playbackSpeed,
                                     minEffectiveSpeed), maxEffectiveSpeed)

        let valueLabel = NSTextField(labelWithString:
            "Speed  \(String(format: "%.2f", effectiveSpeed))×")
        valueLabel.frame = NSRect(x: 18, y: 40, width: 150, height: 18)
        valueLabel.font = NSFont.menuFont(ofSize: 13)
        valueLabel.tag = 4101
        view.addSubview(valueLabel)

        let reset = NSButton(title: "Reset", target: self, action: #selector(resetSpeed(_:)))
        reset.frame = NSRect(x: 214, y: 36, width: 54, height: 24)
        reset.bezelStyle = .inline
        reset.font = NSFont.menuFont(ofSize: 11)
        view.addSubview(reset)

        let slider = NSSlider(value: effectiveSpeed,
                              minValue: minEffectiveSpeed,
                              maxValue: maxEffectiveSpeed,
                              target: self,
                              action: #selector(speedSliderChanged(_:)))
        slider.frame = NSRect(x: 40, y: 12, width: 198, height: 22)
        slider.isContinuous = true
        slider.altIncrementValue = speedStep
        slider.setAccessibilityLabel("Just Aloud playback speed")
        slider.setAccessibilityValueDescription(String(format: "%.2f times", effectiveSpeed))
        view.addSubview(slider)

        let slow = NSTextField(labelWithString: "0.7×")
        slow.frame = NSRect(x: 9, y: 14, width: 34, height: 16)
        slow.font = NSFont.menuFont(ofSize: 10)
        slow.textColor = .secondaryLabelColor
        view.addSubview(slow)

        let fast = NSTextField(labelWithString: "3×")
        fast.frame = NSRect(x: 242, y: 14, width: 28, height: 16)
        fast.font = NSFont.menuFont(ofSize: 10)
        fast.textColor = .secondaryLabelColor
        view.addSubview(fast)

        menuItem.view = view
        return menuItem
    }

    private func buildLocalSpeedItems() -> [NSMenuItem] {
        localSpeedSteps.map { s in
            item(s.label, #selector(pickLocalSpeed(_:)),
                 repr: String(s.value), on: abs(s.value - config.localSpeed) < 0.01)
        }
    }

    private func buildSentencePauseItems() -> [NSMenuItem] {
        var items = sentencePauseSteps.map { step in
            item(step.label, #selector(pickSentencePause(_:)),
                 repr: String(step.value), on: step.value == config.sentencePause)
        }
        items.append(.separator())
        let isCustom = !sentencePauseSteps.contains { $0.value == config.sentencePause }
        items.append(item(
            isCustom ? "Custom… (\(config.sentencePause) ms)" : "Custom…",
            #selector(editSentencePause), repr: "", on: isCustom))
        return items
    }

    private func buildStabilityItems() -> [NSMenuItem] {
        var items = [hintItem("Lower = expressive · Higher = steady"), .separator()]
        items += stabilitySteps.map { s in
            item(s.label, #selector(pickStability(_:)),
                 repr: String(s.value), on: abs(s.value - config.stability) < 0.01)
        }
        return items
    }

    private func buildSimilarityItems() -> [NSMenuItem] {
        var items = [hintItem("How closely output matches the original voice"), .separator()]
        items += similaritySteps.map { s in
            item(s.label, #selector(pickSimilarity(_:)),
                 repr: String(s.value), on: abs(s.value - config.similarityBoost) < 0.01)
        }
        return items
    }

    private func buildStyleItems() -> [NSMenuItem] {
        var items = [hintItem("Amplifies characteristic delivery · adds latency"), .separator()]
        items += styleSteps.map { s in
            item(s.label, #selector(pickStyle(_:)),
                 repr: String(s.value), on: abs(s.value - config.style) < 0.01)
        }
        return items
    }

    // MARK: Helpers

    private func hintItem(_ text: String) -> NSMenuItem {
        let i = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func item(_ title: String, _ action: Selector,
                      repr: String, on: Bool) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.representedObject = repr
        i.state = on ? .on : .off
        return i
    }

    private func voiceChoiceItem(_ title: String, _ action: Selector,
                                 repr: String, on: Bool) -> NSMenuItem {
        let i = item(title, action, repr: repr, on: on)
        i.onStateImage = voiceRadioImage(active: true)
        i.offStateImage = voiceRadioImage(active: false)
        return i
    }

    private func voiceRadioImage(active: Bool) -> NSImage? {
        let size = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        let color = NSImage.SymbolConfiguration(
            paletteColors: [active ? .controlAccentColor : .tertiaryLabelColor])
        return NSImage(
            systemSymbolName: active ? "circle.inset.filled" : "circle",
            accessibilityDescription: active ? "Active" : "Inactive")?
            .withSymbolConfiguration(size.applying(color))
    }

    private func submenuItem(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        items.forEach { sub.addItem($0) }
        parent.submenu = sub
        return parent
    }

    // MARK: Backend setup helpers

    private var isAppleSilicon: Bool {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }.hasPrefix("arm64")
    }

    private var isLocalInstalled: Bool {
        config.backendsInstalled == "local" || config.backendsInstalled == "both"
    }

    private var installLocalPath: String {
        ((speakPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("just-aloud-install-local")
    }

    /// Show "Install Local TTS" dialog. Returns true if user clicked Install.
    private func offerLocalInstall(skipLabel: String = "Cancel") -> Bool {
        guard isAppleSilicon else {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Apple Silicon Required"
            a.informativeText = "Local TTS (Kokoro) requires an Apple Silicon Mac (M1 or later)."
            a.alertStyle = .warning
            a.addButton(withTitle: "OK")
            a.runModal()
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Install Local TTS"
        alert.informativeText = "This will install mlx-audio and download the Kokoro voice model (~350 MB)."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: skipLabel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Run install-local.sh in background. On success, reload config, set
    /// desiredBackend (because install-local.sh forces TTS_BACKEND="local"),
    /// and rebuild the menu.
    private func runInstallLocal(desiredBackend: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [installLocalPath]
            task.standardOutput = FileHandle.nullDevice
            task.standardError  = FileHandle.nullDevice
            do { try task.run() } catch {
                DispatchQueue.main.async { completion(false) }
                return
            }
            task.waitUntilExit()
            let success = task.terminationStatus == 0
            DispatchQueue.main.async { [self] in
                if success {
                    config = Config.load()
                    config.ttsBackend = desiredBackend
                    config.save()
                    rebuildMenu()
                }
                completion(success)
            }
        }
    }

    private func showInstallResult(success: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        if success {
            a.messageText = "Local TTS Installed"
            a.informativeText = "mlx-audio and the Kokoro model are ready."
        } else {
            a.messageText = "Installation Failed"
            a.informativeText = "Could not install local TTS.\n\nAn internet connection is required for the first install.\nPlease check your connection and try again."
            a.alertStyle = .warning
        }
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    // MARK: Actions

    @objc private func pickBackend(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }

        if id == "elevenlabs" {
            // ElevenLabs requires an API key
            if readAPIKey() == nil {
                if !showAPIKeyDialog(forBackendSwitch: true) { return }
            }
        } else if id == "local" {
            // Local requires mlx-audio installed
            if !isLocalInstalled {
                if !offerLocalInstall(skipLabel: "Cancel") { return }
                // User accepted — install in background, switch now
                config.ttsBackend = id
                config.save()
                rebuildMenu()
                scheduleRespeak()
                runInstallLocal(desiredBackend: id) { [weak self] ok in
                    self?.showInstallResult(success: ok)
                    self?.updateTTSDaemon()
                }
                return
            }
        } else {
            // auto — ensure at least one backend is available
            let hasKey   = readAPIKey() != nil
            let hasLocal = isLocalInstalled

            if !hasKey && !hasLocal {
                // Neither ready — need at least one
                if !showAPIKeyDialog(forBackendSwitch: true) {
                    // Skipped API key — try local install
                    if offerLocalInstall(skipLabel: "Cancel") {
                        config.ttsBackend = id
                        config.save()
                        rebuildMenu()
                        runInstallLocal(desiredBackend: id) { [weak self] ok in
                            self?.showInstallResult(success: ok)
                            self?.updateTTSDaemon()
                        }
                        return
                    }
                    return  // both skipped — don't switch
                }
            } else if !hasKey {
                // Has local, missing API key — soft prompt (Skip is fine)
                showAPIKeyDialog(forBackendSwitch: true, optional: true)
            } else if !hasLocal {
                // Has API key, missing local — offer install (Not Now is fine)
                if offerLocalInstall(skipLabel: "Not Now") {
                    config.ttsBackend = id
                    config.save()
                    rebuildMenu()
                    scheduleRespeak()
                    runInstallLocal(desiredBackend: id) { [weak self] ok in
                        self?.showInstallResult(success: ok)
                        self?.updateTTSDaemon()
                    }
                    return
                }
                // User chose "Not Now" — auto degrades to ElevenLabs-only
            }
        }

        config.ttsBackend = id
        config.save()
        rebuildMenu()
        scheduleRespeak()
        updateTTSDaemon()
    }

    @objc private func pickCloudVoice(_ sender: VoiceActionButton) {
        guard !sender.voiceId.isEmpty else { return }
        config.voiceId = sender.voiceId
        config.save()
        updateCloudVoiceSelectionIndicators()
        scheduleRespeak()
    }

    private func updateCloudVoiceSelectionIndicators() {
        for (id, indicator) in cloudVoiceIndicators {
            let active = id == config.voiceId
            indicator.image = voiceRadioImage(active: active)
            indicator.contentTintColor = active ? .controlAccentColor : .tertiaryLabelColor
        }
        for button in cloudVoiceSelectionButtons {
            let active = button.voiceId == config.voiceId
            button.setAccessibilityLabel(
                "\(active ? "Active" : "Inactive") voice, ID \(button.voiceId)")
        }
    }

    @objc private func copyCustomVoiceID(_ sender: VoiceActionButton) {
        guard !sender.voiceId.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sender.voiceId, forType: .string)

        sender.title = "Copied"
        sender.image = NSImage(
            systemSymbolName: "checkmark",
            accessibilityDescription: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak sender] in
            guard let sender else { return }
            sender.title = sender.voiceId
            sender.image = NSImage(
                systemSymbolName: "doc.on.doc",
                accessibilityDescription: "Copy voice ID")
        }
    }

    @objc private func pickLocalVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        config.localVoice = id
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func customVoice() {
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(.accessory) }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add Custom Voice ID"
        alert.informativeText = "Enter a voice ID from elevenlabs.io/voice-library. Saved voices remain available in the Voice menu."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        field.isEditable = true
        field.isSelectable = true
        field.stringValue = ""
        field.placeholderString = "Paste your ElevenLabs voice ID"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let val = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !val.isEmpty else { return }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard val.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            let error = NSAlert()
            error.messageText = "Invalid Voice ID"
            error.informativeText = "Voice IDs may contain only letters, numbers, hyphens, and underscores."
            error.alertStyle = .warning
            error.runModal()
            return
        }
        if !config.customVoiceIds.contains(val) { config.customVoiceIds.append(val) }
        config.voiceId = val
        config.save()
        voiceNameFetchFailures.remove(val)
        refreshVoiceNames()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func removeCustomVoice(_ sender: VoiceActionButton) {
        let id = sender.voiceId
        guard !id.isEmpty else { return }
        statusItem.menu?.cancelTracking()
        let wasActive = config.voiceId == id
        config.customVoiceIds.removeAll { $0 == id }
        config.customVoiceNames.removeValue(forKey: id)
        voiceNameFetchFailures.remove(id)
        if wasActive { config.voiceId = knownVoices.first?.id ?? "" }
        config.save()
        rebuildMenu()
        if wasActive && !config.voiceId.isEmpty { scheduleRespeak() }
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        config.modelId = id
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    private func setEffectiveSpeed(_ rawValue: Double) {
        let bounded = min(max(rawValue, minEffectiveSpeed), maxEffectiveSpeed)
        let value = (bounded / speedStep).rounded() * speedStep
        config.speed = min(value, 1.2)
        config.playbackSpeed = value / config.speed
        config.save()
    }

    @objc private func speedSliderChanged(_ sender: NSSlider) {
        setEffectiveSpeed(sender.doubleValue)
        let effectiveSpeed = config.speed * config.playbackSpeed
        sender.doubleValue = effectiveSpeed
        sender.setAccessibilityValueDescription(String(format: "%.2f times", effectiveSpeed))
        if let label = sender.superview?.viewWithTag(4101) as? NSTextField {
            label.stringValue = "Speed  \(String(format: "%.2f", effectiveSpeed))×"
        }
    }

    @objc private func resetSpeed(_ sender: NSButton) {
        setEffectiveSpeed(1.0)
        guard let view = sender.superview,
              let slider = view.subviews.compactMap({ $0 as? NSSlider }).first else { return }
        slider.doubleValue = 1.0
        slider.setAccessibilityValueDescription("1.00 times")
        if let label = view.viewWithTag(4101) as? NSTextField {
            label.stringValue = "Speed  1.00×"
        }
    }

    @objc private func pickLocalSpeed(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let val = Double(str) else { return }
        config.localSpeed = val
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    private func setSentencePause(_ value: Int) {
        let bounded = min(max(value, 0), 5_000)
        config.sentencePause = bounded
        config.save()
        if isSpeechActive {
            sendAudioControl("sentence-pause:\(bounded)")
        }
        rebuildMenu()
    }

    @objc private func pickSentencePause(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let value = Int(rawValue) else { return }
        setSentencePause(value)
    }

    @objc private func editSentencePause() {
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(.accessory) }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Sentence Pause"
        alert.informativeText = "Milliseconds of actual silence between sentences. Enter a value from 0 to 5000."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        field.stringValue = String(config.sentencePause)
        field.placeholderString = "e.g. 400"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let value = Int(text), (0...5_000).contains(value) else {
            let error = NSAlert()
            error.messageText = "Invalid Sentence Pause"
            error.informativeText = "Enter a whole number from 0 to 5000 milliseconds."
            error.alertStyle = .warning
            error.runModal()
            return
        }
        setSentencePause(value)
    }

    @objc private func pickStability(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let val = Double(str) else { return }
        config.stability = val
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func pickSimilarity(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let val = Double(str) else { return }
        config.similarityBoost = val
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let str = sender.representedObject as? String,
              let val = Double(str) else { return }
        config.style = val
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    @objc private func toggleSpeakerBoost() {
        config.useSpeakerBoost.toggle()
        config.save()
        rebuildMenu()
        scheduleRespeak()
    }

    // MARK: - ElevenLabs voice names

    private func refreshVoiceNames(force: Bool = false) {
        guard let key = readAPIKey(), !key.isEmpty else { return }
        for id in config.customVoiceIds {
            guard !voiceNameFetchesInFlight.contains(id),
                  force || config.customVoiceNames[id] == nil else { continue }
            voiceNameFetchesInFlight.insert(id)
            voiceNameFetchFailures.remove(id)
            fetchVoiceName(id: id, apiKey: key)
        }
    }

    private func fetchVoiceName(id: String, apiKey: String) {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/voices/\(id)") else {
            voiceNameFetchesInFlight.remove(id)
            voiceNameFetchFailures.insert(id)
            return
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let name: String? = {
                guard let data, error == nil,
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let value = json["name"] as? String else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }()

            DispatchQueue.main.async {
                guard let self else { return }
                self.voiceNameFetchesInFlight.remove(id)
                guard self.config.customVoiceIds.contains(id) else { return }
                if let name {
                    self.config.customVoiceNames[id] = name
                    self.voiceNameFetchFailures.remove(id)
                    self.config.save()
                } else {
                    self.voiceNameFetchFailures.insert(id)
                }
                self.rebuildMenu()
            }
        }.resume()
    }

    // MARK: - Credits Display

    private func fetchCredits() {
        guard config.ttsBackend == "auto" || config.ttsBackend == "elevenlabs" else { return }
        guard let key = readAPIKey(), !key.isEmpty else { return }

        // Use cache if fresh (< 60s old)
        if let cached = cachedCredits, Date().timeIntervalSince(cached.fetchedAt) < 60 {
            updateCreditsMenuItem(used: cached.used, limit: cached.limit)
            return
        }

        guard let url = URL(string: "https://api.elevenlabs.io/v1/user/subscription") else { return }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data, error == nil,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let used = json["character_count"] as? Int,
                  let limit = json["character_limit"] as? Int else { return }

            self?.cachedCredits = (used: used, limit: limit, fetchedAt: Date())

            DispatchQueue.main.async {
                self?.updateCreditsMenuItem(used: used, limit: limit)
            }
        }.resume()
    }

    private func updateCreditsMenuItem(used: Int, limit: Int) {
        guard let menu = statusItem.menu,
              let creditsItem = menu.item(withTag: 999) else { return }
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        let remaining = max(limit - used, 0)
        let rStr = fmt.string(from: NSNumber(value: remaining)) ?? "\(remaining)"
        let lStr = fmt.string(from: NSNumber(value: limit)) ?? "\(limit)"
        creditsItem.title = "Credits: \(rStr) / \(lStr)"
        creditsItem.isHidden = false
    }

    // MARK: - About and safe migration

    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
        return "Version \(version) (\(build))"
    }

    private func welcomeSetupRow(
        symbol: String,
        title: String,
        detail: String,
        buttonTitle: String,
        action: Selector
    ) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: title
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        )
        icon.contentTintColor = .controlAccentColor
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)

        let explanation = NSTextField(wrappingLabelWithString: detail)
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 2

        let labels = NSStackView(views: [heading, explanation])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(title: buttonTitle, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [icon, labels, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            labels.widthAnchor.constraint(equalToConstant: 336),
            button.widthAnchor.constraint(equalToConstant: 138),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 58),
        ])
        return row
    }

    @objc private func showWelcome() {
        if let welcomeWindow {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            welcomeWindow.makeKeyAndOrderFront(nil)
            return
        }

        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 704),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "Welcome to Just Aloud"
        if ProcessInfo.processInfo.environment["JUST_ALOUD_UI_APPEARANCE"] == "light" {
            window.appearance = NSAppearance(named: .aqua)
        } else if ProcessInfo.processInfo.environment["JUST_ALOUD_UI_APPEARANCE"] == "dark" {
            window.appearance = NSAppearance(named: .darkAqua)
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        window.center()

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Welcome to Just Aloud")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        title.alignment = .center

        let creator = NSTextField(labelWithString: "Created and maintained by Kian Konrad Tajbakhsh")
        creator.font = .systemFont(ofSize: 13, weight: .medium)
        creator.textColor = .secondaryLabelColor
        creator.alignment = .center

        let summary = NSTextField(wrappingLabelWithString:
            "Just Aloud reads selected text from any Mac app and gives you native pause, resume, seek, speed, and voice controls from the menu bar.")
        summary.font = .systemFont(ofSize: 13)
        summary.alignment = .center
        summary.maximumNumberOfLines = 2
        summary.translatesAutoresizingMaskIntoConstraints = false

        let attribution = NSTextField(wrappingLabelWithString:
            "Based on Speak11, originally created by Stefano Martiniani. Just Aloud is an independent, unofficial derivative and is not affiliated with or endorsed by Speak11 or ElevenLabs.")
        attribution.font = .systemFont(ofSize: 11)
        attribution.textColor = .secondaryLabelColor
        attribution.alignment = .center
        attribution.maximumNumberOfLines = 3
        attribution.translatesAutoresizingMaskIntoConstraints = false

        let setupHeading = NSTextField(labelWithString: "Finish setup")
        setupHeading.font = .systemFont(ofSize: 15, weight: .semibold)

        let apiRow = welcomeSetupRow(
            symbol: "key.fill",
            title: "ElevenLabs API key",
            detail: "Optional for cloud voices. Your key is stored securely in macOS Keychain.",
            buttonTitle: "Set Up API Key…",
            action: #selector(welcomeConfigureAPIKey))
        let accessibilityRow = welcomeSetupRow(
            symbol: "accessibility",
            title: "Accessibility permission",
            detail: "Required only for the global ⌥⇧/ shortcut that reads selected text.",
            buttonTitle: "Enable…",
            action: #selector(welcomeRequestAccessibility))
        let migrationRow = welcomeSetupRow(
            symbol: "arrow.triangle.2.circlepath",
            title: "Speak11 settings",
            detail: "Optionally copy compatible settings and your Keychain credential. Speak11 stays unchanged.",
            buttonTitle: "Migrate…",
            action: #selector(migrateFromSpeak11))

        let setupStack = NSStackView(views: [setupHeading, apiRow, accessibilityRow, migrationRow])
        setupStack.orientation = .vertical
        setupStack.alignment = .leading
        setupStack.spacing = 9
        setupStack.translatesAutoresizingMaskIntoConstraints = false

        let privacyHeading = NSTextField(labelWithString: "Privacy")
        privacyHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        let privacyText = NSTextField(wrappingLabelWithString:
            "Selected text is sent to ElevenLabs only when cloud synthesis is used. Local TTS stays on this Mac. Just Aloud includes no analytics or telemetry.")
        privacyText.font = .systemFont(ofSize: 12)
        privacyText.textColor = .secondaryLabelColor
        privacyText.maximumNumberOfLines = 2
        privacyText.translatesAutoresizingMaskIntoConstraints = false
        let privacyStack = NSStackView(views: [privacyHeading, privacyText])
        privacyStack.orientation = .vertical
        privacyStack.alignment = .leading
        privacyStack.spacing = 3

        let source = NSButton(title: "Source Repository", target: self, action: #selector(openSourceRepository))
        let license = NSButton(title: "View License", target: self, action: #selector(openSoftwareLicense))
        let attributionButton = NSButton(title: "View Attribution", target: self, action: #selector(openAttribution))
        let thirdParty = NSButton(title: "Third-Party Licenses", target: self, action: #selector(openThirdPartyLicenses))
        for button in [source, license, attributionButton, thirdParty] {
            button.bezelStyle = .inline
            button.controlSize = .small
        }
        let links = NSStackView(views: [source, license, attributionButton, thirdParty])
        links.orientation = .horizontal
        links.alignment = .centerY
        links.spacing = 8
        links.distribution = .fillEqually

        let finish = NSButton(title: "Start Using Just Aloud", target: self, action: #selector(finishWelcome))
        finish.bezelStyle = .rounded
        finish.controlSize = .large
        finish.keyEquivalent = "\r"
        finish.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, title, creator, summary, attribution, setupStack, privacyStack, links, finish])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(16, after: attribution)
        stack.setCustomSpacing(15, after: setupStack)
        stack.setCustomSpacing(16, after: links)
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 640),
            content.heightAnchor.constraint(equalToConstant: 704),
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            summary.widthAnchor.constraint(equalToConstant: 540),
            attribution.widthAnchor.constraint(equalToConstant: 540),
            setupStack.widthAnchor.constraint(equalToConstant: 540),
            privacyStack.widthAnchor.constraint(equalToConstant: 540),
            privacyText.widthAnchor.constraint(equalToConstant: 540),
            links.widthAnchor.constraint(equalToConstant: 540),
            finish.widthAnchor.constraint(greaterThanOrEqualToConstant: 210),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -40),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
        ])

        welcomeWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func welcomeConfigureAPIKey() {
        _ = showAPIKeyDialog(forBackendSwitch: false, optional: true)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func welcomeRequestAccessibility() {
        requestAccessibility()
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func finishWelcome() {
        welcomeDefaults.set(true, forKey: welcomeCompletionKey)
        welcomeDefaults.synchronize()
        welcomeWindow?.close()
    }

    @objc private func showAbout() {
        if let aboutWindow {
            NSApp.activate(ignoringOtherApps: true)
            aboutWindow.makeKeyAndOrderFront(nil)
            return
        }

        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "About Just Aloud"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        let title = NSTextField(labelWithString: "Just Aloud")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.alignment = .center

        let version = NSTextField(labelWithString: versionString)
        version.textColor = .secondaryLabelColor
        version.alignment = .center

        let creator = NSTextField(wrappingLabelWithString:
            "Created and maintained by Kian Konrad Tajbakhsh.\n\n" +
            "Based on Speak11, originally created by Stefano Martiniani.\n\n" +
            "Just Aloud is an independent, unofficial derivative and is not affiliated with or endorsed by the original Speak11 project or ElevenLabs.")
        creator.alignment = .center
        creator.maximumNumberOfLines = 0

        let source = NSButton(title: "Source Repository", target: self, action: #selector(openSourceRepository))
        let license = NSButton(title: "Software License", target: self, action: #selector(openSoftwareLicense))
        let attribution = NSButton(title: "Attribution", target: self, action: #selector(openAttribution))
        let thirdParty = NSButton(title: "Third-Party Licenses", target: self, action: #selector(openThirdPartyLicenses))
        let copyVersion = NSButton(title: "Copy Version Information", target: self, action: #selector(copyVersionInformation))
        let migrate = NSButton(title: "Migrate from Speak11…", target: self, action: #selector(migrateFromSpeak11))
        for button in [source, license, attribution, thirdParty, copyVersion, migrate] {
            button.bezelStyle = .rounded
        }

        let linkRow = NSStackView(views: [source, license, attribution, thirdParty])
        linkRow.orientation = .horizontal
        linkRow.spacing = 8
        linkRow.distribution = .fillEqually

        let welcome = NSButton(title: "Welcome & Setup…", target: self, action: #selector(showWelcome))
        welcome.bezelStyle = .rounded

        let actionRow = NSStackView(views: [copyVersion, migrate, welcome])
        actionRow.orientation = .horizontal
        actionRow.spacing = 8
        actionRow.distribution = .fillEqually

        let stack = NSStackView(views: [icon, title, version, creator, linkRow, actionRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 620),
            content.heightAnchor.constraint(equalToConstant: 520),
            icon.widthAnchor.constraint(equalToConstant: 112),
            icon.heightAnchor.constraint(equalToConstant: 112),
            creator.widthAnchor.constraint(equalToConstant: 550),
            linkRow.widthAnchor.constraint(equalToConstant: 560),
            actionRow.widthAnchor.constraint(equalToConstant: 560),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        aboutWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openSourceRepository() {
        NSWorkspace.shared.open(URL(string: "https://github.com/Kian-hdr/just-aloud")!)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        if closingWindow === aboutWindow,
           welcomeWindow?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        } else if closingWindow === welcomeWindow,
                  aboutWindow?.isVisible != true {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func openBundledDocument(_ name: String, extension ext: String? = "md", fallbackURL: String) {
        if let path = Bundle.main.path(forResource: name, ofType: ext) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if let url = URL(string: fallbackURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openSoftwareLicense() {
        openBundledDocument("LICENSE", extension: nil,
                            fallbackURL: "https://github.com/Kian-hdr/just-aloud/blob/main/LICENSE")
    }

    @objc private func openAttribution() {
        openBundledDocument("ATTRIBUTION", fallbackURL: "https://github.com/Kian-hdr/just-aloud/blob/main/ATTRIBUTION.md")
    }

    @objc private func openThirdPartyLicenses() {
        openBundledDocument("THIRD_PARTY_NOTICES", fallbackURL: "https://github.com/Kian-hdr/just-aloud/blob/main/THIRD_PARTY_NOTICES.md")
    }

    @objc private func copyVersionInformation() {
        let value = "Just Aloud \(versionString) • macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func migrateFromSpeak11() {
        struct MigrationSource {
            let label: String
            let configPath: String
            let keychainAccount: String
            let keychainService: String
        }
        let home = NSHomeDirectory() as NSString
        let candidates = [
            MigrationSource(
                label: "Speak11 Enhanced",
                configPath: home.appendingPathComponent(".config/speak11-enhanced/config"),
                keychainAccount: "speak11-enhanced",
                keychainService: "speak11-enhanced-api-key"),
            MigrationSource(
                label: "Speak11",
                configPath: home.appendingPathComponent(".config/speak11/config"),
                keychainAccount: "speak11",
                keychainService: "speak11-api-key"),
        ]
        guard let source = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.configPath) ||
            keychainData(account: $0.keychainAccount, service: $0.keychainService) != nil
        }) else {
            let alert = NSAlert()
            alert.messageText = "No Speak11 settings found"
            alert.informativeText = "The original installation was not changed."
            alert.runModal()
            return
        }

        let confirmation = NSAlert()
        confirmation.messageText = "Migrate from \(source.label)?"
        confirmation.informativeText =
            "This copies compatible settings and the ElevenLabs credential into Just Aloud. " +
            "It does not reveal the key, modify the original Keychain item, or uninstall the original app."
        confirmation.addButton(withTitle: "Migrate")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        if FileManager.default.fileExists(atPath: source.configPath) {
            config = Config.load(from: source.configPath)
            config.save()
        }
        if let keyData = keychainData(account: source.keychainAccount, service: source.keychainService) {
            saveKeychainData(keyData, account: "just-aloud", service: "just-aloud-api-key")
        }
        refreshVoiceNames(force: true)
        rebuildMenu()
        updateTTSDaemon()

        let result = NSAlert()
        result.messageText = "Migration complete"
        result.informativeText = "Just Aloud now has a private copy. \(source.label) remains installed and unchanged."
        result.runModal()
    }

    // MARK: - API Key Management

    @objc private func manageAPIKey() {
        showAPIKeyDialog(forBackendSwitch: false)
    }

    /// Validate an API key by calling /v1/user/subscription.
    /// Returns nil on success, or an error message on failure.
    private func validateAPIKey(_ key: String) -> String? {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/user/subscription") else {
            return "Could not build request URL."
        }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 10

        var result: String? = "Could not reach ElevenLabs. Check your internet connection."
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            if error != nil {
                result = "Could not reach ElevenLabs. Check your internet connection."
                return
            }
            guard let http = response as? HTTPURLResponse else {
                result = "Unexpected response from ElevenLabs."
                return
            }
            switch http.statusCode {
            case 200:
                result = nil
            case 401:
                result = "Invalid API key. Check that you copied the full key."
            case 403:
                result = "This key is missing required permissions.\nEnable Text-to-Speech and User Read at elevenlabs.io."
            default:
                result = "ElevenLabs returned HTTP \(http.statusCode). Try again later."
            }
        }.resume()
        sem.wait()
        return result
    }

    @discardableResult
    private func showAPIKeyDialog(forBackendSwitch: Bool, optional: Bool = false) -> Bool {
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(.accessory) }
        NSApp.activate(ignoringOtherApps: true)
        let existingKey = readAPIKey()

        let skipTitle = optional ? "Skip" : "Cancel"
        let baseMessage: String
        let baseInfo: String
        if optional {
            baseMessage = "Add ElevenLabs API Key"
            baseInfo = "Add your API key for cloud TTS.\nThe key needs Text-to-Speech and User Read permissions.\n\nWithout a key, Auto mode will use local TTS only."
        } else if forBackendSwitch {
            baseMessage = "ElevenLabs API Key Required"
            baseInfo = "Enter your ElevenLabs API key to use the cloud backend.\nThe key needs Text-to-Speech and User Read permissions."
        } else {
            baseMessage = "ElevenLabs API Key"
            baseInfo = "Enter or update your ElevenLabs API key.\nThe key needs Text-to-Speech and User Read permissions."
        }

        var errorMessage: String? = nil

        while true {
            let alert = NSAlert()
            alert.messageText = baseMessage
            if let err = errorMessage {
                alert.informativeText = err + "\n\n" + baseInfo
                alert.icon = NSImage(named: NSImage.cautionName)
            } else {
                alert.informativeText = baseInfo
            }
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: skipTitle)
            if !forBackendSwitch && !optional && existingKey != nil && errorMessage == nil {
                alert.addButton(withTitle: "Remove")
            }

            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
            if errorMessage == nil, let key = existingKey {
                if key.count > 8 {
                    let start = key.prefix(4)
                    let end = key.suffix(4)
                    field.placeholderString = "\(start)\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\(end)"
                } else {
                    field.placeholderString = "Current key set"
                }
            } else {
                field.placeholderString = "Paste your API key here"
            }
            alert.accessoryView = field
            alert.window.initialFirstResponder = field

            let response = alert.runModal()

            if response == .alertFirstButtonReturn {
                let val = field.stringValue.trimmingCharacters(in: .whitespaces)
                if val.isEmpty {
                    if existingKey != nil { return true }
                    errorMessage = "No key entered."
                    continue
                }
                if let err = validateAPIKey(val) {
                    errorMessage = err
                    continue
                }
                saveAPIKey(val)
                return true
            } else if response == .alertThirdButtonReturn {
                deleteAPIKey()
                return false
            }
            return false
        }
    }
}

// MARK: - Entry point

#if TESTING
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--inspect-config" {
    let inspected = Config.load(from: CommandLine.arguments[2])
    print("backend=\(inspected.ttsBackend)")
    print("custom_voice_count=\(inspected.customVoiceIds.count)")
    print("named_voice_count=\(inspected.customVoiceNames.count)")
    print("has_active_voice=\(!inspected.voiceId.isEmpty)")
    exit(0)
}
if CommandLine.arguments.count >= 3,
   CommandLine.arguments[1] == "--inspect-welcome-state",
   let isolatedDefaults = UserDefaults(suiteName: CommandLine.arguments[2]) {
    if CommandLine.arguments.count == 4,
       CommandLine.arguments[3] == "complete" {
        isolatedDefaults.set(true, forKey: welcomeCompletionKey)
        isolatedDefaults.synchronize()
    }
    print("should_show=\(!isolatedDefaults.bool(forKey: welcomeCompletionKey))")
    print("domain=\(CommandLine.arguments[2])")
    exit(0)
}
#endif

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
