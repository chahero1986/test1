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
/// - 每轮识别结束后约 0.16 秒自动重开。麦克风不重启（audioEngine 常开，只换 request），
///   避免每句话都「咔哒」开关一次麦克风。间隙越短越不容易吞掉下一个字。
@MainActor
final class VoiceCommandRecognizer: ObservableObject {
    enum Command {
        case trash      // 移入垃圾箱
        case protect    // 加入免删除
        case next       // 下一张
        case previous   // 上一张
        case undo       // 撤销上一次语音标记
        case stop       // 结束聆听
    }

    @Published private(set) var isListening = false
    /// 实时识别文字（界面用黄色显示，让用户确认是否听对）。
    /// 指令一执行就清空：下一张照片从全新状态开始，不残留上一句的内容
    @Published private(set) var transcript = ""
    @Published var errorMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let box = RequestBox()
    private let bag = ObserverBag()
    private var audioEngine: AVAudioEngine?
    private var task: SFSpeechRecognitionTask?
    private var pendingRestart: Task<Void, Never>?
    private var transcriptIdle: Task<Void, Never>?
    /// 看门狗：识别任务长时间没有任何回调（不是 isFinal 也不是 error）就强制重启。
    /// 真机上偶发「第一句正常、第二句起管线假死」——界面还显示聆听中，
    /// 但说什么都没反应，文字停留在上一句。没有看门狗就永远卡死。
    private var watchdog: Task<Void, Never>?
    private var hasTap = false
    private var lastRebuild = Date.distantPast
    /// 识别器暂时不可用时的重试间隔（指数退避，成功后复位）
    private var unavailableRetry: TimeInterval = 0.35

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

    init() {
        installObservers()
    }

    // MARK: - 对外控制

    func start(onCommand: @escaping (Command) -> Void) {
        self.onCommand = onCommand
        if wantsListening {
            // 系统中断 / 耳机插拔后可能停在「想听但引擎已停」的状态：
            // 此时直接忽略点击会让按钮像坏了一样，重新拉起引擎更符合预期
            rebuildEngine(force: true)
            return
        }
        wantsListening = true
        Task { await begin() }
    }

    func stop() {
        wantsListening = false
        isListening = false
        teardownEngine()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        transcriptIdle?.cancel()
        transcriptIdle = nil
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

    /// 关掉引擎与当前识别任务，但保留 wantsListening（系统中断后用得上）
    private func teardownEngine() {
        watchdog?.cancel()
        watchdog = nil
        task?.cancel()
        task = nil
        pendingRestart?.cancel()
        pendingRestart = nil
        // 先摘掉引用再 endAudio：音频线程此刻 append 会拿到 nil，不会写给已关闭的 request
        box.replace(with: nil)?.endAudio()
        if let engine = audioEngine {
            engine.stop()
            if hasTap {
                engine.inputNode.removeTap(onBus: 0)
                hasTap = false
            }
        }
        audioEngine = nil
        generation += 1
    }

    private func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        // 标点会被拼进识别文本，干扰「删」「过」这类单字匹配
        request.addsPunctuation = false
        // 提示识别器偏向这些词，明显提升单字指令的命中率
        request.contextualStrings = [
            "删", "删除", "删掉", "垃圾",
            "留", "保留", "免删",
            "过", "跳过", "下一个",
            "上一张", "撤销", "停止"
        ]
        return request
    }

