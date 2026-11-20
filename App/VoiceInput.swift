// 语音输入，两种：
// - 听写：输入框里右侧的小麦克风，点一下开始，说的话直接写进输入框，再点一下停。
// - 按住说话：最左边的 🔈 把输入框换成「按住 说话」（再点 ⌨️ 换回）。按住说，松开发送；
//   按着往右滑到 ✏️ 上松开是把文字放进输入框改，滑到最右的 ✕ 上松开是取消；文字边说边显示在输入框上方。
// 识别在设备上做（SpeechAnalyzer + DictationTranscriber），出来的是文字，走和打字一样的发送路径，
// 所以引擎和各个主机都不用改。

import AVFoundation
import Speech
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Where the finger is while holding the mic.
enum TalkZone: Equatable {
    /// Release sends.
    case send
    /// On the ✕: release drops it.
    case cancel
    /// On the ✏️: release puts the text in the composer to edit.
    case edit
}

/// What changes many times a second while talking. Kept apart from `VoiceRecorder` so only the
/// waveform and the transcript card redraw, not the whole chat page.
@MainActor
final class VoiceLive: ObservableObject {
    @Published var transcript = ""
    /// Recent input levels, 0…1, newest last.
    @Published var levels: [CGFloat] = Array(repeating: 0, count: VoiceRecorder.bars)
}

/// One push-to-talk recording.
@MainActor
final class VoiceRecorder: ObservableObject {
    enum Start { case recording, askedPermission, denied, unavailable, downloading, released }

    /// Audio on and the finger down: the composer shows the talking row.
    @Published private(set) var recording = false
    @Published var zone: TalkZone = .send
    let live = VoiceLive()
    /// The person still wants to talk (finger on 按住 说话, or dictation tapped on), set straight from
    /// the touch — before `begin` gets to run, so a release before recording started stops it as soon as it starts.
    var held = false
    /// Dictation (the mic in the field): the words go into the text field, not a send.
    @Published var handsFree = false
    /// Where the press began (global). The finger can land where ✏️ then appears:
    /// the targets count only once it has moved off that spot.
    var origin: CGPoint?
    /// The ✕ and ✏️ targets on screen, in global coordinates.
    var cancelFrame = CGRect.null
    var editFrame = CGRect.null

    static let bars = 28
    /// A press shorter than this is a slip, not speech.
    static let shortest: TimeInterval = 0.35
    /// On-device recognition has no time limit; a stuck finger must not record forever.
    static let longest: TimeInterval = 120

    private let audio = AVAudioEngine()
    private let queue = DispatchQueue(label: "voice-input")
    private var feed: AnalyzerFeed?
    /// The running SpeechAnalyzer, kept untyped so the recorder loads on older systems.
    private var analyzerObject: AnyObject?
    private var reading: Task<Void, Never>?
    /// A recording is under way, including the moment after release while the last words arrive.
    private var active = false
    /// Bumped for every recording, so a finished one's late results are ignored.
    private var generation = 0
    /// What the recognizer has settled on, piece by piece; `guess` is its current take on what follows.
    private var settledText: [String] = []
    private var guess = ""
    /// The finger is up: the analyzer is finishing the last words.
    private var ending = false
    private var started = Date()
    private var levelAt = Date.distantPast
    /// The recognizer said its last word (or gave up).
    private var settled = false
    private var interruption: NSObjectProtocol?
    /// UI tests: a recording played in place of the microphone (Debug builds only).
    private var testFeed: TestFeed?
    #if DEBUG
    private let prerecorded: URL?
    private let testLocale: Locale?

    init(prerecorded: URL? = nil, testLocale: Locale? = nil) {
        self.prerecorded = prerecorded
        self.testLocale = testLocale
    }
    #endif
    private var limitTimer: Timer?
    /// Called when recording stops on its own (a call came in, the time limit).
    var stoppedOnItsOwn: (() -> Void)?
    /// A speech model download is under way (first use of a language on this phone).
    private static var installing = false
    static var supported: Bool {
        if #available(iOS 26, macOS 26, *) { return true }
        return false
    }

