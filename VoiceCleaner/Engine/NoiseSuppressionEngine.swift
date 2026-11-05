import Foundation
import AVFoundation

/// 实时降噪引擎：把麦克风输入实时降噪后输出。
///
/// 线程模型：
/// - **采集线程**（`installTap` 回调）：把原始样本写入环形缓冲。
/// - **处理线程**（`DispatchSource` 定时器）：从环形缓冲取数据 → 降噪 → 写回输出环形缓冲。
/// - **播放线程**（`AVAudioSourceNode` 渲染回调）：从输出环形缓冲取数据送出。
///
/// 关键点：降噪运算**不在音频渲染回调里做**，避免超时导致爆音（underrun）。
///
/// 设计为 `@unchecked Sendable`：内部状态只被单一处理线程访问，
/// 环形缓冲区本身是 SPSC 无锁的。
final class NoiseSuppressionEngine: @unchecked Sendable {

    enum OutputMode: String, CaseIterable {
        /// 实时外放处理后的声音。**这是唯一能把降噪音频交给其他 App 的模式**：
        /// 目标 App 的麦克风去拾取扬声器里干净的语音。
        case monitor
        /// 只处理不外放，适合自己 Recording / 不做外放的场景
        case silent
        /// 处理后的声音写入文件
        case record

        var displayName: String {
            switch self {
            case .monitor: return "实时外放（推荐）"
            case .silent: return "静音处理"
            case .record: return "录制文件"
            }
        }
    }

    enum State: Equatable {
        case idle
        case learningNoise
        case running
        case failed(String)
    }

    // MARK: - 依赖

    private let engine = AVAudioEngine()
    private let inputNode: AVAudioInputNode
    private var sourceNode: AVAudioSourceNode?

    /// 麦克风 → 处理线程
    private let inputBuffer: AudioRingBuffer
    /// 处理线程 → 播放线程
    private let outputBuffer: AudioRingBuffer

    /// 降噪器（只在处理线程访问）
    private var denoiser: SpectralDenoiser
    private var denoiserConfig: SpectralDenoiser.Configuration

    /// 处理线程工作区（预分配，避免实时分配）
    private var workBuffer: [Float]
    private var processedBuffer: [Float]

    // MARK: - 线程与同步

    private var processingTimer: DispatchSourceTimer?
    private let processingQueue = DispatchQueue(label: "com.qweq-1.voicecleaner.processing", qos: .userInitiated)
    private let stateLock = NSLock()
    private var _state: State = .idle

    private var _stats = EngineStats()
    private let statsLock = NSLock()

    /// 噪声剖面快照锁（降噪器在处理线程写，主线程读）
    private let profileLock = NSLock()
    private var _noiseProfileSnapshot: [Float] = []

    /// 实际生效的音频格式
    private var format: AVAudioFormat
    /// 是否正在运行
    private var isRunning = false
    /// 是否已安装采集 tap（无 tap 时调 removeTap 会告警）
    private var tapInstalled = false
    /// 当前输出模式（决定是否把处理后的音频写进输出缓冲）
    private var currentMode: OutputMode = .silent

    // 音频流诊断：区分「tap 没被驱动」和「tap 有回调但处理没跑」
    private var inputCallbackCount = 0
    private var didReportAudioFlow = false
    private var processingStartedAt: Date?

    // MARK: - 录制

    private var audioFile: AVAudioFile?
    private var recordingURL: URL?

    /// 启动诊断日志（展示在界面上，便于定位「点了没反应」这类问题）
    let log = DiagnosticLog()

    /// 降噪后音频的输出回调（可用于写入文件 / 推流）
    var onProcessedAudio: ((AVAudioPCMBuffer) -> Void)?

    /// 状态变化回调（主线程）
    var onStateChange: ((State) -> Void)?

    // MARK: - 初始化

    init(configuration: SpectralDenoiser.Configuration = SpectralDenoiser.Configuration()) {
        let cfg = configuration.validated()
        denoiserConfig = cfg
        denoiser = SpectralDenoiser(configuration: cfg)

        let hop = cfg.hopSize
        // 环形缓冲留 16 帧余量，容忍调度抖动
        let ringSize = Self.nextPowerOfTwo(hop * 16)
        inputBuffer = AudioRingBuffer(capacity: ringSize)
        outputBuffer = AudioRingBuffer(capacity: ringSize)

        workBuffer = [Float](repeating: 0, count: hop)
        processedBuffer = [Float](repeating: 0, count: hop)

        format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        inputNode = engine.inputNode
    }

