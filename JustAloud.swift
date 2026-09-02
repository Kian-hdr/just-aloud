import Cocoa
import ApplicationServices
import CoreAudio
import Darwin
import Security
import ServiceManagement

// Explicit offline UI inspection mode. Normal launches are unaffected. Release
// screenshots use an isolated config/defaults suite and never real credentials.
private let offlinePreview = ProcessInfo.processInfo.environment["JUST_ALOUD_OFFLINE_PREVIEW"] == "1"

// MARK: - Config paths

private let configDir: String = {
    if let override = ProcessInfo.processInfo.environment["JUST_ALOUD_CONFIG_DIR"],
       !override.isEmpty { return override }
    return (NSHomeDirectory() as NSString).appendingPathComponent(".config/just-aloud")
}()
private let configPath = (configDir as NSString).appendingPathComponent("config")
private let speakPath: String = {
    if let bundled = Bundle.main.path(forResource: "just-aloud", ofType: nil) { return bundled }
    let userInstall = (NSHomeDirectory() as NSString)
        .appendingPathComponent(".local/bin/just-aloud")
    if FileManager.default.isExecutableFile(atPath: userInstall) { return userInstall }
    return Bundle.main.path(forResource: "just-aloud", ofType: nil) ?? userInstall
}()
private let playbackRuntimeDir: String = {
    #if TESTING
    if let directory = ProcessInfo.processInfo.environment["JUST_ALOUD_TEST_RUNTIME_DIR"],
       !directory.isEmpty { return directory }
    #endif
    return NSTemporaryDirectory()
}()
private let audioControlPath = (playbackRuntimeDir as NSString)
    .appendingPathComponent("just_aloud_audio_control")
private let speechPIDPath = (playbackRuntimeDir as NSString)
    .appendingPathComponent("just_aloud_tts.pid")
private let playbackStatePath = (playbackRuntimeDir as NSString)
    .appendingPathComponent("just_aloud_audio_state")
private let statusItemAutosaveName = "JustAloudMenuBar"
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

private let sentencePauseSliderStep = 50.0

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

// ElevenLabs retains the legacy character_* field names for subscription usage.
// This read-only response is deliberately independent of the synthesis pipeline.
private struct CreditUsageResponse: Decodable {
    let used: Int
    let limit: Int?
    enum CodingKeys: String, CodingKey {
        case used = "character_count"
        case limit = "character_limit"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        used = try values.decode(Int.self, forKey: .used)
        limit = try values.decodeIfPresent(Int.self, forKey: .limit)
        guard used >= 0, limit.map({ $0 >= 0 }) ?? true else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Negative credit usage or allowance"))
        }
    }

    static func title(used: Int, limit: Int?, stale: Bool) -> String {
        let number = NumberFormatter()
        number.locale = Locale(identifier: "en_US")
        number.numberStyle = .decimal
        let usedText = number.string(from: NSNumber(value: used)) ?? "\(used)"
        let limitText = limit.flatMap { number.string(from: NSNumber(value: $0)) } ?? "N/A"
        let percent: String
        if let limit, limit > 0 {
            // Convert before arithmetic: no integer overflow or division by zero.
            percent = String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"),
                             Double(used) / Double(limit) * 100)
        } else {
            percent = "N/A"
        }
        return "Credits: \(usedText) / \(limitText) used · \(percent)" + (stale ? " · stale" : "")
    }

    static func compactTitle(used: Int, limit: Int?, stale: Bool, digits: Int = 2) -> String {
        func compact(_ value: Int) -> String {
            for (divisor, suffix) in [(1e18, "E"), (1e15, "P"), (1e12, "T"),
                                      (1e9, "B"), (1e6, "M"), (1e3, "K")] {
                if Double(value) >= divisor {
                    return String(format: "%.*f%@", locale: Locale(identifier: "en_US_POSIX"),
                                  digits, Double(value) / divisor, suffix)
                }
            }
            return String(value)
        }
        let percent: String
        if let limit, limit > 0 {
            let value = Double(used) / Double(limit) * 100
            percent = String(format: value >= 1e6 ? "%.1e%%" : "%.1f%%",
                             locale: Locale(identifier: "en_US_POSIX"), value)
        } else {
            percent = "N/A"
        }
        return "Credits: \(compact(used)) / \(limit.map(compact) ?? "N/A") used · \(percent)" +
            (stale ? " · stale" : "")
    }
}

#if TESTING
private final class CreditUsageStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var pending: [CreditUsageStubProtocol] = []
    private static var requests: [URLRequest] = []
    static var recordedRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return requests
    }
    static var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }; return pending.count
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.requests.append(request)
        Self.pending.append(self)
    }
    override func stopLoading() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.pending.removeAll { $0 === self }
    }
    static func finish(status: Int = 200, json: String = "", error: Error? = nil) {
        lock.lock()
        let task = pending.removeFirst()
        lock.unlock()
        if let error {
            task.client?.urlProtocol(task, didFailWithError: error)
        } else {
            let response = HTTPURLResponse(url: task.request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            task.client?.urlProtocol(task, didReceive: response, cacheStoragePolicy: .notAllowed)
            task.client?.urlProtocol(task, didLoad: Data(json.utf8))
            task.client?.urlProtocolDidFinishLoading(task)
        }
    }
}
#endif

private final class VoiceActionButton: NSButton {
    var voiceId = ""
}