    /// Starts recording, unless permission is still to be asked or was refused.
    /// The first press only asks: the system alerts would end the hold anyway.
    func begin(hints: [String]) async -> Start {
        guard held, !Task.isCancelled else { return .released }
        guard !active else { return ending ? .released : .recording }
        guard #available(iOS 26, macOS 26, *) else { return .unavailable }
        generation += 1
        let mine = generation
        let file: URL?
        #if DEBUG
        file = prerecorded ?? Self.testAudio
        if prerecorded == nil, let outcome = await checkPermissions() { return outcome }
        #else
        file = nil
        if let outcome = await checkPermissions() { return outcome }
        #endif
        let locale = await recognitionLocale()
        guard wantsRecording(mine) else { return .released }
        guard let locale else {
            UITrace.note("voice no supported locale")
            return .unavailable
        }
        let transcriber = Self.transcriber(locale)
        let asset = await AssetInventory.status(forModules: [transcriber])
        guard wantsRecording(mine) else { return .released }
        switch asset {
        case .installed: break
        case .unsupported:
            UITrace.note("voice locale unsupported \(locale.identifier)")
            return .unavailable
        case .supported, .downloading:
            UITrace.note("voice model missing \(locale.identifier)")
            Self.install(transcriber)
            return .downloading
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            UITrace.note("voice no audio format")
            return .unavailable
        }
        // The checks above awaited: the finger may be up already.
        guard wantsRecording(mine) else { return .released }
        guard !active else { return .recording }

        live.transcript = ""
        live.levels = Array(repeating: 0, count: Self.bars)
        settledText = []
        guess = ""
        ending = false
        settled = false
        zone = .send
        active = true
        recording = true
        started = Date()
        // Audio from the start of the press queues in the stream while the model loads.
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        let feed = AnalyzerFeed()
        self.feed = feed
        feed.start(format: format, input: input)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        self.analyzerObject = analyzer
        let context = AnalysisContext()
        let hints = Array(hints.filter { !$0.isEmpty }.prefix(100))
        if !hints.isEmpty { context.contextualStrings[.general] = hints }
        reading = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, mine == self.generation else { return }
                    self.take(String(result.text.characters), final: result.isFinal)
                }
            } catch {
                UITrace.note("voice results ended \(Log.reason(error))")
            }
            guard let self, mine == self.generation else { return }
            self.settled = true
        }
        Task { [weak self] in
            do {
                guard self?.generation == mine else { return }
                try await analyzer.setContext(context)
                guard self?.generation == mine else { return }
                try await analyzer.start(inputSequence: stream)
            } catch {
                UITrace.note("voice analyzer start failed \(Log.reason(error))")
                guard let self, mine == self.generation else { return }
                self.settled = true
            }
        }

        if let file {
            testFeed = TestFeed(file: file, feed: feed) { [weak self] level in
                Task { @MainActor in
                    guard self?.generation == mine else { return }
                    self?.push(level)
                }
            }
        }
        let ok = testFeed != nil ? true : await withCheckedContinuation { continuation in
            queue.async { [audio] in
                do {
                    #if os(iOS)
                    let session = AVAudioSession.sharedInstance()
                    // .default, not .measurement: keep the microphone's own gain and noise handling, as
                    // the system's dictation does. Quiet or slightly distant speech is lost without them.
                    try session.setCategory(.record, mode: .default, options: [.duckOthers, .allowBluetoothHFP])
                    try session.setActive(true, options: .notifyOthersOnDeactivation)
                    #endif
                    let input = audio.inputNode
                    let format = input.outputFormat(forBus: 0)
                    guard format.sampleRate > 0, format.channelCount > 0 else { throw CocoaError(.featureUnsupported) }
                    input.removeTap(onBus: 0)
                    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                        feed.append(buffer)
                        let level = Self.level(buffer)
                        Task { @MainActor in
                            guard self?.generation == mine else { return }
                            self?.push(level)
                        }
                    }
                    audio.prepare()
                    try audio.start()
                    continuation.resume(returning: true)
                } catch {
                    Log.engine.error("voice input: audio start failed \(Log.reason(error), privacy: .public)")
                    continuation.resume(returning: false)
                }
            }
        }
        guard active, mine == generation else { return .released }
        guard ok else {
            UITrace.note("voice audio start failed")
            stopAudio(); stopAnalyzer(); tearDown()
            return .unavailable
        }
        // Released (or cancelled) while the audio was starting: `finish` or `cancel` already ran.
        guard wantsRecording(mine) else {
            UITrace.note("voice released before audio started")
            cancel()
            return .released
        }
        UITrace.note("voice recording locale=\(locale.identifier)")

        #if os(macOS)
        let interruptionName = Notification.Name.AVAudioEngineConfigurationChange
        let interruptionObject: AnyObject? = audio
        #else
        let interruptionName = AVAudioSession.interruptionNotification
        let interruptionObject: AnyObject? = nil
        #endif
        interruption = NotificationCenter.default.addObserver(forName: interruptionName, object: interruptionObject, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.active else { return }
                UITrace.note("voice interrupted")
                self.cancel()
                self.stoppedOnItsOwn?()
            }
        }
        limitTimer = Timer.scheduledTimer(withTimeInterval: Self.longest, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.recording else { return }
                self.stoppedOnItsOwn?()
            }
        }
        return .recording
    }

    /// Asks for the microphone and speech recognition if never asked (on switching to voice), so the
    /// first hold already records, and fetches the speech model if this phone lacks it. False when
    /// either permission is refused.
    func prepare() async -> Bool {
        #if DEBUG
        let suppliedAudio = prerecorded != nil
        #else
        let suppliedAudio = false
        #endif
        if !suppliedAudio, !(await askPermissions()) { return false }
        if #available(iOS 26, macOS 26, *), let locale = await recognitionLocale() {
            let transcriber = Self.transcriber(locale)
            let status = await AssetInventory.status(forModules: [transcriber])
            if status == .supported || status == .downloading { Self.install(transcriber) }
        }
        return true
    }

    private func wantsRecording(_ id: Int) -> Bool { held && generation == id && !Task.isCancelled }

    private func checkPermissions() async -> Start? {
        #if os(macOS)
        let unasked = AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        #else
        let unasked = AVAudioApplication.shared.recordPermission == .undetermined || SFSpeechRecognizer.authorizationStatus() == .notDetermined
        #endif
        if unasked { return await askPermissions() ? .askedPermission : .denied }
        return Self.allowed ? nil : .denied
    }

    private func askPermissions() async -> Bool {
        #if os(macOS)
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
        #else
        if AVAudioApplication.shared.recordPermission == .undetermined { _ = await AVAudioApplication.requestRecordPermission() }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        }
        #endif
        return Self.allowed
    }

    /// Stops and returns what was said: nil for a slip (too short to be speech), empty for silence.
    /// The talking row goes away at once; the last words may take a moment more.
    func finish() async -> String? {
        guard active, !ending else { return nil }
        let mine = generation
        let held = Date().timeIntervalSince(started)
        recording = false
        stopAudio()
        if held < Self.shortest {
            UITrace.note("voice slip \(Int(held * 1000))ms")
            stopAnalyzer()
            tearDown()
            return nil
        }
        ending = true
        feed?.end()
        if #available(iOS 26, macOS 26, *), let analyzer = analyzerObject as? SpeechAnalyzer {
            Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        }
        // The last words arrive after the audio ends; give the recognizer a moment.
        for _ in 0..<30 where !settled {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch {
                if generation == mine { cancel() }
                return nil
            }
            guard generation == mine else { return nil }
        }
        guard generation == mine else { return nil }
        let text = live.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        UITrace.note("voice finished held=\(Int(held * 1000))ms settled=\(settled) chars=\(text.count) pieces=\(settledText.count)")
        if !settled { stopAnalyzer() }
        tearDown()
        return text
    }

    func cancel() {
        held = false
        guard active else { generation += 1; return }
        UITrace.note("voice cancelled")
        recording = false
        stopAudio()
        stopAnalyzer()
        tearDown()
    }

    /// One result: a final one closes its stretch of audio; a volatile one is a guess that the next replaces.
    private func take(_ text: String, final: Bool) {
        if final {
            if !text.isEmpty { settledText.append(text) }
            guess = ""
        } else {
            guess = text
        }
        let joined = Self.join(settledText + [guess])
        if joined != live.transcript { live.transcript = joined }
    }

    private func stopAudio() {
        limitTimer?.invalidate(); limitTimer = nil
        if let testFeed { testFeed.stop(); self.testFeed = nil; return }
        queue.async { [audio] in
            audio.inputNode.removeTap(onBus: 0)
            if audio.isRunning { audio.stop() }
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
    }

    private func stopAnalyzer() {
        feed?.end()
        reading?.cancel()
        if #available(iOS 26, macOS 26, *), let analyzer = analyzerObject as? SpeechAnalyzer { Task { await analyzer.cancelAndFinishNow() } }
    }

    /// Pieces in order. The recognizer spaces its own words; this only keeps two Latin words from
    /// running together where one piece ends and the next begins.
    nonisolated static func join(_ parts: [String]) -> String {
        var text = ""
        for part in parts where !part.isEmpty {
            if let last = text.last, let first = part.first, !last.isWhitespace, !first.isWhitespace,
               last.isASCII, first.isASCII, first.isLetter || first.isNumber,
               last.isLetter || last.isNumber || ".,!?;:".contains(last) {
                text += " "
            }
            text += part
        }
        return text
    }

    /// Keeps the original draft and separates Latin text at the insertion point.
    nonisolated static func appending(_ words: String, to draft: String) -> String {
        guard let last = draft.last, let first = words.first else { return draft + words }
        let space = last.isASCII && first.isASCII && !last.isWhitespace ? " " : ""
        return draft + space + words
    }

    private func tearDown() {
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        interruption = nil
        generation += 1
        reading = nil
        analyzerObject = nil
        feed = nil
        active = false
        ending = false
        recording = false
        zone = .send
    }

    /// About 20 updates a second is plenty for the bars.
    private func push(_ level: CGFloat) {
        guard recording else { return }
        let now = Date()
        guard now.timeIntervalSince(levelAt) >= 0.05 else { return }
        levelAt = now
        var levels = live.levels
        levels.removeFirst()
        levels.append(level)
        live.levels = levels
    }

    /// The zone under a finger at `point` (global coordinates): the ✕ (and anything past it on the
    /// right), the ✏️, or anywhere else. Generous up and down: the thumb drifts while it slides.
    func zone(at point: CGPoint) -> TalkZone {
        if let origin, hypot(point.x - origin.x, point.y - origin.y) < 24 { return .send }
        func near(_ frame: CGRect) -> Bool { !frame.isNull && point.x >= frame.minX - 6 && abs(point.y - frame.midY) < 90 }
        if near(cancelFrame) { return .cancel }
        if near(editFrame) { return .edit }
        return .send
    }

    nonisolated static func levelOf(_ buffer: AVAudioPCMBuffer) -> CGFloat { level(buffer) }

    private nonisolated static func level(_ buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        let rms = (sum / Float(count)).squareRoot()
        // -50 dB → 0, -10 dB → 1.
        let db = 20 * log10(max(rms, 1e-6))
        return CGFloat(min(1, max(0, (db + 50) / 40)))
    }

    #if DEBUG
    /// `-voiceTestAudio <file in Documents>`: device UI tests speak from a file, not the room.
    private static var testAudio: URL? {
        #if os(iOS)
        guard let name = UserDefaults.standard.string(forKey: "voiceTestAudio"), !name.isEmpty else { return nil }
        let url = URL.documentsDirectory.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
        #else
        return nil
        #endif
    }
    #endif

    /// Both permissions granted: a short press is then a slip, not the first-time permission ask.
    nonisolated static var allowedNow: Bool {
        #if os(macOS)
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        #else
        AVAudioApplication.shared.recordPermission == .granted && SFSpeechRecognizer.authorizationStatus() == .authorized
        #endif
    }

    static var allowed: Bool { allowedNow }

    /// The system's dictation model, with punctuation and live guesses while speaking.
    @available(iOS 26, macOS 26, *)
    private static func transcriber(_ locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
    }

    @available(iOS 26, macOS 26, *)
    private func recognitionLocale() async -> Locale? {
        #if DEBUG
        if let testLocale { return await DictationTranscriber.supportedLocale(equivalentTo: testLocale) }
        #endif
        return await Self.locale()
    }

    /// Fetches the speech model in the background; the next press uses it.
    @available(iOS 26, macOS 26, *)
    private static func install(_ transcriber: DictationTranscriber) {
        guard !installing else { return }
        installing = true
        Task {
            defer { installing = false }
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
                UITrace.note("voice model installed")
            } catch {
                UITrace.note("voice model install failed \(Log.reason(error))")
            }
        }
    }

    /// The phone's languages in order, Chinese first when it is one of them, else Chinese.
    @available(iOS 26, macOS 26, *)
    static func locale() async -> Locale? {
        var candidates = Locale.preferredLanguages.map { Locale(identifier: $0) }
        if let chinese = candidates.firstIndex(where: { $0.language.languageCode == .chinese }), chinese > 0 {
            candidates.insert(candidates.remove(at: chinese), at: 0)
        }
        candidates.append(Locale(identifier: "zh-CN"))
        for candidate in candidates {
            if let locale = await DictationTranscriber.supportedLocale(equivalentTo: candidate) { return locale }
        }
        return nil
    }
}

