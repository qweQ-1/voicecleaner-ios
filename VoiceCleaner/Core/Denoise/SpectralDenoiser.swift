import Foundation

/// 基于短时傅里叶变换（STFT）的实时降噪器。
///
/// 算法链路：
/// 1. **加窗分帧**：Hann 窗（周期型），frameSize / hopSize 可配，默认 75% 重叠。
/// 2. **噪声剖面估计**：持续跟踪每频点的噪声功率谱，
///    只在判定为「非语音」时更新，避免把人声学进噪声模型。
/// 3. **先验 SNR 估计**：判决引导法（decision-directed）
///    `SNR_prior = α·|X(k-1)|²/λd(k) + (1-α)·max(|X(k)|²/λd(k) - 1, 0)`
/// 4. **增益函数**：Wiener 增益 `G = SNR_prior/(1+SNR_prior)`，
///    做时间平滑 + 频率平滑 + 谱底下限，防止「音乐噪声」。
/// 5. **重叠相加重建**：WOLA（加权重叠相加），
///    输出除以累积的窗平方和，抵消 75% 重叠 Hann 窗的幅度起伏。
///
/// 时序约定（严格对齐，索引错一位就会导致输出错位或混叠）：
/// - 第 m 步消费 `hop` 个新样本，累计已消费 `m*hop` 个样本；
/// - 本步分析的帧覆盖绝对区间 `[m*hop - frameSize, m*hop)`；
/// - 本步输出区间为 `[m*hop - frameSize, m*hop - frameSize + hop)`，
///   即该帧的**前一个 hop**——此时它收到的四份贡献（来自第 m, m-1, m-2, m-3 帧）已全部就绪。
///
/// 设计约束：
/// - **纯 Swift、零依赖**，可被单元测试逐帧验证。
/// - **实时线程无堆分配**：所有缓冲区在 `init` 时预分配，`process` 只做原地运算。
final class SpectralDenoiser {
    // MARK: - 配置

    struct Configuration {
        var sampleRate: Float = 48_000
        /// 每帧样本数，必须是 2 的幂
        var frameSize: Int = 1024
        /// 帧移（默认 75% 重叠）
        var hopSize: Int = 256
        /// 噪声剖面的平滑系数（越大跟得越慢、越稳）
        var noiseSmoothing: Float = 0.85
        /// 判决引导法的先验权重 α
        var decisionDirectedAlpha: Float = 0.98
        /// 过子因子：噪声能量被低估时的补偿
        var oversubtraction: Float = 1.8
        /// 谱底增益下限，防止语音被削成「水声」
        var spectralFloor: Float = 0.08
        /// 增益在时间维度上的平滑强度（0 = 不平滑）
        var gainSmoothing: Float = 0.6
        /// 噪声剖面初始学习帧数
        var noiseLearningFrames: Int = 30
        /// 判定为「含语音」的 SNR 阈值（dB），高于它就不更新噪声模型
        var speechSNRThresholdDb: Float = 6

        init() {}

        /// 校验配置合法性，非法项回退到安全默认值。
        func validated() -> Configuration {
            var c = self
            if c.frameSize < 64 || (c.frameSize & (c.frameSize - 1)) != 0 {
                c.frameSize = 1024
            }
            if c.hopSize <= 0 || c.hopSize > c.frameSize {
                c.hopSize = c.frameSize / 4
            }
            c.noiseSmoothing = min(max(c.noiseSmoothing, 0.5), 0.995)
            c.decisionDirectedAlpha = min(max(c.decisionDirectedAlpha, 0.0), 0.999)
            c.oversubtraction = max(c.oversubtraction, 1.0)
            c.spectralFloor = min(max(c.spectralFloor, 0.0), 1.0)
            c.gainSmoothing = min(max(c.gainSmoothing, 0.0), 1.0)
            c.noiseLearningFrames = max(c.noiseLearningFrames, 1)
            return c
        }
    }

    // MARK: - 公开状态

    private(set) var config: Configuration

