import Foundation
import AVFoundation
import Speech

/// 本地语音指令识别（纯离线）
///
/// 设计要点：
/// - `requiresOnDeviceRecognition = true`：音频不经网络、不落盘，与「相册不出本机」的定位一致。
///   因此设备不支持离线中文识别时**直接报错**，绝不静默降级成云端识别。
/// - 关键词匹配而非自然语言理解：单字和完整词都认。匹配顺序先「留」后「删」，
///   否则「免删」会被「删」抢先命中、误判成移入垃圾箱。
/// - 一句话可以含多个指令（「删、删、过、留」）：按「已消费前缀」增量扫描，
///   命中一个就把游标推过去，既不重复触发，也不会漏掉后半句。
/// - 每轮识别结束后 0.6 秒自动重开。麦克风不重启（audioEngine 常开，只换 request），
///   避免每句话都「咔哒」开关一次麦克风。
@MainActor
final class VoiceCommandRecognizer: ObservableObject {
    enum Command { case trash, protect, next }

    @Published private(set) var isListening = false
    /// 实时识别文字（界面用黄色显示，让用户确认是否听对）
    @Published private(set) var transcript = ""
    @Published var errorMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let box = RequestBox()
    private var audioEngine: AVAudioEngine?
    private var task: SFSpeechRecognitionTask?
    private var pendingRestart: Task<Void, Never>?
    private var hasTap = false

    /// 用户意图（点开 = true，点关 / 离开页面 = false）。
    /// 与 isListening 分开：授权是异步的，等授权期间用户可能已经退出，
    /// 只看 isListening 会让已经关掉的录音在回调回来后又自己启动。
    private var wantsListening = false

    /// 识别任务代号：重启后旧任务的回调会被作废，避免「一句话执行两次、连跳两张」
    private var generation = 0
    /// 本句话里已被消费的前缀（增量扫描游标）。
    /// 用「已消费文本」而不是字数：识别器会在句首插字或改词，
    /// 只比长度会把同一句「删」判成两次，直接连跳两张。
    private var consumedText = ""
    private var lastFire = Date.distantPast

    private var onCommand: ((Command) -> Void)?

    // MARK: - 对外控制

    func start(onCommand: @escaping (Command) -> Void) {
        guard !wantsListening else { return }
        wantsListening = true
        self.onCommand = onCommand
        Task { await begin() }
    }

    func stop() {
        wantsListening = false
        isListening = false
        generation += 1
        pendingRestart?.cancel()
        pendingRestart = nil
        task?.cancel()
        task = nil
        box.replace(with: nil)?.endAudio()
        if let engine = audioEngine {
            engine.stop()
            if hasTap {
                engine.inputNode.removeTap(onBus: 0)
                hasTap = false
            }
        }
        audioEngine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        transcript = ""
        consumedText = ""
        onCommand = nil
    }

    // MARK: - 启动

    private func begin() async {
        guard await ensureAuthorized() else {
            wantsListening = false
            isListening = false
            errorMessage = "需要麦克风与语音识别权限。请在「设置」中允许本 App 使用麦克风与语音识别。"
            return
        }
        // 等授权期间用户可能已经关掉或退出页面
        guard wantsListening else { return }
        guard let recognizer = self.recognizer, recognizer.isAvailable else {
            wantsListening = false
            errorMessage = "语音识别暂时不可用，请稍后重试。"
            return
        }
        // 只接受本机识别：不做联网降级（音频不出设备是本功能的承诺）
        guard recognizer.supportsOnDeviceRecognition else {
            wantsListening = false
            errorMessage = "此设备暂不支持离线中文语音识别，无法在不上传音频的前提下使用语音指令。"
            return
        }
        guard wantsListening else { return }
        do {
            // 先置位：首轮识别若立刻结束（环境安静），scheduleRestart 需要看到 isListening
            isListening = true
            transcript = ""
            try startEngine()
            errorMessage = nil
        } catch {
            errorMessage = "无法启动麦克风：\(error.localizedDescription)"
            stop()
        }
    }

    private func ensureAuthorized() async -> Bool {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func startEngine() throws {
        let session = AVAudioSession.sharedInstance()
        // .record 会中断正在播放的视频音频，这是语音输入的合理代价
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let engine = AVAudioEngine()
        // 先挂上引用：installTap 之后 engine.start() 抛错时，stop() 才清得掉 tap
        audioEngine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceError.noInput
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [box] buffer, _ in
            box.append(buffer)
        }
        hasTap = true
        engine.prepare()
        try engine.start()
        startTask()
    }