/// 按住 说话: in voice mode it takes the text field's place. Hold to talk, let go to send, or slide
/// right onto ✏️ or ✕ first. VoiceOver: activate to start, again to send.
struct HoldToTalkBar: View {
    @ObservedObject var recorder: VoiceRecorder
    let begin: () -> Void
    let end: (TalkZone) -> Void
    @State private var pressed = false
    /// Goes false when the system takes the touch away (an alert, a call) without an end.
    @GestureState private var touching = false

    var body: some View {
        let live = recorder.recording
        ZStack {
            if live {
                TalkWave(live: recorder.live, cancelling: recorder.zone != .send).padding(.horizontal, 12)
            } else {
                (pressed ? Text("松开 结束") : Text("按住 说话")).font(.body.weight(.medium)).foregroundStyle(ChatColors.ink)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 40)
        .background((pressed || live) ? Color.accentColor.opacity(0.16) : ChatColors.muted.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(Motion.std(Motion.quick), value: pressed)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { value in
                    if !pressed {
                        pressed = true
                        recorder.handsFree = false
                        recorder.held = true
                        recorder.origin = value.startLocation
                        #if os(iOS)
                        SidePanelSwipe.paused = true
                        #endif
                        begin()
                        return
                    }
                    guard recorder.recording else { return }
                    let next = recorder.zone(at: value.location)
                    if next != recorder.zone {
                        recorder.zone = next
                        #if os(iOS)
                        UISelectionFeedbackGenerator().selectionChanged()
                        #endif
                    }
                }
                .onEnded { _ in release() }
        )
        .onChange(of: touching) { _, now in if !now && pressed { release() } }
        .accessibilityElement()
        .accessibilityLabel(live ? String(localized: "结束并发送") : String(localized: "按住 说话"))
        .accessibilityIdentifier("holdToTalk")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if recorder.recording { recorder.held = false; end(.send) }
            else { recorder.handsFree = false; recorder.held = true; recorder.origin = nil; begin() }
        }
    }

