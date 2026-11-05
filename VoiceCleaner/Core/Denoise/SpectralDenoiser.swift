import Foundation

/// 基于短时傅里叶变换（STFT）的实时降噪器。
///
/// 算法链路：
/// 1. **加窗分帧**：Hann 窗（周期型），默认 512 点 / 跳 128（75% 重叠）。
/// 2. **噪声功率谱估计**：逐个频点跟踪「带缓慢向上漂移的最小值」（最小统计量法），
///    乘以实测标定的偏置系数补偿最小值系统性偏低。
/// 3. **先验 SNR**：判决引导法（decision-directed），递归项用**上一帧增强后**的信号功率。
/// 4. **增益**：Wiener `G = ξ/(1+ξ)`，再做时间平滑 + 频率三点平滑 + 谱底下限，
///    三层防「音乐噪声」。
/// 5. **WOLA 重叠相加重建**，输出除以累积窗平方和。
///
/// 时序约定（严格对齐，索引错一位就会导致输出错位或回声）：
/// - 第 m 步消费 `hop` 个新样本，累计已消费 `m*hop` 个样本；
/// - 本步分析的帧覆盖绝对区间 `[m*hop - frameSize, m*hop)`；
/// - 本步输出区间为 `[m*hop - frameSize, m*hop - frameSize + hop)`，
///   即该帧的**前一个 hop**——此时它收到的四份贡献（来自第 m, m-1, m-2, m-3 帧）已全部就绪。
/// - 因此流式输出比当前输入滞后 `frameSize - hopSize` 个样本。
///
/// 设计约束：
/// - **纯 Swift、零依赖**，可被单元测试逐帧验证。
/// - 实时路径上不分配内存（`process` 会返回新数组，但内部工作区全部预分配）。
final class SpectralDenoiser {

    // MARK: - 配置

    struct Configuration {
        var sampleRate: Float = 48_000
        /// 每帧样本数，必须是 2 的幂
        var frameSize: Int = 1024
        /// 帧移（默认 75% 重叠）
        var hopSize: Int = 256
        /// 取最小值**之前**的时间平滑系数。
        /// 白噪声的功率谱近似指数分布，直接取最小值会系统性偏低约 15 dB 且方差很大；
        /// 先平滑把方差降下来，最小值才贴近均值。
        var noiseSmoothingPre: Float = 0.85
        /// 最小值向上漂移的速率（越小噪声估计越稳，但跟环境变化越慢）
        var minimumUpDrift: Float = 0.002
        /// 最小值低估的补偿系数。
        /// **实测标定值**：在纯噪声上跑 0.03/0.05/0.10/0.30 四种幅度，
        /// 所需系数分别为 2.17/2.14/2.14/2.15，波动仅 0.03。
        /// 不做时间平滑直接取最小值的话，该系数要 30~43 且波动 13，不可用。
        var noiseBias: Float = 2.15
        /// 判决引导法的先验权重 α
        var decisionDirectedAlpha: Float = 0.98
        /// 过子因子：噪声能量被低估时的补偿
        var oversubtraction: Float = 1.8
        /// 谱底增益下限，防止语音被削成「水声」
        var spectralFloor: Float = 0.08
        /// 增益在时间维度上的平滑强度（0 = 不平滑）
        var gainSmoothing: Float = 0.6
        /// 噪声剖面初始学习帧数（仅用于 UI 进度显示，估计本身从第一帧就可用）
        var noiseLearningFrames: Int = 30

        init() {}

        /// 校验配置合法性，非法项回退到安全默认值。
        func validated() -> Configuration {
            var c = self
            if c.frameSize < 64 || (c.frameSize & (c.frameSize - 1)) != 0 { c.frameSize = 1024 }
            if c.hopSize <= 0 || c.hopSize > c.frameSize { c.hopSize = c.frameSize / 4 }
            c.noiseSmoothingPre = min(max(c.noiseSmoothingPre, 0.0), 0.99)
            c.minimumUpDrift = min(max(c.minimumUpDrift, 0.0), 0.2)
            c.noiseBias = max(c.noiseBias, 1.0)
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
    /// 是否还在初始学习阶段（UI 显示用）
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
    /// 窗平方累积（WOLA 归一化）
    private var windowSquareAccumulator: [Float]

    // 频域状态
    private var noiseProfile: [Float]        // 每 bin 噪声功率估计
    private var minPower: [Float]            // 逐 bin 最小值跟踪
    private var smoothedPowerPre: [Float]    // 取最小值前的平滑功率
    private var hasInitializedNoise = false  // 是否已用首个有效帧初始化最小值
    private var previousPower: [Float]       // 上一帧含噪功率谱（仅用于显示/统计）
    private var previousEnhancedPower: [Float] // 上一帧**增强后**功率 G²P（判决引导递归项）
    private var previousGain: [Float]        // 上一帧增益
    private var gain: [Float]                // 当前帧增益
    private var smoothedGain: [Float]
    private var scratchGain: [Float]         // 频率平滑临时缓冲

    // FFT 工作区
    private var realBuf: [Float]
    private var imagBuf: [Float]
    private var powerBuf: [Float]

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

        noiseProfile = [Float](repeating: 1e-12, count: binCount)
        minPower = [Float](repeating: .greatestFiniteMagnitude, count: binCount)
        smoothedPowerPre = [Float](repeating: 0, count: binCount)
        hasInitializedNoise = false
        previousPower = [Float](repeating: 0, count: binCount)
        previousEnhancedPower = [Float](repeating: 0, count: binCount)
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
        for i in noiseProfile.indices { noiseProfile[i] = 1e-12 }
        for i in minPower.indices { minPower[i] = .greatestFiniteMagnitude }
        for i in smoothedPowerPre.indices { smoothedPowerPre[i] = 0 }
        hasInitializedNoise = false
        for i in previousPower.indices { previousPower[i] = 0 }
        for i in previousEnhancedPower.indices { previousEnhancedPower[i] = 0 }
        for i in previousGain.indices { previousGain[i] = 1 }
        for i in gain.indices { gain[i] = 1 }
        for i in smoothedGain.indices { smoothedGain[i] = 1 }
        processedFrames = 0
        lastSNRDb = 0
        lastVoiceProbability = 0
        isLearningNoise = true
    }