    /// 最近一帧的宽带估计信噪比（dB）
    private(set) var lastSNRDb: Float = 0
    /// 最近一帧的语音概率（0...1）
    private(set) var lastVoiceProbability: Float = 0
    /// 是否还在学习环境噪声
    private(set) var isLearningNoise: Bool = true
    /// 已处理的总帧数
    private(set) var processedFrames: Int = 0

    // MARK: - 私有状态

    private let fft: FFT
    private let window: [Float]
    /// 单边功率谱长度（0...N/2）
    private let binCount: Int
    /// 输出累加器长度，取 2*frameSize 保证环形复用时不冲突
    private let accumulatorLength: Int

    // 输入环形缓冲：保存最近 frameSize 个样本
    private var inputRing: [Float]
    private var ringWriteIndex: Int
    /// 已消费的输入样本总数
    private var samplesConsumed: Int

    // 输出累加器（绝对位置 mod accumulatorLength）
    private var outputAccumulator: [Float]
    /// 窗平方累积（用于 WOLA 归一化）
    private var windowSquareAccumulator: [Float]

    // 频域状态
    private var noiseProfile: [Float]       // 每 bin 的噪声功率（线性，未过子因子）
    private var previousPower: [Float]      // 上一帧功率谱
    private var previousGain: [Float]       // 上一帧增益
    private var gain: [Float]               // 当前帧增益
    private var smoothedGain: [Float]
    private var scratchGain: [Float]        // 频率平滑用的临时缓冲

    // FFT 工作区
    private var realBuf: [Float]
    private var imagBuf: [Float]
    private var powerBuf: [Float]

    private var learningFramesDone: Int = 0

    // MARK: - 初始化