    private func startTask() {
        guard audioEngine != nil else { return }
        guard let recognizer = self.recognizer else { return }
        guard recognizer.isAvailable else {
            // 暂时不可用（刚结束一轮识别后偶发）：稍后重试。
            // 绝不能静默返回——那会让聆听状态还在、识别管线却已死，
            // 表现就是「第二句开始说什么都没反应」。
            unavailableRetry = min(unavailableRetry * 2, 3.0)
            scheduleRestart(after: unavailableRetry)
            return
        }
        unavailableRetry = 0.35
        generation += 1
        let gen = generation
        // 新一轮从零开始：清掉上一句的识别文字和消费游标
        consumedText = ""
        transcript = ""
        transcriptIdle?.cancel()
        transcriptIdle = nil
        armWatchdog()

        let request = makeRequest()
        box.replace(with: request)
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // 识别回调在内部队列，统一回主线程再改状态
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                if let result { self.handle(result) }
                if error != nil {
                    // 出错通常意味着上一轮任务没正常收尾，退避一点再重开，避免疯狂重试耗电
                    self.scheduleRestart(after: 0.45)
                } else if result?.isFinal ?? false {
                    self.scheduleRestart(after: 0.16)
                }
            }
        }
    }

    private func scheduleRestart(after delay: TimeInterval) {
        // 立刻作废旧任务的一切回调（含 cancel 本身引发的 error 回调）。
        // 不作废的话：error 回调会再次进入 scheduleRestart，把真正的重启
        // 一推再推，表现为「说完一句后长时间没反应」。
        generation += 1
        watchdog?.cancel()
        watchdog = nil
        pendingRestart?.cancel()
        task?.cancel()
        task = nil
        // 先摘掉引用再 endAudio：音频线程此刻 append 会拿到 nil，不会写给已关闭的 request
        box.replace(with: nil)?.endAudio()
        guard isListening else { return }
        pendingRestart = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isListening else { return }
            self.startTask()
        }
    }

    // MARK: - 系统事件（来电、耳机插拔、音频服务重启）

    private func installObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        bag.add(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            Task { @MainActor in self?.handleInterruption(raw) }
        })
        bag.add(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            Task { @MainActor in self?.handleRouteChange(raw) }
        })
        bag.add(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildEngine() }
        })
    }

    /// 来电、闹钟会夺走麦克风。此时如果界面还显示「聆听中」就是在骗人，
    /// 而且引擎已经停了，后续说的指令一句都收不到。
    private func handleInterruption(_ raw: UInt) {
        guard wantsListening, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            isListening = false
            teardownEngine()
        case .ended:
            rebuildEngine()
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ raw: UInt) {
        guard wantsListening, isListening else { return }
        guard let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange, .override:
            rebuildEngine()
        default:
            break
        }
    }

    /// 耳机插拔、中断结束、音频服务重启都会让 AVAudioEngine 失效，原地重建。
    private func rebuildEngine(force: Bool = false) {
        guard wantsListening else { return }
        // 中断结束和路由变化常常前后脚到达，去抖避免连着重启两次；
        // 用户手动点按钮时不受去抖限制
        if !force {
            guard Date().timeIntervalSince(lastRebuild) > 0.5 else { return }
        }
        lastRebuild = Date()
        teardownEngine()
        // 先置位：startTask 里的看门狗依赖 isListening 判断是否需要武装
        isListening = true
        do {
            try startEngine()
            errorMessage = nil
        } catch {
            isListening = false
            wantsListening = false
            errorMessage = "麦克风被系统中断，语音已停止。请重新点按麦克风继续。"
        }
    }

    // MARK: - 结果处理

    private func handle(_ result: SFSpeechRecognitionResult) {
        let text = result.bestTranscription.formattedString
        guard !text.isEmpty else { return }

        // 识别结果被重写（句首插字、改词）→ 已消费标记失效，从头重扫
        if !text.hasPrefix(consumedText) { consumedText = "" }
        let fresh = String(text.dropFirst(consumedText.count))
        // 只显示「还没执行」的部分：已执行的指令不再留在提示条上，
        // 切到下一张照片时不会残留上一句的操作内容
        touchTranscript(fresh)
        guard !fresh.isEmpty, let hit = Self.firstCommand(in: fresh) else { return }
        consumedText += String(fresh.prefix(hit.end))
        fire(hit.command)
    }

    /// 文字保留 2 秒再清空：让用户看清最后听到的是什么，同时不长期显示过期内容
    private func touchTranscript(_ text: String) {
        transcript = text
        transcriptIdle?.cancel()
        transcriptIdle = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.transcript = ""
        }
        armWatchdog()
    }

    /// 看门狗：任务启动或每次收到结果时重置。若 2.5 秒内没有任何回调
    /// （识别管线假死时既不会 isFinal 也不会报错），强制重启识别任务。
    private func armWatchdog() {
        watchdog?.cancel()
        guard isListening else { return }
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled, self.isListening else { return }
            self.scheduleRestart(after: 0.05)
        }
    }

    private func fire(_ command: Command) {
        let now = Date()
        // 兜底防抖：增量扫描本身已避免重复，这里只防同一次识别被投递两遍
        guard now.timeIntervalSince(lastFire) > 0.15 else { return }
        lastFire = now
        // 指令一旦执行就清空识别文字：切换到下一张时从全新状态开始，
        // 不残留上一句的内容（操作结果由详情页的确认提示条负责展示）
        transcript = ""
        transcriptIdle?.cancel()
        transcriptIdle = nil
        onCommand?(command)
    }

    // MARK: - 关键词表

    /// 顺序即优先级：同一起始位置时取靠前的词。
    /// 「留」类必须排在「删」类之前，「免删」才不会命中「删」。
    /// 「上一张」必须排在「一张」类之前，否则会被短词抢先命中。
    private static let keywords: [(word: String, command: Command)] = [
        // 撤销（放最前：含「回」等字，短词容易抢位）
        ("撤销", .undo), ("撤回", .undo), ("反悔", .undo), ("恢复", .undo),
        // 停止聆听
        ("停止", .stop), ("停下", .stop), ("结束", .stop), ("关闭", .stop), ("关了", .stop),
        // 保留类
        ("免删", .protect), ("保留", .protect), ("留着", .protect), ("留下", .protect), ("留", .protect),
        // 删除类
        ("删除", .trash), ("删掉", .trash), ("删", .trash), ("垃圾", .trash),
        // 上一张
        ("上一张", .previous), ("上一个", .previous), ("上一幅", .previous),
        ("回退", .previous), ("往前", .previous), ("前一张", .previous),
        // 下一张
        ("下一张", .next), ("下一个", .next), ("下一幅", .next), ("跳过", .next), ("过", .next)
    ]

    /// 在文本中找**最早出现**的有效指令；同位置取优先级高（rank 小）的那个。
    /// 被规则否决的命中（否定前缀、词中「过」）会被跳过，继续往后找，
    /// 所以「不要跳过，下一个」仍然能正确执行「下一个」。
    static func firstCommand(in text: String) -> (command: Command, end: Int)? {
        var searchStart = text.startIndex
        while searchStart < text.endIndex {
            var best: (range: Range<String.Index>, command: Command, rank: Int)?
            for (rank, item) in keywords.enumerated() {
                guard let range = text.range(of: item.word, options: [], range: searchStart..<text.endIndex) else { continue }
                if let current = best {
                    if range.lowerBound > current.range.lowerBound { continue }
                    if range.lowerBound == current.range.lowerBound, rank >= current.rank { continue }
                }
                best = (range, item.command, rank)
            }
            guard let win = best else { return nil }
            if let resolved = resolve(win.command, in: text, range: win.range) {
                return (resolved, text.distance(from: text.startIndex, to: win.range.upperBound))
            }
            // 被否决：从下一个字符继续扫，保证循环一定前进
            let next = text.index(after: win.range.lowerBound)
            searchStart = next
        }
        return nil
    }

    /// 语义修正
    private static func resolve(_ command: Command, in text: String, range: Range<String.Index>) -> Command? {
        // 「过」是最容易误中的单字：通过 / 不过 / 超过 / 经过 / 难过 都会命中。
        // 要求它前面不是汉字、后面不是汉字（句尾语气词除外），即真正被单独说出来才算指令。
        if text[range] == "过", !isStandaloneGuo(range, in: text) { return nil }

        // 否定前缀：「不要删」「别删」语义相反，转成保留；「不要跳过」这类直接忽略
        if isNegated(range, in: text) {
            return command == .trash ? .protect : nil
        }
        return command
    }

    /// 句尾语气词：「过了」「过吧」是自然说法，不该被当成词中命中
    private static let particles: Set<Character> = ["了", "吧", "啊", "呀", "呢", "哦", "哈", "嘛"]

    private static func isStandaloneGuo(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let prev = text[text.index(before: range.lowerBound)]
            if isHan(prev) { return false }
        }
        if range.upperBound < text.endIndex {
            let next = text[range.upperBound]
            if isHan(next), !particles.contains(next) { return false }
        }
        return true
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        }
    }

    /// 命中位置往前 3 个字内出现「不 / 别 / 勿 / 甭 / 没」即视为否定
    private static func isNegated(_ range: Range<String.Index>, in text: String) -> Bool {
        var index = range.lowerBound
        var steps = 0
        while index > text.startIndex, steps < 3 {
            index = text.index(before: index)
            let character = text[index]
            if "不别勿甭没".contains(character) { return true }
            // 跨过标点/空格就不再看更前面的字，避免「不好，删」被误判成否定
            if character == " " || character == "，" || character == "、" || character == "," { break }
            steps += 1
        }
        return false
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

/// 通知监听令牌的容器：deinit 时统一摘除。
/// 单独一个非隔离类，避免 @MainActor 类的 deinit 里碰隔离状态。
private final class ObserverBag {
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
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