    private func release() {
        guard pressed else { return }
        pressed = false
        recorder.held = false
        #if os(iOS)
        SidePanelSwipe.paused = false
        #endif
        end(recorder.zone)
    }
}

/// The small mic inside the text field: tap to dictate into it, tap again to stop. While listening
/// it fills and breathes with the voice.
struct DictationKey: View {
    @ObservedObject var recorder: VoiceRecorder
    let tap: () -> Void

    var body: some View {
        let live = recorder.recording && recorder.handsFree
        Button(action: tap) {
            ZStack {
                if live { DictationPulse(live: recorder.live) }
                Image(systemName: live ? "mic.fill" : "mic")
                    .font(.system(size: 16, weight: .medium)).frame(width: 30, height: 30)
                    .foregroundStyle(live ? Color.white : ChatColors.muted)
                    .background(live ? Color.accentColor : Color.clear, in: Circle())
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .animation(Motion.thumbSpring, value: live)
        .accessibilityLabel(live ? String(localized: "停止听写") : String(localized: "听写"))
        .accessibilityIdentifier("dictation")
    }
}

/// A ring around the dictation mic that grows with the input level.
private struct DictationPulse: View {
    @ObservedObject var live: VoiceLive
    var body: some View {
        Circle().fill(Color.accentColor.opacity(0.25))
            .frame(width: 30, height: 30)
            .scaleEffect(1 + (live.levels.last ?? 0) * 0.6)
            .animation(.easeOut(duration: 0.1), value: live.levels.last)
    }
}

/// ✏️ or ✕ in place of ＋ while holding 按住 说话: slid onto, filled while the finger is on it.
struct TalkTarget: View {
    enum Kind { case cancel, edit }
    let kind: Kind
    @ObservedObject var recorder: VoiceRecorder
    let tap: () -> Void

    var body: some View {
        let on = recorder.zone == (kind == .cancel ? .cancel : .edit)
        let tint = kind == .cancel ? Color.red : Color.accentColor
        Button(action: tap) {
            Image(systemName: kind == .cancel ? "xmark" : "pencil")
                .font(.system(size: 17, weight: .semibold)).frame(width: 36, height: 36)
                .foregroundStyle(on ? Color.white : ChatColors.ink)
                .background(on ? tint : ChatColors.muted.opacity(0.12), in: Circle())
                .scaleEffect(on ? 1.12 : 1)
                .animation(Motion.thumbSpring, value: on)
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
            if kind == .cancel { recorder.cancelFrame = frame } else { recorder.editFrame = frame }
        }
        .onDisappear { if kind == .cancel { recorder.cancelFrame = .null } else { recorder.editFrame = .null } }
        .accessibilityLabel(kind == .cancel ? String(localized: "取消") : String(localized: "放进输入框"))
    }
}

/// The input level, in place of the text field while talking.
struct TalkWave: View {
    @ObservedObject var live: VoiceLive
    var cancelling = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(live.levels.enumerated()), id: \.offset) { _, level in
                Capsule().fill(cancelling ? ChatColors.muted.opacity(0.5) : Color.accentColor)
                    .frame(width: 3, height: 4 + level * 22)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 36)
        .animation(.linear(duration: 0.05), value: live.levels)
        .accessibilityHidden(true)
    }
}