    private func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        // 提示识别器偏向这些词，明显提升单字指令的命中率
        request.contextualStrings = ["删", "删除", "垃圾", "过", "下一个", "跳过", "留", "保留", "免删"]
        return request
    }

    private func startTask() {
        guard audioEngine != nil, let recognizer = self.recognizer, recognizer.isAvailable else { return }
        generation += 1
        let gen = generation
        consumedText = ""
        transcript = ""

        let request = makeRequest()
        box.replace(with: request)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // 识别回调在内部队列，统一回主线程再改状态
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                if let result { self.handle(result) }
                if error != nil || (result?.isFinal ?? false) {
                    self.scheduleRestart()
                }
            }
        }
    }

    private func scheduleRestart() {
        pendingRestart?.cancel()
        task?.cancel()
        task = nil
        // 先摘掉引用再 endAudio：音频线程此刻 append 会拿到 nil，不会写给已关闭的 request
        box.replace(with: nil)?.endAudio()
        guard isListening else { return }
        pendingRestart = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled, self.isListening else { return }
            self.startTask()
        }
    }

    // MARK: - 结果处理

    private func handle(_ result: SFSpeechRecognitionResult) {
        let text = result.bestTranscription.formattedString
        guard !text.isEmpty else { return }
        transcript = text

        // 识别结果被重写（句首插字、改词）→ 已消费标记失效，从头重扫
        if !text.hasPrefix(consumedText) { consumedText = "" }
        let fresh = String(text.dropFirst(consumedText.count))
        guard !fresh.isEmpty, let hit = Self.firstCommand(in: fresh) else { return }
        consumedText += String(fresh.prefix(hit.end))
        fire(hit.command)
    }

    private func fire(_ command: Command) {
        let now = Date()
        // 兜底防抖：增量扫描本身已避免重复，这里只防同一次识别被投递两遍
        guard now.timeIntervalSince(lastFire) > 0.15 else { return }
        lastFire = now
        onCommand?(command)
    }

    // MARK: - 关键词表

    /// 顺序即优先级：同一起始位置时取靠前的词。
    /// 「留」类必须排在「删」类之前，「免删」才不会命中「删」。
    private static let keywords: [(word: String, command: Command)] = [
        ("免删", .protect), ("保留", .protect), ("留着", .protect), ("留下", .protect), ("留", .protect),
        ("删除", .trash), ("删掉", .trash), ("删", .trash), ("垃圾", .trash), ("不要", .trash),
        ("下一个", .next), ("下一张", .next), ("跳过", .next), ("继续", .next), ("过", .next)
    ]

    /// 在文本中找**最早出现**的指令词；同位置取优先级高（rank 小）的那个。
    /// 返回命中指令与它在文本中的结束偏移，供调用方推进游标。
    private static func firstCommand(in text: String) -> (command: Command, end: Int)? {
        var best: (lower: String.Index, end: String.Index, command: Command, rank: Int)?
        for (rank, item) in keywords.enumerated() {
            guard let range = text.range(of: item.word) else { continue }
            if let current = best {
                if range.lowerBound > current.lower { continue }
                if range.lowerBound == current.lower, rank >= current.rank { continue }
            }
            best = (range.lowerBound, range.upperBound, item.command, rank)
        }
        guard let win = best else { return nil }
        return (win.command, text.distance(from: text.startIndex, to: win.end))
    }
}

/// 音频 tap 与识别 request 之间的可变引用：
/// 重启识别只换 request，麦克风与 tap 保持不动（否则每句话都要「咔哒」开关一次麦克风）。
/// 需加锁：tap 在音频线程读、主线程写；对已 endAudio 的 request 再 append 会崩。
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SFSpeechAudioBufferRecognitionRequest?

    /// 换入新 request 并返回旧的（由调用方 endAudio）
    func replace(with request: SFSpeechAudioBufferRecognitionRequest?) -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock()
        let old = current
        current = request
        lock.unlock()
        return old
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        current?.append(buffer)
        lock.unlock()
    }
}

enum VoiceError: LocalizedError {
    case noInput

    var errorDescription: String? {
        switch self {
        case .noInput: return "麦克风输入不可用"
        }
    }
}