@objc final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var config         = Config.load()
    private var accessTimer: Timer?
    private var didRequestAccessibilityThisSession = false
    private var animTimer:   Timer?
    private var animPhase:   Double = 0
    private var indicatorMode = "idle"
    private var playbackMonitorTimer: Timer?
    private var recordingTimer: Timer?
    private let recordingRoot = URL(fileURLWithPath: playbackRuntimeDir)
        .appendingPathComponent("just-aloud-recordings", isDirectory: true)
    private var latestRecording: URL?
    private var currentRecording: URL?
    private var queuedDownload: URL?
    private var exportingRecording: URL?
    private var exportProcess: Process?
    private var isQuitting = false
    private weak var downloadButton: NSButton?
    private var downloadPopover: NSPopover?
    private var lastDownloadedFile: URL?

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
    private var cachedCredits: (used: Int, limit: Int?, fetchedAt: Date)?
    private var creditsRefreshFailed = false
    private var creditsTask: URLSessionDataTask?
    private var creditsRefreshPending = false
    private var creditsRequestID = 0
    private var creditsKeyInUse: String?
    private var creditsSession = URLSession(configuration: .ephemeral)
    private var creditObservedRecording: URL?
    private var creditObservedSpeechActive = false
    #if TESTING
    // Test builds never read a real credential for usage checks.
    private var testCreditsAPIKey: String?
    #endif
    private var voiceNameFetchesInFlight = Set<String>()
    private var voiceNameFetchFailures = Set<String>()
    private var cloudVoiceIndicators: [String: NSImageView] = [:]
    private var cloudVoiceSelectionButtons: [VoiceActionButton] = []
    private var aboutWindow: NSWindow?
    private var welcomeWindow: NSWindow?

    // TTS daemon process (managed mode — started by this app)
    private var ttsDaemonProcess: Process?

    private func idleMenuBarImage() -> NSImage {
        if let image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "Just Aloud") {
            let configured = image.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)) ?? image
            configured.isTemplate = true
            return configured
        }
        if let path = Bundle.main.path(forResource: "menu-bar-template", ofType: "svg"),
           let image = NSImage(contentsOfFile: path) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            image.accessibilityDescription = "Just Aloud"
            return image
        }
        return NSImage()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = statusItemAutosaveName
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = idleMenuBarImage()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.alphaValue = 1
            button.isHidden = false
            button.toolTip = "Just Aloud"
            button.setAccessibilityLabel("Just Aloud menu")
            if button.image?.isValid != true {
                button.title = "JA"
            }
        }
        appDelegateRef = self
        installStandardEditMenu()
        installHotkey()
        if !AXIsProcessTrusted() { startAccessibilityPolling() }
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
        refreshRecordings()
        let recordings = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshRecordings()
        }
        recordingTimer = recordings
        RunLoop.main.add(recordings, forMode: .common)
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

    // Opening the app again from Finder should reveal its controls, not appear
    // to do nothing just because this is a menu-bar-only application.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showPlaybackControls() }
        return true
    }

    private func installStandardEditMenu() {
        let mainMenu = NSMenu()
        let applicationRoot = NSMenuItem(title: "Just Aloud", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "Just Aloud")
        for (title, action) in [("About Just Aloud", #selector(showAbout)),
                                ("Welcome & Setup…", #selector(showWelcome)),
                                ("Show Playback Controls", #selector(showPlaybackControls))] {
            let command = NSMenuItem(title: title, action: action, keyEquivalent: "")
            command.target = self
            applicationMenu.addItem(command)
        }
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(NSMenuItem(title: "Quit Just Aloud",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        applicationRoot.submenu = applicationMenu
        mainMenu.addItem(applicationRoot)
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

    @objc private func showPlaybackControls() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in self?.statusItem.button?.performClick(nil) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isQuitting = true
        creditsTask?.cancel()
        recordingTimer?.invalidate()
        if let exportProcess, exportProcess.isRunning { exportProcess.terminate() }
        accessTimer?.invalidate()
        playbackMonitorTimer?.invalidate()
        killCurrentProcess()
        stopTTSDaemon()
        terminateExternalSpeech()
        // Only this application's private temporary recordings, never Downloads.
        if (try? recordingRoot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
            try? FileManager.default.removeItem(at: recordingRoot)
        }
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
        let speechActive = isSpeechActive
        observeSpeechActivityForCredits(speechActive)
        guard speechActive,
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
        guard !offlinePreview else { return }
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

    // Observe grants made directly in System Settings, without prompting.
    private func startAccessibilityPolling() {
        guard accessTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            guard AXIsProcessTrusted() else { return }
            t.invalidate()
            self.accessTimer = nil
            self.installHotkey()
            self.rebuildMenu()
        }
        accessTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func requestAccessibility() {
        guard !AXIsProcessTrusted() else {
            installHotkey()
            rebuildMenu()
            return
        }
        // Never repeatedly trigger the system alert during one app session.
        if !didRequestAccessibilityThisSession {
            didRequestAccessibilityThisSession = true
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startAccessibilityPolling()
    }

    private var openAtLoginState: NSControl.StateValue {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .on
        case .requiresApproval:
            return .mixed
        default:
            return .off
        }
    }

    @objc private func toggleOpenAtLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t Update Open at Login"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
        rebuildMenu()
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
                self.fetchCredits(afterGeneration: true)
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
        guard !offlinePreview else { return }
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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 52))
        let back = mediaButton(symbol: "gobackward.10", pointSize: 18, label: "Back 10 seconds", action: #selector(seekBackward))
        let playPause = mediaButton(symbol: isPlaybackPaused ? "play.circle.fill" : "pause.circle.fill", pointSize: 25, label: isPlaybackPaused ? "Resume" : "Pause", action: #selector(togglePlaybackPause))
        let forward = mediaButton(symbol: "goforward.10", pointSize: 18, label: "Forward 10 seconds", action: #selector(seekForward))
        let stop = mediaButton(symbol: "stop.fill", pointSize: 15, label: "Stop", action: #selector(stopPlayback))
        playPauseButton = playPause
        playbackButtons = [back, playPause, forward, stop]
        let download = mediaButton(symbol: "arrow.down.to.line", pointSize: 18,
                                   label: "Download recording", action: #selector(downloadRecording))
        downloadButton = download
        let stack = NSStackView(views: playbackButtons + [download])
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
        downloadButton?.isEnabled = exportProcess == nil && queuedDownload == nil &&
            (currentRecording != nil || latestRecording != nil)
        downloadButton?.toolTip = exportProcess != nil ? "Saving recording…" :
            queuedDownload != nil ? "Download queued until generation finishes" :
            "Download the complete recording to Downloads without using more credits"
        let symbol = isPlaybackPaused ? "play.circle.fill" : "pause.circle.fill"
        let label = isPlaybackPaused ? "Resume" : "Pause"
        let configuration = NSImage.SymbolConfiguration(pointSize: 25, weight: .medium)
        playPauseButton?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(configuration)
        playPauseButton?.toolTip = label
        playPauseButton?.setAccessibilityLabel(label)
    }

    // MARK: - Retained recordings and explicit offline downloads

    private func refreshRecordings() {
        guard !isQuitting else { return }
        let fm = FileManager.default
        guard (try? recordingRoot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        else { return }
        let folders = (try? fm.contentsOfDirectory(at: recordingRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        let sessions = folders.filter {
            $0.lastPathComponent.hasPrefix("recording.") &&
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true &&
            (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        }
        let completed = sessions.filter { fm.fileExists(atPath: $0.appendingPathComponent("complete").path) }
        latestRecording = completed.max {
            let a = (try? $0.appendingPathComponent("complete").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.appendingPathComponent("complete").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        observeCompletedRecordingForCredits(latestRecording)
        let name = (try? String(contentsOf: recordingRoot.appendingPathComponent("current"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        currentRecording = sessions.first { $0.lastPathComponent == name }
        if let requested = queuedDownload {
            if completed.contains(requested) {
                queuedDownload = nil
                exportRecording(requested)
            } else if !sessions.contains(requested) {
                queuedDownload = nil
                showDownloadNotice("Recording was not completed. No download was saved.")
            }
        }
        // A new partial or failed request must never discard the last success.
        for old in completed where old != latestRecording && old != exportingRecording {
            try? fm.removeItem(at: old)
        }
        updateMediaControls()
    }

    @objc private func downloadRecording() {
        guard exportProcess == nil, queuedDownload == nil else { return }
        refreshRecordings()
        guard let recording = currentRecording ?? latestRecording else { return }
        if FileManager.default.fileExists(atPath: recording.appendingPathComponent("complete").path) {
            exportRecording(recording)
        } else {
            queuedDownload = recording
            updateMediaControls()
            showDownloadNotice("Download queued. It will save when the full recording has been generated.")
        }
    }

    private func exportRecording(_ recording: URL) {
        guard !isQuitting, exportProcess == nil else { return }
        var helper = Bundle.main.path(forResource: "just-aloud-audio", ofType: nil) ??
            ((speakPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("just-aloud-audio")
        #if TESTING
        helper = ProcessInfo.processInfo.environment["JUST_ALOUD_TEST_EXPORT_HELPER"] ?? helper
        #endif
        let output = recordingRoot.appendingPathComponent("export-\(UUID().uuidString).wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["export-recording", recording.path, output.path]
        process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory()]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        exportingRecording = recording
        exportProcess = process
        do { try process.run() } catch {
            exportProcess = nil
            exportingRecording = nil
            showDownloadNotice("Could not export the recording. Your original audio is still available.")
            return
        }
        updateMediaControls()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            process.waitUntilExit()
            DispatchQueue.main.async {
                guard let self, !self.isQuitting else { return }
                self.exportProcess = nil
                self.exportingRecording = nil
                defer {
                    try? FileManager.default.removeItem(at: output)
                    self.updateMediaControls()
                }
                guard process.terminationStatus == 0 else {
                    self.showDownloadNotice("Could not export the full recording. Your original audio is still available.")
                    return
                }
                do {
                    var downloads = try FileManager.default.url(for: .downloadsDirectory,
                        in: .userDomainMask, appropriateFor: nil, create: true)
                    #if TESTING
                    if let path = ProcessInfo.processInfo.environment["JUST_ALOUD_TEST_DOWNLOADS"] {
                        downloads = URL(fileURLWithPath: path)
                    }
                    #endif
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
                    let name = "Just Aloud \(formatter.string(from: Date())) \(UUID().uuidString.prefix(8)).wav"
                    let destination = downloads.appendingPathComponent(name)
                    // Exclusive move: never overwrite an existing user download.
                    try FileManager.default.moveItem(at: output, to: destination)
                    self.lastDownloadedFile = destination
                    self.showDownloadNotice("Recording saved to Downloads.", reveal: true)
                } catch {
                    self.showDownloadNotice("Could not save to Downloads. Check folder access and free disk space, then try again.")
                }
            }
        }
    }

    private func showDownloadNotice(_ message: String, reveal: Bool = false) {
        guard let button = statusItem?.button else { return }
        statusItem.menu?.cancelTracking()
        downloadPopover?.close()
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: reveal ? 100 : 76))
        let label = NSTextField(wrappingLabelWithString: message)
        label.frame = NSRect(x: 16, y: reveal ? 42 : 16, width: 248, height: 44)
        label.font = .systemFont(ofSize: 13)
        controller.view.addSubview(label)
        if reveal {
            let revealButton = NSButton(title: "Show in Finder", target: self, action: #selector(revealDownload))
            revealButton.frame = NSRect(x: 16, y: 10, width: 140, height: 28)
            revealButton.bezelStyle = .rounded
            controller.view.addSubview(revealButton)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        downloadPopover = popover
        DispatchQueue.main.async {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak popover] in popover?.close() }
    }

    @objc private func revealDownload() {
        if let url = lastDownloadedFile { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        downloadPopover?.close()
    }

    #if TESTING
    func testRecordingLifecycle() throws {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        guard let testRoot = env["JUST_ALOUD_TEST_RUNTIME_DIR"],
              let downloadPath = env["JUST_ALOUD_TEST_DOWNLOADS"],
              let fixture = env["JUST_ALOUD_TEST_AUDIO"] else { fatalError("Isolated test paths required") }
        precondition(downloadPath.hasPrefix(testRoot + "/"))
        precondition(configDir.hasPrefix(testRoot + "/"))
        precondition(!fm.fileExists(atPath: speechPIDPath))
        let downloads = URL(fileURLWithPath: downloadPath)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fm.createDirectory(at: recordingRoot, withIntermediateDirectories: true)
        func session(_ name: String, complete: Bool) throws -> URL {
            let folder = recordingRoot.appendingPathComponent("recording." + name, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            try fm.copyItem(at: URL(fileURLWithPath: fixture), to: folder.appendingPathComponent("chunk-1.audio"))
            try "chunk-1.audio\t0\t1\n".write(to: folder.appendingPathComponent("manifest.tsv"), atomically: true, encoding: .utf8)
            try "".write(to: folder.appendingPathComponent(complete ? "complete" : "pending"), atomically: true, encoding: .utf8)
            try folder.lastPathComponent.write(to: recordingRoot.appendingPathComponent("current"), atomically: true, encoding: .utf8)
            return try fm.contentsOfDirectory(at: recordingRoot, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent == folder.lastPathComponent }!
        }
        var checks = 0
        func check(_ condition: Bool) {
            precondition(condition, "Recording lifecycle check \(checks + 1)")
            checks += 1
        }
        func waitForExport() {
            let deadline = Date().addingTimeInterval(30)
            while exportProcess != nil && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            check(exportProcess == nil)
        }
        let old = try session("old", complete: true)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10)], ofItemAtPath: old.appendingPathComponent("complete").path)
        refreshRecordings()
        check(latestRecording == old)
        let pending = try session("pending", complete: false)
        refreshRecordings()
        check(latestRecording == old && currentRecording == pending)
        check(try fm.contentsOfDirectory(atPath: downloadPath).isEmpty)
        downloadRecording()
        check(queuedDownload == pending && exportProcess == nil)
        check(fm.fileExists(atPath: old.path))
        try "".write(to: pending.appendingPathComponent("complete"), atomically: true, encoding: .utf8)
        refreshRecordings()
        check(queuedDownload == nil)
        waitForExport()
        check(try fm.contentsOfDirectory(atPath: downloadPath).count == 1)
        check(!fm.fileExists(atPath: old.path) && latestRecording == pending)
        let failed = try session("failed", complete: false)
        refreshRecordings()
        downloadRecording()
        try fm.removeItem(at: failed)
        refreshRecordings()
        check(queuedDownload == nil && latestRecording == pending)
        check(try fm.contentsOfDirectory(atPath: downloadPath).count == 1)
        downloadRecording()
        waitForExport()
        check(try fm.contentsOfDirectory(atPath: downloadPath).count == 2)
        applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        check(!fm.fileExists(atPath: recordingRoot.path))
        check(try fm.contentsOfDirectory(atPath: downloadPath).count == 2)
        print("PASS: \(checks) recording retention, queued download, repeat download, failure, and quit checks")
    }
    #endif

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
        resetCreditsForCredentialChange()
    }

    private func deleteAPIKey() {
        guard !offlinePreview else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "just-aloud",
            kSecAttrService as String: "just-aloud-api-key",
        ]
        SecItemDelete(query as CFDictionary)
        resetCreditsForCredentialChange()
    }

    private func keychainData(account: String, service: String) -> Data? {
        guard !offlinePreview else { return nil }
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
        guard !offlinePreview else { return }
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

    private weak var creditsMenuItem: NSMenuItem?
    private weak var creditsStatusLabel: NSTextField?

    private func rebuildMenu() {
        statusItem.menu = buildPlaybackMenu()
    }

    private func buildPlaybackMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(buildMediaControlsItem())
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
        }

        // ── Local (Kokoro) section ──
        if showLocal {
            if showHeaders {
                menu.addItem(.separator())
                menu.addItem(hintItem("Local (Kokoro)"))
            }
            menu.addItem(submenuItem("Voice", items: buildLocalVoiceItems()))
            menu.addItem(submenuItem("Speed", items: buildLocalSpeedItems()))
        }

        // Playback-level setting shared by all backends. The selected value is
        // real elapsed silence and does not shrink at faster playback speeds.
        menu.addItem(buildSentencePauseSliderItem())
        menu.addItem(.separator())

        menu.addItem(buildCreditsStatusItem())
        menu.addItem(submenuItem("Settings", items: buildSettingsItems(showElevenLabs: showEl)))

        // Permission setup stays in the welcome window, not as a persistent
        // warning in the everyday playback menu.
        let about = NSMenuItem(title: "About Just Aloud",
                               action: #selector(showAbout),
                               keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Just Aloud",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    private func buildSettingsItems(showElevenLabs showEl: Bool) -> [NSMenuItem] {
        // One configuration menu for every engine. No extra "advanced" layer.
        var items = [submenuItem("Speech Engine", items: buildBackendItems())]
        if showEl {
            items += [
                submenuItem("Model", items: buildModelItems()),
                submenuItem("Stability", items: buildStabilityItems()),
                submenuItem("Similarity", items: buildSimilarityItems()),
                .separator()
            ]

            let apiItem = NSMenuItem(title: "API Key\u{2026}",
                                    action: #selector(manageAPIKey), keyEquivalent: "")
            apiItem.target = self
            items.append(apiItem)

        }
        items.append(.separator())
        let openAtLogin = NSMenuItem(title: "Open at Login",
                                     action: #selector(toggleOpenAtLogin),
                                     keyEquivalent: "")
        openAtLogin.target = self
        openAtLogin.state = openAtLoginState
        openAtLogin.toolTip = openAtLoginState == .mixed
            ? "Approval is required in System Settings"
            : nil
        items.append(openAtLogin)
        return items
    }

    private func buildCreditsStatusItem() -> NSMenuItem {
        let title = "Credits unavailable"
        // A long NSMenuItem title can widen the native menu even with a custom
        // view. Keep this structural title short; the label carries the status.
        let item = NSMenuItem(title: "Credits", action: nil, keyEquivalent: "")
        item.tag = 999
        item.isEnabled = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 18, y: 5, width: 244, height: 16)
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.autoresizingMask = [.width]
        view.addSubview(label)
        item.view = view
        creditsMenuItem = item
        creditsStatusLabel = label
        renderCreditsStatus()
        return item
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
        reset.autoresizingMask = [.minXMargin]
        reset.bezelStyle = .recessed
        reset.isBordered = false
        reset.contentTintColor = .labelColor
        reset.font = NSFont.menuFont(ofSize: 11)
        view.addSubview(reset)

        let slider = NSSlider(value: effectiveSpeed,
                              minValue: minEffectiveSpeed,
                              maxValue: maxEffectiveSpeed,
                              target: self,
                              action: #selector(speedSliderChanged(_:)))
        slider.frame = NSRect(x: 40, y: 12, width: 198, height: 22)
        slider.autoresizingMask = [.width]
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
        fast.autoresizingMask = [.minXMargin]
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

    private func buildSentencePauseSliderItem() -> NSMenuItem {
        let menuItem = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 66))
        let value = min(max(config.sentencePause, 0), 5_000)

        let title = NSTextField(labelWithString: "Sentence Pause")
        title.frame = NSRect(x: 18, y: 40, width: 140, height: 18)
        title.font = NSFont.menuFont(ofSize: 13)
        view.addSubview(title)

        let valueButton = NSButton(title: "\(value) ms", target: self,
                                   action: #selector(editSentencePause))
        valueButton.frame = NSRect(x: 170, y: 36, width: 98, height: 24)
        valueButton.autoresizingMask = [.minXMargin]
        valueButton.bezelStyle = .recessed
        valueButton.isBordered = false
        valueButton.contentTintColor = .labelColor
        valueButton.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueButton.tag = 4201
        valueButton.toolTip = "Enter an exact sentence pause in milliseconds"
        valueButton.setAccessibilityLabel("Enter exact sentence pause")
        valueButton.setAccessibilityValueDescription("\(value) milliseconds")
        view.addSubview(valueButton)

        let slider = NSSlider(value: Double(value), minValue: 0, maxValue: 5_000,
                              target: self, action: #selector(sentencePauseSliderChanged(_:)))
        slider.frame = NSRect(x: 40, y: 12, width: 198, height: 22)
        slider.autoresizingMask = [.width]
        slider.isContinuous = true
        slider.altIncrementValue = sentencePauseSliderStep
        slider.setAccessibilityLabel("Sentence pause")
        slider.setAccessibilityValueDescription("\(value) milliseconds")
        view.addSubview(slider)

        for (text, x) in [("0 s", 9.0), ("5 s", 242.0)] {
            let endpoint = NSTextField(labelWithString: text)
            endpoint.frame = NSRect(x: x, y: 14, width: 30, height: 16)
            if x > 100 { endpoint.autoresizingMask = [.minXMargin] }
            endpoint.font = NSFont.menuFont(ofSize: 10)
            endpoint.textColor = .secondaryLabelColor
            view.addSubview(endpoint)
        }
        menuItem.view = view
        return menuItem
    }

    #if TESTING
    func testCreditUsage() {
        precondition(ProcessInfo.processInfo.environment["JUST_ALOUD_CONFIG_DIR"] != nil)
        precondition(ProcessInfo.processInfo.environment["JUST_ALOUD_TEST_RUNTIME_DIR"] != nil)
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        func waitFor(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !condition(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            check(condition(), "asynchronous credit request completed")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CreditUsageStubProtocol.self]
        creditsSession = URLSession(configuration: configuration)
        let menu = buildPlaybackMenu()
        check(menu.indexOfItem(withTag: 999) + 1 == menu.indexOfItem(withTitle: "Settings"), "status directly above Settings")
        check(creditsStatusLabel?.stringValue == "Credits unavailable", "empty status persists")
        fetchCredits()
        check(CreditUsageStubProtocol.recordedRequests.isEmpty, "missing key never sends requests")
        testCreditsAPIKey = "unit-test-credential"
        fetchCredits()
        waitFor { CreditUsageStubProtocol.pendingCount == 1 }
        fetchCredits()
        check(CreditUsageStubProtocol.recordedRequests.count == 1, "overlapping opens coalesce")
        check(creditsStatusLabel?.stringValue == "Credits unavailable", "no loading layout jump")
        CreditUsageStubProtocol.finish(json: #"{"character_count":12450,"character_limit":30000}"#)
        waitFor { creditsTask == nil }
        check(creditsStatusLabel?.stringValue == "Credits: 12,450 / 30,000 used · 41.5%", "used credits and actual percentage")
        check(!creditsRefreshFailed, "success clears stale state")
        let cachedAt = cachedCredits!.fetchedAt
        fetchCredits()
        check(creditsStatusLabel?.stringValue == "Credits: 12,450 / 30,000 used · 41.5%", "cache shown synchronously")
        waitFor { CreditUsageStubProtocol.pendingCount == 1 }
        check(CreditUsageStubProtocol.recordedRequests.count == 2, "fresh cache still refreshes on next open")
        CreditUsageStubProtocol.finish(status: 503)
        waitFor { creditsTask == nil }
        check(creditsStatusLabel?.stringValue == "Credits: 12,450 / 30,000 used · 41.5% · stale", "failed refresh retains stale balance")
        check(cachedCredits?.fetchedAt == cachedAt, "failure preserves last successful timestamp")
        for json in ["broken", #"{"character_count":-1,"character_limit":100}"#,
                     #"{"character_count":true,"character_limit":100}"#,
                     #"{"character_count":1,"character_limit":-10}"#,
                     #"{"character_limit":100}"#] {
            fetchCredits()
            waitFor { CreditUsageStubProtocol.pendingCount == 1 }
            CreditUsageStubProtocol.finish(json: json)
            waitFor { creditsTask == nil }
            check(cachedCredits?.used == 12450 && creditsRefreshFailed, "invalid payload preserves cache")
        }
        fetchCredits()
        waitFor { CreditUsageStubProtocol.pendingCount == 1 }
        CreditUsageStubProtocol.finish(error: URLError(.timedOut))
        waitFor { creditsTask == nil }
        check(cachedCredits?.used == 12450 && creditsRefreshFailed, "timeout retains stale cache")
        for (json, expected) in [
            (#"{"character_count":0,"character_limit":0}"#, "Credits: 0 / 0 used · N/A"),
            (#"{"character_count":50}"#, "Credits: 50 / N/A used · N/A"),
            (#"{"character_count":50,"character_limit":null}"#, "Credits: 50 / N/A used · N/A"),
            (#"{"character_count":125,"character_limit":100}"#, "Credits: 125 / 100 used · 125.0%"),
            (#"{"character_count":1,"character_limit":3}"#, "Credits: 1 / 3 used · 33.3%")
        ] {
            fetchCredits()
            waitFor { CreditUsageStubProtocol.pendingCount == 1 }
            CreditUsageStubProtocol.finish(json: json)
            waitFor { creditsTask == nil }
            check(creditsStatusLabel?.stringValue == expected, "allowance and rounding edge case")
            check(!creditsRefreshFailed, "recovery clears stale state")
        }
        cachedCredits = (used: 12450, limit: 30000, fetchedAt: Date().addingTimeInterval(-61))
        renderCreditsStatus()
        check(creditsStatusLabel!.stringValue.hasSuffix(" · stale"), "aged cache is identified")
        let countBeforeGeneration = CreditUsageStubProtocol.recordedRequests.count
        fetchCredits()
        waitFor { CreditUsageStubProtocol.pendingCount == 1 }
        let completed = URL(fileURLWithPath: playbackRuntimeDir).appendingPathComponent("completed-fixture")
        observeCompletedRecordingForCredits(completed)
        observeCompletedRecordingForCredits(completed)
        check(creditsRefreshPending, "completion queues a post-generation refresh")
        CreditUsageStubProtocol.finish(json: #"{"character_count":20,"character_limit":100}"#)
        waitFor { CreditUsageStubProtocol.recordedRequests.count == countBeforeGeneration + 2 && CreditUsageStubProtocol.pendingCount == 1 }
        CreditUsageStubProtocol.finish(json: #"{"character_count":30,"character_limit":100}"#)
        waitFor { creditsTask == nil }
        check(cachedCredits?.used == 30, "post-generation balance wins")
        observeCompletedRecordingForCredits(completed)
        check(creditsTask == nil, "same completion never refetches")
        observeSpeechActivityForCredits(true)
        observeSpeechActivityForCredits(true) // Speech remains active while paused.
        check(creditsTask == nil, "pause or repeated activity never refreshes usage")
        observeSpeechActivityForCredits(false)
        waitFor { CreditUsageStubProtocol.pendingCount == 1 }
        CreditUsageStubProtocol.finish(status: 429)
        waitFor { creditsTask == nil }
        check(cachedCredits?.used == 30 && creditsRefreshFailed, "partial generation and rate limiting retain balance")
        fetchCredits()
        waitFor { CreditUsageStubProtocol.pendingCount == 1 }
        resetCreditsForCredentialChange()
        waitFor { CreditUsageStubProtocol.pendingCount == 0 }
        check(cachedCredits == nil && creditsStatusLabel?.stringValue == "Credits unavailable", "credential change cancels old account balance")
        fetchCredits()
        waitFor { CreditUsageStubProtocol.pendingCount == 1 }
        CreditUsageStubProtocol.finish(status: 401)
        waitFor { creditsTask == nil }
        check(creditsStatusLabel?.stringValue == "Credits unavailable", "no balance on authentication failure")
        cachedCredits = (used: 80, limit: 100, fetchedAt: Date())
        fetchCredits()
        waitFor { CreditUsageStubProtocol.pendingCount == 1 }
        testCreditsAPIKey = nil
        fetchCredits()
        waitFor { CreditUsageStubProtocol.pendingCount == 0 }
        check(cachedCredits?.used == 80 && creditsRefreshFailed && creditsTask == nil,
              "missing credential cancels pending request but retains stale balance")
        testCreditsAPIKey = "different-test-credential"
        fetchCredits()
        waitFor { CreditUsageStubProtocol.pendingCount == 1 }
        check(cachedCredits == nil, "different account cannot display previous balance")
        CreditUsageStubProtocol.finish(json: #"{"character_count":10,"character_limit":100}"#)
        waitFor { creditsTask == nil }
        check(cachedCredits?.used == 10 && !creditsRefreshFailed, "new credential uses only new balance")
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                cachedCredits = (used: 999999999, limit: 999999999, fetchedAt: Date())
                creditsRefreshFailed = true
                renderCreditsStatus()
                let label = creditsStatusLabel!
                let measured = (label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width
                check(measured <= label.frame.width, "compact balance and stale state fit on one line")
                check(creditsMenuItem?.view?.frame.width == 280, "credit status never widens the popover")
                check(creditsMenuItem?.title == "Credits", "native menu title cannot widen the popover")
                check(label.textColor == .secondaryLabelColor, "semantic subdued color")
                check(!label.isEditable && !label.isSelectable, "read-only status")
                check(label.accessibilityLabel()?.contains("999,999,999") == true, "accessible exact balance")
                check(label.toolTip?.contains("999,999,999") == true, "hover reveals exact balance")
            }
        }
        check(!CreditUsageResponse.title(used: Int.max, limit: 1, stale: false).contains("inf"), "large balance avoids overflow")
        for (used, limit) in [(5_410_242, 33_098_807), (Int.max, 1), (1, Int.max), (Int.max, Int.max)] {
            for stale in [false, true] {
                cachedCredits = (used: used, limit: limit, fetchedAt: Date())
                creditsRefreshFailed = stale
                renderCreditsStatus()
                let label = creditsStatusLabel!
                check((label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width <= 244,
                      "large and extreme balances fit without truncation")
                check(label.accessibilityLabel() == CreditUsageResponse.title(used: used, limit: limit, stale: stale),
                      "compact visual balance retains exact accessible values")
                check(label.stringValue.contains("%"), "compact balance keeps percentage visible")
            }
        }
        for request in CreditUsageStubProtocol.recordedRequests {
            check(request.httpMethod == "GET" && request.httpBody == nil && request.httpBodyStream == nil,
                  "usage request cannot synthesize speech")
            check(request.url?.absoluteString == "https://api.elevenlabs.io/v1/user/subscription", "only the usage endpoint requested")
            check(request.cachePolicy == .reloadIgnoringLocalCacheData, "background refresh bypasses HTTP cache")
        }
        check(!FileManager.default.fileExists(atPath: speechPIDPath), "usage checks did not launch speech")
        print("PASS: \(checks) credit usage, refresh, stale-state, generation, and read-only request checks")
        creditsSession.invalidateAndCancel()
    }

    func testMenuLayout() {
        precondition(ProcessInfo.processInfo.environment["JUST_ALOUD_CONFIG_DIR"] != nil)
        precondition(ProcessInfo.processInfo.environment["JUST_ALOUD_TEST_RUNTIME_DIR"] != nil)
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        func titles(_ menu: NSMenu) -> [String] {
            menu.items.filter { !$0.isSeparatorItem && !$0.isHidden && $0.view == nil }.map(\.title)
        }
        installStandardEditMenu()
        check(NSApp.mainMenu?.items.map(\.title) == ["Just Aloud", "Edit"], "standard app and Edit menus")
        let appCommands = NSApp.mainMenu!.items[0].submenu!
        check(appCommands.items.contains { $0.title == "Show Playback Controls" }, "playback controls can be reopened")
        check(appCommands.items.contains { $0.keyEquivalent == "q" && $0.action == #selector(NSApplication.terminate(_:)) }, "standard clean Quit shortcut")
        for backend in ["elevenlabs", "local", "auto"] {
            config.ttsBackend = backend
            config.backendsInstalled = "both"
            config.modelId = "eleven_multilingual_v2"
            config.stability = 0.35
            config.similarityBoost = 0.65
            config.style = 0.25
            config.useSpeakerBoost = false
            config.save()
            let before = try! Data(contentsOf: URL(fileURLWithPath: configPath))
            cachedCredits = nil
            let menu = buildPlaybackMenu()
            let settings = menu.item(withTitle: "Settings")!.submenu!
            check(titles(menu).suffix(3) == ["Settings", "About Just Aloud", "Quit Just Aloud"], "app commands grouped")
            for title in ["Speech Engine", "Backend", "Model", "Stability", "Similarity", "API Key…", "Open at Login"] {
                check(menu.item(withTitle: title) == nil, "configuration not at root: \(title)")
            }
            check(settings.item(withTitle: "Advanced Voice Settings") == nil, "no redundant layer")
            check(settings.item(withTitle: "Speech Engine")?.submenu?.items.count == 3, "all engines reachable")
            let login = settings.item(withTitle: "Open at Login")!
            check(login.action == #selector(toggleOpenAtLogin), "login action preserved")
            check(login.state == openAtLoginState, "native login state preserved")
            check(login.target === self, "login action target preserved")
            check(menu.items.first?.view?.frame.size == NSSize(width: 280, height: 52), "media dimensions preserved")
            check(menu.items.compactMap(\.view).contains { $0.viewWithTag(4201) != nil }, "pause slider remains at root")
            check(menu.indexOfItem(withTag: 999) + 1 == menu.indexOfItem(withTitle: "Settings"), "persistent credits immediately above Settings")
            check(menu.item(withTag: 999)?.isHidden == false, "credit status always visible")
            check(settings.item(withTag: 999) == nil, "credits are not settings")
            check(menu.item(withTitle: "Quit Just Aloud")?.keyEquivalent == "q", "quit shortcut preserved")
            check(before == (try! Data(contentsOf: URL(fileURLWithPath: configPath))), "building menu never changes preferences")
            if backend == "local" {
                check(titles(settings) == ["Speech Engine", "Open at Login"], "local settings remain available")
                fetchCredits()
                check(creditsStatusLabel?.stringValue == "Credits unavailable", "no balance remains visible in local mode")
            } else {
                check(titles(settings) == ["Speech Engine", "Model", "Stability", "Similarity", "API Key…", "Open at Login"], "flat cloud settings order")
                check(settings.items.filter(\.isSeparatorItem).count == 2, "voice account and app groups separated")
                check(creditsStatusLabel?.stringValue == "Credits unavailable", "unknown credits retain stable placeholder")
                cachedCredits = (used: 25, limit: 100, fetchedAt: Date())
                creditsRefreshFailed = false
                renderCreditsStatus()
                check(menu.item(withTag: 999)?.title == "Credits", "main status does not change native menu width")
                check(creditsStatusLabel?.stringValue == "Credits: 25 / 100 used · 25.0%", "visible status label updates")
                cachedCredits = (used: 40, limit: 100, fetchedAt: Date())
                let reopened = buildPlaybackMenu()
                check(reopened.item(withTag: 999)?.title == "Credits" && creditsStatusLabel?.stringValue == "Credits: 40 / 100 used · 40.0%", "cached credits survive rebuild")
                config.modelId = "eleven_v3"
                let v3 = buildPlaybackMenu().item(withTitle: "Settings")!.submenu!
                check(v3.item(withTitle: "Stability")!.submenu!.items.count == 3, "v3 stability presets preserved")
                check(v3.item(withTitle: "Similarity")!.submenu!.items.first!.isEnabled == false, "v3 unsupported hint preserved")
            }
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            appearance.performAsCurrentDrawingAppearance {
                for item in [buildElSpeedSliderItem(), buildSentencePauseSliderItem()] {
                    check(item.view?.frame.size == NSSize(width: 280, height: 66), "slider dimensions preserved")
                    let slider = item.view!.subviews.compactMap { $0 as? NSSlider }.first!
                    check(slider.isEnabled && slider.isContinuous, "native slider operable")
                    check(slider.accessibilityLabel()?.isEmpty == false, "slider accessibility label")
                    let action = item.view!.subviews.compactMap { $0 as? NSButton }.first!
                    check(action.isEnabled && action.contentTintColor == .labelColor, "adaptive readable action")
                }
            }
        }
        print("PASS: \(checks) menu layout checks")
    }

    func testSentencePauseSlider() {
        // This test must never touch the user's config or active audio queue.
        let env = ProcessInfo.processInfo.environment
        precondition(env["JUST_ALOUD_CONFIG_DIR"] != nil)
        precondition(env["JUST_ALOUD_TEST_RUNTIME_DIR"] != nil)
        let sandbox = URL(fileURLWithPath: env["JUST_ALOUD_TEST_RUNTIME_DIR"]!).resolvingSymlinksInPath().path
        precondition(URL(fileURLWithPath: playbackRuntimeDir).resolvingSymlinksInPath().path == sandbox)
        precondition(URL(fileURLWithPath: configDir).resolvingSymlinksInPath().path.hasPrefix(sandbox + "/"))
        precondition(!FileManager.default.fileExists(atPath: speechPIDPath))
        let menuItem = buildSentencePauseSliderItem()
        let view = menuItem.view!
        let slider = view.subviews.compactMap { $0 as? NSSlider }.first!
        let valueButton = view.viewWithTag(4201) as! NSButton
        var checks = 0
        func check(_ condition: Bool) { precondition(condition); checks += 1 }
        check(slider.minValue == 0 && slider.maxValue == 5_000)
        check(slider.isContinuous)
        check(valueButton.action == #selector(editSentencePause))
        for (raw, expected) in [(0.0, 0), (49.0, 50), (250.0, 250),
                                (400.0, 400), (2481.0, 2500), (5000.0, 5000)] {
            slider.doubleValue = raw
            check(slider.sendAction(slider.action, to: slider.target))
            check(config.sentencePause == expected)
            check(Config.load().sentencePause == expected)
            check(valueButton.title == "\(expected) ms")
            check(menuItem.view === view && slider.superview === view)
        }
        setSentencePause(333)
        check(Config.load().sentencePause == 333)
        let reopened = buildSentencePauseSliderItem().view!
        check(reopened.subviews.compactMap { $0 as? NSSlider }.first!.intValue == 333)
        // Exercise live delivery using this isolated queue, never the real one.
        speakLock.lock()
        isSpeakingFlag = true
        speakLock.unlock()
        setSentencePause(750)
        check((try? String(contentsOfFile: audioControlPath, encoding: .utf8)) == "sentence-pause:750\n")
        speakLock.lock()
        isSpeakingFlag = false
        speakLock.unlock()
        print("PASS: \(checks) sentence-pause slider checks")
    }
    #endif

    private func buildStabilityItems() -> [NSMenuItem] {
        if config.modelId == "eleven_v3" {
            let effective = (config.stability * 2).rounded() / 2
            return [("Creative", 0.0), ("Natural", 0.5), ("Robust", 1.0)].map { label, value in
                item(label, #selector(pickStability(_:)), repr: String(value), on: effective == value)
            }
        }
        var items = [hintItem("Lower = expressive · Higher = steady"), .separator()]
        items += stabilitySteps.map { s in
            item(s.label, #selector(pickStability(_:)),
                 repr: String(s.value), on: abs(s.value - config.stability) < 0.01)
        }
        return items
    }

    private func buildSimilarityItems() -> [NSMenuItem] {
        if config.modelId == "eleven_v3" {
            return [hintItem("Not supported by Eleven v3; saved value is preserved")]
        }
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
        guard config.sentencePause != bounded else { return }
        config.sentencePause = bounded
        config.save()
        if isSpeechActive {
            sendAudioControl("sentence-pause:\(bounded)")
        }
    }

    @objc private func sentencePauseSliderChanged(_ sender: NSSlider) {
        let value = Int((sender.doubleValue / sentencePauseSliderStep).rounded()
                        * sentencePauseSliderStep)
        setSentencePause(value)
        sender.doubleValue = Double(config.sentencePause)
        sender.setAccessibilityValueDescription("\(config.sentencePause) milliseconds")
        if let button = sender.superview?.viewWithTag(4201) as? NSButton {
            button.title = "\(config.sentencePause) ms"
            button.setAccessibilityValueDescription("\(config.sentencePause) milliseconds")
        }
        // Keep the native tracking view alive while dragging; no menu rebuild.
    }

    @objc private func editSentencePause() {
        statusItem.menu?.cancelTracking()
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
        rebuildMenu()
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

    private func resetCreditsForCredentialChange() {
        creditsRequestID += 1
        creditsTask?.cancel()
        creditsTask = nil
        creditsRefreshPending = false
        creditsKeyInUse = nil
        cachedCredits = nil
        creditsRefreshFailed = false
        renderCreditsStatus()
    }

    private func fetchCredits(afterGeneration: Bool = false) {
        precondition(Thread.isMainThread)
        guard !isQuitting else { return }
        // Show the session cache immediately, but always refresh on menu open.
        renderCreditsStatus()
        #if TESTING
        let key = testCreditsAPIKey
        #else
        let key = readAPIKey()
        #endif
        guard let key, !key.isEmpty else {
            if creditsTask != nil {
                creditsRequestID += 1
                creditsTask?.cancel()
                creditsTask = nil
                creditsRefreshPending = false
            }
            creditsRefreshFailed = true
            renderCreditsStatus()
            return
        }
        if let previousKey = creditsKeyInUse, previousKey != key {
            resetCreditsForCredentialChange()
        }
        creditsKeyInUse = key
        if creditsTask != nil {
            // A pre-generation request may report an older balance. Follow it
            // with one new GET if generation ends while that request is running.
            creditsRefreshPending = creditsRefreshPending || afterGeneration
            return
        }
        creditsRequestID += 1
        let requestID = creditsRequestID
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/user/subscription")!)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        creditsTask = creditsSession.dataTask(with: request) { [weak self] data, response, error in
            let usage: CreditUsageResponse?
            if error == nil, let data,
               (response as? HTTPURLResponse)?.statusCode == 200 {
                usage = try? JSONDecoder().decode(CreditUsageResponse.self, from: data)
            } else {
                usage = nil
            }
            // Neither cached state nor AppKit views are mutated on the URLSession queue.
            DispatchQueue.main.async {
                guard let self, !self.isQuitting, self.creditsRequestID == requestID else { return }
                self.creditsTask = nil
                if let usage {
                    self.cachedCredits = (used: usage.used, limit: usage.limit, fetchedAt: Date())
                    self.creditsRefreshFailed = false
                } else {
                    // Keep the last successful balance, including its timestamp.
                    self.creditsRefreshFailed = true
                }
                self.renderCreditsStatus()
                if self.creditsRefreshPending {
                    self.creditsRefreshPending = false
                    self.fetchCredits()
                }
            }
        }
        creditsTask?.resume()
    }

    private func observeCompletedRecordingForCredits(_ recording: URL?) {
        guard let recording, recording != creditObservedRecording else { return }
        creditObservedRecording = recording
        // The complete marker is written after generation, before playback ends.
        fetchCredits(afterGeneration: true)
    }

    private func observeSpeechActivityForCredits(_ active: Bool) {
        let finished = creditObservedSpeechActive && !active
        creditObservedSpeechActive = active
        // Also covers external CLI runs and failed/partial requests that consumed
        // credits but never produced a complete recording. Pause is still active.
        if finished { fetchCredits(afterGeneration: true) }
    }

    private func renderCreditsStatus() {
        guard let item = creditsMenuItem, let label = creditsStatusLabel else { return }
        let title: String
        if let cached = cachedCredits {
            let stale = creditsRefreshFailed || Date().timeIntervalSince(cached.fetchedAt) >= 60
            title = CreditUsageResponse.title(used: cached.used, limit: cached.limit, stale: stale)
            label.toolTip = title + "\nElevenLabs credits used / total allowance. Last updated " +
                DateFormatter.localizedString(from: cached.fetchedAt, dateStyle: .medium, timeStyle: .medium) +
                (stale ? ". Cached balance; refresh unavailable or pending." : ".") +
                ((cached.limit ?? 0) <= 0 ? " Percentage unavailable without a positive allowance." : "")
        } else {
            title = "Credits unavailable"
            label.toolTip = "Unable to retrieve ElevenLabs credit usage. Check the API key and connection in Settings."
        }
        var display = title
        // Preserve the original 280-point control width. Exact totals stay in
        // the tooltip and accessibility label; only long visual values compact.
        if let cached = cachedCredits {
            let stale = creditsRefreshFailed || Date().timeIntervalSince(cached.fetchedAt) >= 60
            for digits in [2, 1, 0] {
                if (display as NSString).size(withAttributes: [.font: label.font!]).width <= 244 { break }
                display = CreditUsageResponse.compactTitle(used: cached.used, limit: cached.limit,
                                                           stale: stale, digits: digits)
            }
        }
        label.stringValue = display
        label.setAccessibilityLabel(title)
        item.view?.setFrameSize(NSSize(width: 280, height: 26))
        label.frame = NSRect(x: 18, y: 5, width: 244, height: 16)
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
        guard !offlinePreview else { return "Network access is disabled in offline UI preview." }
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
if CommandLine.arguments.contains("--test-credit-usage") {
    _ = NSApplication.shared
    AppDelegate().testCreditUsage()
    exit(0)
}
if CommandLine.arguments.contains("--test-menu-layout") {
    _ = NSApplication.shared
    AppDelegate().testMenuLayout()
    exit(0)
}
if CommandLine.arguments.contains("--test-recording-lifecycle") {
    _ = NSApplication.shared
    try AppDelegate().testRecordingLifecycle()
    exit(0)
}
if CommandLine.arguments.contains("--test-sentence-pause-slider") {
    _ = NSApplication.shared
    AppDelegate().testSentencePauseSlider()
    exit(0)
}
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