/// Over the composer while talking: the words so far, once there are any.
struct TalkPreview: View {
    @ObservedObject var live: VoiceLive
    var cancelling = false

    var body: some View {
        if !live.transcript.isEmpty {
            Text(live.transcript).font(.body).foregroundStyle(cancelling ? ChatColors.muted : ChatColors.ink)
                .strikethrough(cancelling, color: ChatColors.muted)
                .lineLimit(6).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .chatCard()
                .padding(.horizontal, 12).padding(.bottom, 6)
                .accessibilityIdentifier("talkPreview")
        }
    }
}


/// Carries microphone audio into the analyzer, converted to the format its model wants.
/// The audio tap calls `append` on its own thread; the main actor starts and ends it.
final class AnalyzerFeed: @unchecked Sendable {
    private let lock = NSLock()
    /// Hands a converted buffer to the analyzer's input stream, and ends that stream.
    private var yield: ((AVAudioPCMBuffer) -> Void)?
    private var finish: (() -> Void)?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?

    @available(iOS 26, macOS 26, *)
    func start(format: AVAudioFormat, input: AsyncStream<AnalyzerInput>.Continuation) {
        lock.withLock {
            finish?()
            self.format = format
            yield = { input.yield(AnalyzerInput(buffer: $0)) }
            finish = { input.finish() }
            converter = nil
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let yield, let format, buffer.frameLength > 0 else { return }
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: format)
            }
            guard let converter else { return }
            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var given = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 { yield(out) }
        }
    }

    func end() {
        lock.withLock {
            finish?()
            yield = nil
            finish = nil
            format = nil
            converter = nil
        }
    }
}


/// Plays an audio file into the recognizer in real time, then silence until stopped — what the
/// microphone would hear if someone said it. Used only by device UI tests (`-voiceTestAudio`).
private final class TestFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    init(file url: URL, feed: AnalyzerFeed, level: @escaping (CGFloat) -> Void) {
        Thread.detachNewThread { [self] in
            guard let file = try? AVAudioFile(forReading: url) else { return }
            let format = file.processingFormat
            let frames: AVAudioFrameCount = 1600
            let chunk = Double(frames) / format.sampleRate
            var next = Date()
            while !isStopped {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
                if (try? file.read(into: buffer, frameCount: frames)) == nil || buffer.frameLength == 0 {
                    buffer.frameLength = frames  // silence after the words
                    if let data = buffer.floatChannelData {
                        for channel in 0..<Int(format.channelCount) { data[channel].update(repeating: 0, count: Int(frames)) }
                    }
                }
                feed.append(buffer)
                level(VoiceRecorder.levelOf(buffer))
                next += chunk
                let wait = next.timeIntervalSinceNow
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
        }
    }

    private var isStopped: Bool { lock.withLock { stopped } }
    func stop() { lock.withLock { stopped = true } }
}
