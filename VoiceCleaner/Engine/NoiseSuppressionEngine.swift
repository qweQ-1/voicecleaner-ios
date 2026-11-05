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
        /// 只处理不外放（避免回授），用于「给其他 App 用」的配合模式
        case silent
        /// 实时外放处理后的声音（用于试听效果）
        case monitor
        /// 处理后的声音写入文件
        case record

        var displayName: String {
            switch self {
            case .silent: return "静音（供其他 App 使用）"
            case .monitor: return "实时监听"
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

    // MARK: - 录制

    private var audioFile: AVAudioFile?
    private var recordingURL: URL?

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
    /// - Parameter mode: 输出模式
    /// - Parameter useHardwareVoiceProcessing: 是否启用 Apple 硬件语音处理单元
    func start(mode: OutputMode, useHardwareVoiceProcessing: Bool = true) throws {
        guard !isRunning else { return }

        // 1) 配置音频会话
        //    硬件 VP 单元只在 .voiceChat 模式下生效
        try AudioSessionConfigurator.configure(voiceChatMode: useHardwareVoiceProcessing)

        // 2) 确定实际输入格式
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            setState(.failed("麦克风不可用"))
            throw NSError(domain: "VoiceCleaner", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "麦克风不可用，请检查权限"])
        }
        format = inputFormat

        // 3) 启用 Apple 硬件语音处理单元（AEC + AGC + 硬件降噪）
        //    必须在 installTap 之前调用，否则不生效。
        //    这是效果好坏的最大变量：硬件 DSP 的效果远好于纯软件算法，
        //    而且几乎不占 CPU。我们把它的输出再喂给自研 STFT 降噪做二次处理。
        if useHardwareVoiceProcessing {
            enableHardwareVoiceProcessing()
        }

        // 4) 重新配置降噪器以匹配实际采样率
        var cfg = denoiserConfig
        cfg.sampleRate = Float(inputFormat.sampleRate)
        denoiserConfig = cfg.validated()
        denoiser = SpectralDenoiser(configuration: denoiserConfig)
        workBuffer = [Float](repeating: 0, count: denoiserConfig.hopSize)
        processedBuffer = [Float](repeating: 0, count: denoiserConfig.hopSize)

        // 4) 安装采集 tap
        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(denoiserConfig.hopSize * 4), format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.handleInput(buffer)
        }

        // 5) 构建播放链（monitor 模式需要）
        if mode == .monitor {
            setupMonitorChain()
        }

        // 6) 启动引擎
        engine.prepare()
        try engine.start()

        // 7) 启动处理定时器
        startProcessingTimer()

        isRunning = true
        setState(.learningNoise)
    }

    /// 停止引擎
    func stop() {
        guard isRunning else { return }
        isRunning = false

        processingTimer?.cancel()
        processingTimer = nil

        inputNode.removeTap(onBus: 0)

        if let node = sourceNode { engine.detach(node) }
        sourceNode = nil

        engine.stop()
        engine.reset()

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
        let hop = denoiserConfig.hopSize

        while inputBuffer.availableToRead >= hop {
            let read = inputBuffer.read(into: &workBuffer, count: hop)
            if read < hop { break }

            // 降噪
            let output = denoiser.process(workBuffer)
            processedBuffer = output

            // 送入输出环形缓冲
            outputBuffer.write(processedBuffer)

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

    // MARK: - 监控链

    /// 建立外放链路：`AVAudioSourceNode`（从输出环形缓冲取数据）→ 主混音器 → 输出。
    ///
    /// 注意：`AVAudioPlayerNode` 是**源节点**（没有输入端），
    /// 不能把 source node 接到 player node 上；直接连 `mainMixerNode` 才对。
    /// 混音器和输出节点会以实时线程驱动 source node 的渲染回调。
    private func setupMonitorChain() {
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