    /// 静态方法：init 里所有存储属性初始化完成前不能调用实例方法
    private static func nextPowerOfTwo(_ v: Int) -> Int {
        var n = 1
        while n < v { n <<= 1 }
        return n
    }

    // MARK: - 状态

    var state: State {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }

    private func setState(_ newState: State) {
        stateLock.lock()
        _state = newState
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(newState)
        }
    }

    var stats: EngineStats {
        statsLock.lock(); defer { statsLock.unlock() }
        return _stats
    }

    /// 噪声剖面快照（主线程安全读取）
    func noiseProfileSnapshot() -> [Float] {
        profileLock.lock(); defer { profileLock.unlock() }
        return _noiseProfileSnapshot
    }



    // MARK: - 控制

    /// 启动引擎。
    ///
    /// 分步执行并记录到 `log`；任何一步失败都会抛出具名错误，
    /// 同时尝试**自动降级**（关掉硬件语音处理）再启动一次——
    /// 那条链路在部分机型/外接设备组合下会失败，但不该让整个 App 不可用。
    ///
    /// - Parameters:
    ///   - mode: 输出模式
    ///   - useHardwareVoiceProcessing: 是否启用 Apple 硬件语音处理单元
    func start(mode: OutputMode, useHardwareVoiceProcessing: Bool = true) throws {
        guard !isRunning else { return }
        log.clear()
        log.record("开始启动", "模式=\(mode.rawValue)，硬件语音处理=\(useHardwareVoiceProcessing ? "开" : "关")")

        do {
            try attemptStart(mode: mode, useHardwareVoiceProcessing: useHardwareVoiceProcessing)
            log.record("启动完成", "采样率 \(Int(format.sampleRate)) Hz，帧长 \(denoiserConfig.frameSize)，跳 \(denoiserConfig.hopSize)")
        } catch let firstError {
            log.failure("首次启动失败", "\(firstError.localizedDescription)")
            teardown()

            // 自动降级：关掉硬件语音处理（最容易在特定机型上失败的一环）再试一次
            guard useHardwareVoiceProcessing else {
                hardwareVoiceProcessingFallback = false
                setState(.failed(firstError.localizedDescription))
                throw firstError
            }
            log.record("自动降级", "关闭硬件语音处理后重试")
            do {
                try attemptStart(mode: mode, useHardwareVoiceProcessing: false)
                hardwareVoiceProcessingFallback = true
                log.record("降级启动成功", "音质会略降，但功能可用")
            } catch let secondError {
                log.failure("降级启动也失败", "\(secondError.localizedDescription)")
                teardown()
                setState(.failed(secondError.localizedDescription))
                throw secondError
            }
        }

        isRunning = true
        setState(.learningNoise)
    }

    /// 单次启动尝试：会话 → 输入格式 → 硬件处理 → 音频图 → tap → 引擎。
    private func attemptStart(mode: OutputMode, useHardwareVoiceProcessing: Bool) throws {

        // ---- 1) 麦克风权限 ----
        // 没有权限时系统的输入格式会是 0 Hz，继续走下去只会得到一个
        // 语焉不详的底层错误。在这里提前失败，给出可执行的建议。
        guard AudioSessionConfigurator.permissionGranted else {
            log.failure("麦克风权限", "未授权")
            throw EngineStartupError.microphonePermissionDenied
        }
        log.record("麦克风权限", "已授权")

        // ---- 2) 音频会话 ----
        do {
            try AudioSessionConfigurator.configure(voiceChatMode: useHardwareVoiceProcessing)
        } catch {
            log.failure("音频会话", "\(error.localizedDescription)")
            throw EngineStartupError.sessionConfigurationFailed(error.localizedDescription)
        }
        let session = AVAudioSession.sharedInstance()
        log.record("音频会话", "\(session.category.rawValue) / \(session.mode.rawValue)，"
                  + "采样率 \(Int(session.sampleRate)) Hz，缓冲 \(String(format: "%.1f", session.ioBufferDuration * 1000)) ms")

        // ---- 3) 输入格式 ----
        // 会话刚激活时输入格式偶尔还是 0；重新激活一次再读。
        var inputFormat = inputNode.inputFormat(forBus: 0)
        if inputFormat.sampleRate <= 0 || inputFormat.channelCount == 0 {
            log.record("输入格式异常", "\(inputFormat.sampleRate) Hz / \(inputFormat.channelCount) 声道，重新激活会话")
            try? session.setActive(false)
            try? session.setActive(true)
            inputFormat = inputNode.inputFormat(forBus: 0)
        }
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            log.failure("输入格式", "仍为 \(inputFormat.sampleRate) Hz / \(inputFormat.channelCount) 声道")
            throw EngineStartupError.inputUnavailable(
                "格式 \(inputFormat.sampleRate) Hz / \(inputFormat.channelCount) 声道")
        }
        format = inputFormat
        log.record("输入格式", "\(Int(inputFormat.sampleRate)) Hz，\(inputFormat.channelCount) 声道")

        // ---- 4) 硬件语音处理单元（AEC + AGC + 硬件降噪）----
        // 必须在 installTap 之前调用；只在 .voiceChat 模式下生效。
        if useHardwareVoiceProcessing {
            enableHardwareVoiceProcessing()
            if isHardwareVoiceProcessingEnabled {
                log.record("硬件语音处理", "已启用")
            } else {
                // 不致命：纯软件降噪仍然可用
                log.record("硬件语音处理", "本机不支持，已跳过（用纯软件降噪）")
            }
        } else {
            hardwareFallbackReason = "用户关闭或已降级"
            log.record("硬件语音处理", "未启用")
        }

        // ---- 5) 降噪器按实际采样率重建 ----
        var cfg = denoiserConfig
        cfg.sampleRate = Float(inputFormat.sampleRate)
        denoiserConfig = cfg.validated()
        denoiser = SpectralDenoiser(configuration: denoiserConfig)
        workBuffer = [Float](repeating: 0, count: denoiserConfig.hopSize)
        processedBuffer = [Float](repeating: 0, count: denoiserConfig.hopSize)

        // ---- 6) 安装采集 tap ----
        // format 传 nil：用节点自己的格式，避免与硬件格式不一致触发断言。
        inputNode.installTap(onBus: 0,
                             bufferSize: AVAudioFrameCount(denoiserConfig.hopSize * 4),
                             format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.handleInput(buffer)
        }
        tapInstalled = true
        log.record("采集 tap", "已安装，bufferSize=\(denoiserConfig.hopSize * 4)")

        // ---- 7) 音频图 ----
        // 关键：**输出链路必须完整**。只挂 tap 而不把任何东西连到 output
        // 会让 AVAudioEngine 拿不到渲染驱动，start() 直接抛错或 tap 永不触发。
        // 所以无论哪种模式都把 source node 接到主混音器，
        // 静音模式用 outputVolume = 0 保证不外放（避免回授）。
        setupOutputChain()
        // 混音器恒定满音量：静音不靠 outputVolume=0，而是**不往输出缓冲写数据**。
        // 这样渲染链始终被完整驱动，输入 tap 一定会被拉流；
        // 用 outputVolume=0 静音则有被优化掉、导致输入侧不跑的风险。
        engine.mainMixerNode.outputVolume = 1.0
        currentMode = mode
        log.record("音频图", "source → mainMixer（完整链路），输出 \(mode == .monitor ? "外放" : "静音")")

        // ---- 8) 引擎 ----
        engine.prepare()
        do {
            try engine.start()
        } catch {
            log.failure("引擎 start()", "\(error.localizedDescription)")
            throw EngineStartupError.engineStartFailed(error.localizedDescription)
        }
        log.record("引擎", "已启动，外放 \(mode == .monitor ? "开" : "静音")")

        processingStartedAt = Date()
        didReportAudioFlow = false
        inputCallbackCount = 0
        startProcessingTimer()
    }

    /// 回退状态（供 UI 提示）
    private(set) var hardwareVoiceProcessingFallback = false
    private var hardwareFallbackReason = ""

    /// 拆除音频图与 tap，供重试前清理
    private func teardown() {
        processingTimer?.cancel()
        processingTimer = nil

        if tapInstalled {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if let node = sourceNode { engine.detach(node) }
        sourceNode = nil
        if engine.isRunning { engine.stop() }
        engine.reset()

        // 复位硬件语音处理开关，否则重试时会带着上一次的半初始化状态
        if isHardwareVoiceProcessingEnabled {
            try? inputNode.setVoiceProcessingEnabled(false)
            isHardwareVoiceProcessingEnabled = false
        }
    }

    /// 停止引擎
    func stop() {
        guard isRunning else { return }
        isRunning = false
        teardown()
        hardwareVoiceProcessingFallback = false
        // AVAudioFile.close() 需要 iOS 18+；置空后由 deinit 负责关闭
        audioFile = nil
        AudioSessionConfigurator.deactivate()
        setState(.idle)
    }

    /// 重新学习当前环境噪声
    func relearnNoise() {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            self.denoiser.reset()
            self.updateStats { $0.noiseLearnCount += 1 }
            DispatchQueue.main.async {
                self.setState(.learningNoise)
            }
        }
    }

    /// 动态调整降噪强度（0...1）。
    ///
    /// 只改增益参数，**不重建降噪器**：滑块是连续拖动的，
    /// 每动一下就重置噪声学习会让人声在拖动期间忽隐忽现。
    func setStrength(_ strength: Float) {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            let s = min(max(strength, 0), 1)
            // 强度越高：谱底越高（保留越多语音），过子因子越低（噪声压得越狠）
            let floor = 0.04 + 0.25 * s
            let oversubtraction = 2.4 - 1.4 * s
            self.denoiserConfig.spectralFloor = floor
            self.denoiserConfig.oversubtraction = oversubtraction
            self.denoiser.setStrength(spectralFloor: floor, oversubtraction: oversubtraction)
        }
    }

    // MARK: - 硬件语音处理

    /// 启用/禁用 Apple 的语音处理单元（voice processing unit）。
    ///
    /// 这个单元由系统提供，做三件事：
    /// - **AEC**（回声消除）：消除扬声器外放被麦克风拾取的回声
    /// - **AGC**（自动增益控制）：把音量拉到稳定水平
    /// - **硬件降噪**：抑制稳态背景噪声
    ///
    /// 跑在硬件/DSP 上，CPU 占用几乎为零，效果也远好于纯软件算法。
    /// 但**必须**在 `installTap` 之前调用，且音频会话要用 `.voiceChat` 模式，
    /// 否则系统不会走这条链路。
    private func enableHardwareVoiceProcessing() {
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            isHardwareVoiceProcessingEnabled = true
        } catch {
            // 真机不支持时（如部分 iPad / 模拟器）静默降级到纯软件降噪
            isHardwareVoiceProcessingEnabled = false
        }
    }

    /// 是否成功启用了硬件语音处理
    private(set) var isHardwareVoiceProcessingEnabled = false

    // MARK: - 采集回调

    private func handleInput(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?.pointee else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        // 诊断计数：用来区分「tap 完全没被驱动」和「有回调但处理没跑起来」
        inputCallbackCount += 1
        inputBuffer.write(channelData, count: count)
    }

    // MARK: - 处理定时器

    private func startProcessingTimer() {
        let hop = denoiserConfig.hopSize
        let sampleRate = format.sampleRate
        // 每 hop 个样本处理一次 → 周期 = hop / sampleRate 秒
        let interval = Double(hop) / sampleRate
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.processAvailableAudio()
        }
        timer.resume()
        processingTimer = timer
    }

    private func processAvailableAudio() {
        reportAudioFlowIfNeeded()
        let hop = denoiserConfig.hopSize

        while inputBuffer.availableToRead >= hop {
            let read = inputBuffer.read(into: &workBuffer, count: hop)
            if read < hop { break }

            // 降噪
            let output = denoiser.process(workBuffer)
            processedBuffer = output

            // 只有监听模式才把处理后的音频送进输出缓冲（其余模式静音）
            if currentMode == .monitor {
                outputBuffer.write(processedBuffer)
            }

            // 录音模式：写文件
            if audioFile != nil {
                writeToFile(processedBuffer)
            }

            // 回调
            onProcessedAudio?(makePCMBuffer(from: processedBuffer))


            let snapshot = self.denoiser.noiseProfileSnapshot()
            self.profileLock.lock()
            self._noiseProfileSnapshot = snapshot
            self.profileLock.unlock()

            updateStats { stats in
                stats.processedFrames += 1
                stats.inputLevel = AudioMath.rms(workBuffer[0..<hop])
                stats.outputLevel = AudioMath.rms(processedBuffer[0..<hop])
                stats.snrDb = self.denoiser.lastSNRDb
                stats.voiceProbability = self.denoiser.lastVoiceProbability
                stats.isLearning = self.denoiser.isLearningNoise
                stats.droppedSamples = max(0, self.inputBuffer.availableToRead - hop)
            }

            // 刷新噪声剖面快照（供 UI 展示）
        }

        if !denoiser.isLearningNoise && state == .learningNoise {
            setState(.running)
        }
    }

    /// 把「音频到底有没有在流」这件事记进**用户看得见的日志**。
    ///
    /// 必要性：引擎启动成功却收不到音频时，界面表现和"启动失败"一模一样——
    /// 都是点了没反应。只有把结论写进诊断日志，用户截图才能定位。
    private func reportAudioFlowIfNeeded() {
        guard !didReportAudioFlow else { return }

        if denoiser.processedFrames > 0 {
            didReportAudioFlow = true
            log.record("音频流", "已处理首帧（采集回调 \(inputCallbackCount) 次）")
            return
        }

        guard let started = processingStartedAt,
              Date().timeIntervalSince(started) > 2 else { return }
        didReportAudioFlow = true
        if inputCallbackCount == 0 {
            log.failure("音频流", "2 秒内采集 tap 一次都没触发（回调 0 次）——麦克风没有被拉流")
        } else {
            log.failure("音频流", "采集回调 \(inputCallbackCount) 次，但始终凑不满一帧")
        }
    }

    // MARK: - 监控链

    /// 建立输出链路：`AVAudioSourceNode`（从输出环形缓冲取数据）→ 主混音器 → 输出。
    ///
    /// 两种模式都建这条链路，区别只在 `mainMixerNode.outputVolume`：
    /// - 监听模式 = 1，实时外放降噪后的声音
    /// - 静音模式 = 0，不外放（避免和其他 App 的麦克风形成回授）
    ///
    /// 必须建图的原因：只挂 tap、不连输出，`AVAudioEngine` 缺少渲染驱动，
    /// `start()` 会抛错或 tap 永不触发——这正是「点开始没反应」的一个典型成因。
    ///
    /// 注意：`AVAudioPlayerNode` 是**源节点**（没有输入端），
    /// 不能把 source node 接到 player node 上；直接连 `mainMixerNode` 才对。
    private func setupOutputChain() {
        if sourceNode != nil { return }
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let first = ablPointer.first else { return noErr }

            let capacity = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let count = min(Int(frameCount), capacity)
            if count <= 0 { return noErr }

            let samples = first.mData!.assumingMemoryBound(to: Float.self)
            let read = self.outputBuffer.read(into: samples, count: count)
            if read < count {
                // 欠载：补零。宁可出现极短的静音，也不能阻塞渲染线程。
                for i in read..<count { samples[i] = 0 }
            }
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    // MARK: - 录音

    /// 开始写入音频文件（降噪后的数据）
    func startRecording(to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        audioFile = file
        recordingURL = url
    }

    func stopRecording() -> URL? {
        audioFile = nil
        return recordingURL
    }

    private func writeToFile(_ samples: [Float]) {
        // 注意：format 是非可选属性，不能写成 guard let format = format
        guard let file = audioFile else { return }
        let frameCount = AVAudioFrameCount(samples.count)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcm.frameLength = frameCount
        guard let dst = pcm.floatChannelData?.pointee else { return }
        dst.update(from: samples, count: samples.count)
        try? file.write(from: pcm)
    }

    private func makePCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(samples.count)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        pcm.frameLength = frameCount
        if let dst = pcm.floatChannelData?.pointee {
            dst.update(from: samples, count: samples.count)
        }
        return pcm
    }

    // MARK: - 统计

    private func updateStats(_ mutate: (inout EngineStats) -> Void) {
        statsLock.lock()
        mutate(&_stats)
        statsLock.unlock()
    }
}

/// 引擎运行时统计
struct EngineStats {
    var processedFrames: Int = 0
    var inputLevel: Float = 0
    var outputLevel: Float = 0
    var snrDb: Float = 0
    var voiceProbability: Float = 0
    var isLearning: Bool = true
    var droppedSamples: Int = 0
    var noiseLearnCount: Int = 0

    /// 降噪率：输入能量 / 输出能量（dB），正值代表衰减了多少
    var attenuationDb: Float {
        guard inputLevel > 1e-6, outputLevel > 1e-6 else { return 0 }
        return 20 * log10(inputLevel / outputLevel)
    }
}