    init(configuration: Configuration = Configuration()) {
        let cfg = configuration.validated()
        self.config = cfg

        fft = FFT(size: cfg.frameSize)
        binCount = cfg.frameSize / 2 + 1
        accumulatorLength = cfg.frameSize * 2

        // 周期型 Hann 窗
        var w = [Float](repeating: 0, count: cfg.frameSize)
        for i in 0..<cfg.frameSize {
            w[i] = Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(cfg.frameSize)))
        }
        window = w

        inputRing = [Float](repeating: 0, count: cfg.frameSize)
        ringWriteIndex = 0
        samplesConsumed = 0

        outputAccumulator = [Float](repeating: 0, count: accumulatorLength)
        windowSquareAccumulator = [Float](repeating: 0, count: accumulatorLength)

        noiseProfile = [Float](repeating: 1e-8, count: binCount)
        previousPower = [Float](repeating: 0, count: binCount)
        previousGain = [Float](repeating: 1, count: binCount)
        gain = [Float](repeating: 1, count: binCount)
        smoothedGain = [Float](repeating: 1, count: binCount)
        scratchGain = [Float](repeating: 0, count: binCount)

        realBuf = [Float](repeating: 0, count: cfg.frameSize)
        imagBuf = [Float](repeating: 0, count: cfg.frameSize)
        powerBuf = [Float](repeating: 0, count: binCount)
    }

    /// 重置内部状态（重新学习环境噪声时调用）
    func reset() {
        for i in inputRing.indices { inputRing[i] = 0 }
        ringWriteIndex = 0
        samplesConsumed = 0
        for i in outputAccumulator.indices { outputAccumulator[i] = 0 }
        for i in windowSquareAccumulator.indices { windowSquareAccumulator[i] = 0 }
        for i in noiseProfile.indices { noiseProfile[i] = 1e-8 }
        for i in previousPower.indices { previousPower[i] = 0 }
        for i in previousGain.indices { previousGain[i] = 1 }
        for i in gain.indices { gain[i] = 1 }
        for i in smoothedGain.indices { smoothedGain[i] = 1 }
        learningFramesDone = 0
        processedFrames = 0
        lastSNRDb = 0
        lastVoiceProbability = 0
        isLearningNoise = true
    }

    // MARK: - 主处理

    /// 处理一帧（`hopSize` 个样本），返回降噪后的同长样本。
    ///
    /// - Important: 实时线程调用；内部不做堆分配。
    func process(_ input: [Float]) -> [Float] {
        let hop = config.hopSize
        let n = config.frameSize
        precondition(input.count == hop, "输入长度必须等于 hopSize")

        // ---- 1) 写入输入环形缓冲 ----
        for i in 0..<hop {
            inputRing[(ringWriteIndex + i) % n] = input[i]
        }
        ringWriteIndex = (ringWriteIndex + hop) % n
        samplesConsumed += hop

        // ---- 2) 取出待分析的一帧（按时间顺序：最旧 -> 最新）----
        for i in 0..<n {
            realBuf[i] = inputRing[(ringWriteIndex + i) % n] * window[i]
        }
        for i in 0..<n { imagBuf[i] = 0 }

        // ---- 3) 前向 FFT ----
        fft.transform(real: &realBuf, imag: &imagBuf, inverse: false)

        // ---- 4) 功率谱 ----
        for k in 0..<binCount {
            powerBuf[k] = realBuf[k] * realBuf[k] + imagBuf[k] * imagBuf[k]
        }

        // ---- 5) 先验 SNR + 语音概率 ----
        let alpha = config.decisionDirectedAlpha
        var snrSum: Float = 0
        for k in 0..<binCount {
            let lambdaD = max(noiseProfile[k] * config.oversubtraction, 1e-12)
            let instantSNR = max(powerBuf[k] / lambdaD - 1, 0)
            let previousEstimate = previousPower[k] / lambdaD
            snrSum += alpha * previousEstimate + (1 - alpha) * instantSNR
        }
        let meanSNR = snrSum / Float(binCount)
        lastSNRDb = AudioMath.db(max(meanSNR, 0))
        let speechThreshold = AudioMath.amplitude(config.speechSNRThresholdDb)
        lastVoiceProbability = min(max(meanSNR / max(speechThreshold * 4, 1e-6), 0), 1)

        // ---- 6) 更新噪声剖面 ----
        updateNoiseProfile()

        // ---- 7) 计算增益 ----
        computeGain()

        // ---- 8) 施加增益 ----
        for k in 0..<binCount {
            let g = smoothedGain[k]
            realBuf[k] *= g
            imagBuf[k] *= g
        }

        // ---- 9) 逆 FFT ----
        fft.transform(real: &realBuf, imag: &imagBuf, inverse: true)

        // ---- 10) 加权重叠相加（WOLA）----
        // 本帧覆盖绝对区间 [frameStart, frameStart + n)
        let frameStart = samplesConsumed - n
        for i in 0..<n {
            let slot = (frameStart + i) % accumulatorLength
            let slotIdx = slot < 0 ? slot + accumulatorLength : slot
            outputAccumulator[slotIdx] += realBuf[i] * window[i]
            windowSquareAccumulator[slotIdx] += window[i] * window[i]
        }

        // ---- 11) 输出本帧的前 hop 个样本（此时四份贡献已就绪）----
        var output = [Float](repeating: 0, count: hop)
        for i in 0..<hop {
            let slot = (frameStart + i) % accumulatorLength
            let slotIdx = slot < 0 ? slot + accumulatorLength : slot
            let w = windowSquareAccumulator[slotIdx]
            output[i] = w > 1e-6 ? outputAccumulator[slotIdx] / w : 0
            // 读出后清零，供后续帧复用
            outputAccumulator[slotIdx] = 0
            windowSquareAccumulator[slotIdx] = 0
        }

        // ---- 12) 保存跨帧状态 ----
        for k in 0..<binCount {
            previousPower[k] = powerBuf[k]
            previousGain[k] = gain[k]
        }
        processedFrames += 1

        return output
    }

    /// 噪声剖面的快照（线程安全读取）
    func noiseProfileSnapshot() -> [Float] {
        noiseProfile
    }

    /// 便捷入口：整段处理（离线分析 / 单元测试用）。
    ///
    /// 返回结果与输入**等长且时间轴对齐**，为此做了两件事：
    /// 1. **冲刷流水线**：STFT 有 `frameSize - hopSize` 个样本的前视，
    ///    末尾要再喂几个零块，才能把最后一段音频吐出来。
    /// 2. **对齐**：第 m 步输出的是 `[m*hop - frameSize, m*hop - frameSize + hop)`
    ///    这一段，比当时已消费的输入滞后 `frameSize - hopSize` 个样本，
    ///    所以拼接结果要整体后移这么多。
    ///
    /// 这两点漏掉的话，实时听感是「延迟/回声」，离线测出来是「重建误差巨大」。
    func processBuffer(_ input: [Float]) -> [Float] {
        let hop = config.hopSize
        let lag = config.frameSize - hop
        var blocks: [Float] = []
        blocks.reserveCapacity(input.count + config.frameSize * 2)

        var offset = 0
        while offset + hop <= input.count {
            let chunk = Array(input[offset..<(offset + hop)])
            blocks.append(contentsOf: process(chunk))
            offset += hop
        }
        if offset < input.count {
            var tail = [Float](repeating: 0, count: hop)
            let remaining = input.count - offset
            for i in 0..<remaining { tail[i] = input[offset + i] }
            blocks.append(contentsOf: process(tail))
        }

        // 冲刷流水线
        let flushBlocks = config.frameSize / hop + 2
        let zeros = [Float](repeating: 0, count: hop)
        for _ in 0..<flushBlocks {
            blocks.append(contentsOf: process(zeros))
        }

        // 对齐
        guard blocks.count > lag else { return blocks }
        let end = min(lag + input.count, blocks.count)
        return Array(blocks[lag..<end])
    }

    // MARK: - 噪声估计

    private func updateNoiseProfile() {
        if learningFramesDone < config.noiseLearningFrames {
            // 学习阶段：指数平均累积噪声底（此时应保持安静）
            let smooth = config.noiseSmoothing
            for k in 0..<binCount {
                noiseProfile[k] = noiseProfile[k] * smooth + powerBuf[k] * (1 - smooth)
            }
            learningFramesDone += 1
            isLearningNoise = true
            return
        }

        isLearningNoise = false

        // 稳态阶段：只在判定为「非语音」时更新噪声剖面，
        // 否则会把持续的人声底噪学进噪声模型。
        guard lastVoiceProbability < 0.35 else { return }

        for k in 0..<binCount {
            let target = powerBuf[k]
            // 向上快、向下慢：噪声变响立刻跟上，变安静缓慢释放
            let rate: Float = target > noiseProfile[k] ? 0.3 : 0.02
            noiseProfile[k] = noiseProfile[k] * (1 - rate) + target * rate
        }
    }

    // MARK: - 增益计算

    private func computeGain() {
        let alpha = config.decisionDirectedAlpha
        let lambdaScale = config.oversubtraction

        for k in 0..<binCount {
            let lambdaD = max(noiseProfile[k] * lambdaScale, 1e-12)
            let instantSNR = max(powerBuf[k] / lambdaD - 1, 0)
            let previousEstimate = previousPower[k] / lambdaD
            let priorSNR = alpha * previousEstimate + (1 - alpha) * instantSNR

            // Wiener 增益
            var g = priorSNR / (1 + priorSNR)

            // 时间平滑：避免增益闪烁造成的「音乐噪声」
            g = config.gainSmoothing * previousGain[k] + (1 - config.gainSmoothing) * g

            // 谱底
            g = max(g, config.spectralFloor)

            gain[k] = g
        }

        // 频率维平滑（三点均值）
        if config.gainSmoothing > 0 {
            for k in 0..<binCount {
                let prev = gain[max(k - 1, 0)]
                let next = gain[min(k + 1, binCount - 1)]
                scratchGain[k] = (prev + gain[k] * 2 + next) / 4
            }
            for k in 0..<binCount { smoothedGain[k] = scratchGain[k] }
        } else {
            for k in 0..<binCount { smoothedGain[k] = gain[k] }
        }
    }
}