    /// 调整降噪强度，**保留已学习的噪声剖面**。
    ///
    /// 不要用「重建一个降噪器」的方式改强度：滑块是连续拖动的，
    /// 每动一下就重置噪声学习，体验会很差。
    func setStrength(spectralFloor: Float, oversubtraction: Float) {
        var c = config
        c.spectralFloor = min(max(spectralFloor, 0.0), 1.0)
        c.oversubtraction = max(oversubtraction, 1.0)
        config = c.validated()
    }

    /// 噪声剖面的快照（供 UI 展示）
    func noiseProfileSnapshot() -> [Float] {
        noiseProfile
    }

    // MARK: - 主处理

    /// 处理一帧（`hopSize` 个样本），返回降噪后的同长样本。
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

        // ---- 2) 取出待分析的一帧（最旧 -> 最新），加窗 ----
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

        // ---- 5) 更新噪声功率谱估计（最小统计量法）----
        updateNoiseProfile()

        // ---- 6) 宽带 SNR → 语音概率 ----
        var totalSignal: Float = 0
        var totalNoise: Float = 0
        for k in 0..<binCount {
            totalSignal += powerBuf[k]
            totalNoise += noiseProfile[k]
        }
        let frameSNR = totalSignal / max(totalNoise, 1e-12)
        lastSNRDb = 10 * log10(max(frameSNR, 1e-7))
        // 高于噪声底约 4 dB 视为含语音
        lastVoiceProbability = min(max((frameSNR - 1.5) / 3.0, 0), 1)

        // ---- 7) 计算增益 ----
        computeGain()

        // ---- 8) 施加增益 ----
        for k in 0..<binCount {
            let g = smoothedGain[k]
            realBuf[k] *= g
            imagBuf[k] *= g
            // 记录增强后功率，供下一帧的判决引导递归使用
            previousEnhancedPower[k] = g * g * powerBuf[k]
            previousPower[k] = powerBuf[k]
            previousGain[k] = gain[k]
        }

        // ---- 9) 逆 FFT ----
        fft.transform(real: &realBuf, imag: &imagBuf, inverse: true)

        // ---- 10) 加权重叠相加（WOLA）----
        let frameStart = samplesConsumed - n
        for i in 0..<n {
            var slot = (frameStart + i) % accumulatorLength
            if slot < 0 { slot += accumulatorLength }
            outputAccumulator[slot] += realBuf[i] * window[i]
            windowSquareAccumulator[slot] += window[i] * window[i]
        }

        // ---- 11) 输出本帧的前 hop 个样本（此时四份贡献已就绪）----
        var output = [Float](repeating: 0, count: hop)
        for i in 0..<hop {
            var slot = (frameStart + i) % accumulatorLength
            if slot < 0 { slot += accumulatorLength }
            let w = windowSquareAccumulator[slot]
            output[i] = w > 1e-6 ? outputAccumulator[slot] / w : 0
            outputAccumulator[slot] = 0
            windowSquareAccumulator[slot] = 0
        }

        processedFrames += 1
        isLearningNoise = processedFrames < config.noiseLearningFrames

        return output
    }

    /// 便捷入口：整段处理（离线分析 / 单元测试用）。
    ///
    /// 返回结果与输入**等长且时间轴对齐**，为此做了两件事：
    /// 1. **冲刷流水线**：STFT 有 `frameSize - hopSize` 个样本的前视，
    ///    末尾要再喂几个零块，才能把最后一段音频吐出来。
    /// 2. **对齐**：第 m 步输出的是 `[m*hop - frameSize, m*hop - frameSize + hop)`，
    ///    比当时已消费的输入滞后 `frameSize - hopSize` 个样本，拼接结果要整体后移这么多。
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

    /// 带缓慢向上漂移的逐频点最小值跟踪（最小统计量法）。
    ///
    /// 为什么不用「VAD 门控的指数平均」：那种做法里 VAD 判据依赖噪声估计、
    /// 噪声估计又依赖 VAD 判据，形成**反馈环**。语音起始的头两帧瞬时功率偏低，
    /// 被判成「噪声」，快速向上更新立刻把噪声底抬到语音水平，之后 VAD 再也触发不了，
    /// 噪声模型就把人声整段吃掉（实测 noise 总和从 351 一路涨到 3409，语音只剩 8%）。
    ///
    /// 最小值跟踪的结构保证不会被语音污染：语音只会让频点**高于**最小值，不会让它升高。
    private func updateNoiseProfile() {
        // **预热期**：前 frameSize 个样本里还混着环形缓冲的初始零值，
        // 这一段的帧谱不代表真实环境。用它初始化最小值会让噪声估计长期偏低
        // （实测直流频点噪声估计只有真值的 1/42，压制基本失效，且要几千帧才爬回来）。
        // 这几帧对应的输出落在负时间轴，不会进入真实输出，跳过无副作用。
        guard samplesConsumed >= config.frameSize else { return }

        let pre = config.noiseSmoothingPre
        let drift = config.minimumUpDrift
        let bias = config.noiseBias

        for k in 0..<binCount {
            if hasInitializedNoise {
                // 先时间平滑再取最小值：白噪声功率谱近似指数分布，
                // 直接取最小值会系统性偏低约 15 dB 且方差很大；
                // 平滑把方差降下来，最小值才贴近均值。
                smoothedPowerPre[k] = pre * smoothedPowerPre[k] + (1 - pre) * powerBuf[k]
            } else {
                // 首个有效帧直接用功率本身，避免平滑缓冲从 0 起步造成初值偏低
                smoothedPowerPre[k] = powerBuf[k]
            }

            let smoothed = smoothedPowerPre[k]
            if smoothed < minPower[k] {
                minPower[k] = smoothed                              // 立刻跟随下降
            } else {
                minPower[k] += drift * (smoothed - minPower[k])     // 极慢向上漂移
            }
            noiseProfile[k] = max(minPower[k] * bias, 1e-12)
        }
        hasInitializedNoise = true
    }

    // MARK: - 增益计算

    private func computeGain() {
        let alpha = config.decisionDirectedAlpha
        let lambdaScale = config.oversubtraction
        let timeSmoothing = config.gainSmoothing
        let floorGain = config.spectralFloor

        for k in 0..<binCount {
            let lambdaD = max(noiseProfile[k], 1e-12)

            // 瞬时 SNR（过子因子作用在这一项上）
            let instantSNR = max(powerBuf[k] / (lambdaD * lambdaScale) - 1, 0)
            // 判决引导的递归项：必须用**上一帧增强后**的信号功率 G²P。
            // 若用上一帧的**含噪**功率，噪声自身会被当成信号，
            // 先验 SNR 被系统性抬高的结果是噪声压制不足（直流残留就是这个症状）。
            let previousEstimate = previousEnhancedPower[k] / lambdaD
            let priorSNR = alpha * previousEstimate + (1 - alpha) * instantSNR

            // Wiener 增益
            var g = priorSNR / (1 + priorSNR)
            // 时间平滑：避免增益闪烁造成的「音乐噪声」
            g = timeSmoothing * previousGain[k] + (1 - timeSmoothing) * g
            // 谱底
            g = max(g, floorGain)
            gain[k] = g
        }

        // 频率维平滑：**按功率加权**的三点均值。
        // 用等权平均的话，空频点（功率≈0，增益被抬到 1）会把邻近被压制的频点拉回去，
        // 直流分量、纯音这类只占少数频点的信号会被泄漏抬升，压制不干净
        // （实测直流残余从 0.025 恶化到 0.207）。按功率加权后空频点权重趋零。
        if timeSmoothing > 0 {
            for k in 0..<binCount {
                let prevIdx = max(k - 1, 0)
                let nextIdx = min(k + 1, binCount - 1)
                let prevW = powerBuf[prevIdx]
                let nextW = powerBuf[nextIdx]
                let selfW = powerBuf[k]
                let numerator = gain[prevIdx] * prevW + 2 * gain[k] * selfW + gain[nextIdx] * nextW
                let denominator = prevW + 2 * selfW + nextW + 1e-20
                scratchGain[k] = numerator / denominator
            }
            for k in 0..<binCount { smoothedGain[k] = scratchGain[k] }
        } else {
            for k in 0..<binCount { smoothedGain[k] = gain[k] }
        }
    }
}
