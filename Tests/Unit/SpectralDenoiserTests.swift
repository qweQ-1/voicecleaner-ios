import XCTest
@testable import VoiceCleaner

/// 降噪器行为测试。
///
/// 重点验证三件事：
/// 1. **不引入失真**：纯语音信号过一遍降噪器，波形不能被毁掉。
/// 2. **确实压制噪声**：加噪后处理，噪声段能量应显著下降。
/// 3. **输出对齐**：输出与输入不能错位（错位在实时使用中表现为延迟/回声）。
final class SpectralDenoiserTests: XCTestCase {

    private func makeConfig() -> SpectralDenoiser.Configuration {
        var cfg = SpectralDenoiser.Configuration()
        cfg.sampleRate = 48_000
        cfg.frameSize = 512
        cfg.hopSize = 128
        cfg.noiseLearningFrames = 20
        return cfg
    }

    /// 生成一段测试信号。
    private func generateSignal(
        duration: Double,
        sampleRate: Double,
        noiseLevel: Float,
        speech: (Double) -> Float
    ) -> [Float] {
        let count = Int(duration * sampleRate)
        var result = [Float](repeating: 0, count: count)
        var seed: UInt64 = 42
        for i in 0..<count {
            // 确定性伪随机噪声，保证测试可复现
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let random = Float((seed >> 33) % 20_000) / 10_000 - 1.0
            let t = Double(i) / sampleRate
            result[i] = speech(t) + noiseLevel * random
        }
        return result
    }

    /// 纯静音输入时，输出应基本也是静音（不能自己造出噪声）。
    func testSilentInputProducesSilentOutput() {
        let denoiser = SpectralDenoiser(configuration: makeConfig())
        let input = [Float](repeating: 0, count: 4800)
        let output = denoiser.processBuffer(input)

        let outputRMS = AudioMath.rms(output[0..<output.count])
        XCTAssertLessThan(outputRMS, 1e-4, "静音输入不应产生输出")
    }

    /// 直流偏置应被有效抑制。
    func testRemovesDCOffset() {
        let denoiser = SpectralDenoiser(configuration: makeConfig())
        var input = [Float](repeating: 0.3, count: 4800)
        // 前 1000 点加一段语音，让算法进入稳态
        for i in 0..<1000 {
            input[i] += Float(sin(Double(i) * 0.1)) * 0.2
        }
        let output = denoiser.processBuffer(input)

        // 看尾部（算法已稳态）的均值
        let tail = output[3000..<output.count]
        let mean = tail.reduce(0, +) / Float(tail.count)
        XCTAssertLessThan(abs(mean), 0.05, "直流偏置应被抑制，实际残余 \(mean)")
    }

    /// 噪声压制：加噪信号处理后，噪声段的能量应下降。
    func testSuppressesNoiseInSilentSegments() {
        let denoiser = SpectralDenoiser(configuration: makeConfig())
        let sampleRate = 48_000.0

        // 先用纯噪声学习噪声剖面
        let noiseOnly = generateSignal(duration: 0.2, sampleRate: sampleRate, noiseLevel: 0.1,
                                       speech: { _ in 0 })
        _ = denoiser.processBuffer(noiseOnly)

        // 再处理含噪信号，在「无声段」测量能量
        let noisy = generateSignal(duration: 0.4, sampleRate: sampleRate, noiseLevel: 0.1,
                                   speech: { t in
                                       // 前 0.15 秒有语音，之后是纯噪声
                                       t < 0.15 ? Float(sin(2 * .pi * 220 * t)) * 0.3 : 0
                                   })
        let output = denoiser.processBuffer(noisy)

        // 取尾部纯噪声段
        let noiseStart = Int(0.25 * sampleRate)
        let inputNoise = AudioMath.rms(noisy[noiseStart..<noisy.count])
        let outputNoise = AudioMath.rms(output[noiseStart..<output.count])

        XCTAssertLessThan(outputNoise, inputNoise * 0.6,
                          "噪声段应被压制：输入 \(inputNoise) → 输出 \(outputNoise)")
    }

    /// 输出与输入长度一致（不丢样本）。
    func testOutputLengthMatchesInputLength() {
        let denoiser = SpectralDenoiser(configuration: makeConfig())
        let input = [Float](repeating: 0.1, count: 1000)
        let output = denoiser.processBuffer(input)
        XCTAssertEqual(output.count, input.count)
    }

    /// 输出不能有明显直流偏置（重建过程的对齐错误最典型的表现）。
    func testNoSpuriousDCInOutput() {
        let denoiser = SpectralDenoiser(configuration: makeConfig())
        let input = generateSignal(duration: 0.3, sampleRate: 48_000, noiseLevel: 0.02,
                                   speech: { t in Float(sin(2 * .pi * 440 * t)) * 0.2 })
        let output = denoiser.processBuffer(input)

        let tail = output[2000..<output.count]
        let mean = tail.reduce(0, +) / Float(tail.count)
        XCTAssertLessThan(abs(mean), 0.02, "输出不应有直流分量，实际 \(mean)")
    }

    /// 语音应被保留。
    ///
    /// - Important: 这里的"语音"必须用**非平稳**信号（谐波 + 音节级调幅）。
    ///   稳态纯正弦在统计上和稳态噪声无法区分，降噪器把它压掉是**正确行为**
    ///   （风扇声、电流声就是这种）。早期版本用纯正弦做这个测试，
    ///   得到的结论是错的。
    func testPreservesSpeechContent() {
        let denoiser = SpectralDenoiser(configuration: makeConfig())
        let sampleRate = 48_000.0

        // 先用纯噪声让噪声剖面收敛
        let noiseOnly = generateSignal(duration: 0.6, sampleRate: sampleRate, noiseLevel: 0.08,
                                       speech: { _ in 0 })
        _ = denoiser.processBuffer(noiseOnly)

        // 类语音：三个谐波 × 4 Hz 音节包络（与真实语音一样是非平稳的）
        let syllabic: (Double) -> Float = { t in
            let envelope = 0.5 * (1.0 + sin(2 * .pi * 4.0 * t))
            let harmonics = 0.30 * sin(2 * .pi * 220 * t)
                + 0.15 * sin(2 * .pi * 440 * t)
                + 0.08 * sin(2 * .pi * 880 * t)
            return Float(envelope * harmonics)
        }
        let speech = generateSignal(duration: 1.0, sampleRate: sampleRate, noiseLevel: 0.08,
                                    speech: syllabic)
        let output = denoiser.processBuffer(speech)

        let start = Int(0.2 * sampleRate)
        let inputRMS = AudioMath.rms(speech[start..<speech.count])
        let outputRMS = AudioMath.rms(output[start..<output.count])

        XCTAssertGreaterThan(outputRMS, inputRMS * 0.3,
                             "语音能量不应被过度压制：输入 \(inputRMS) → 输出 \(outputRMS)")
    }

    /// 稳态纯音（噪声）应被显著压制——这是与「语音保留」配对的反向保证。
    func testSuppressesStationaryTone() {
        let denoiser = SpectralDenoiser(configuration: makeConfig())
        let sampleRate = 48_000.0

        let noiseOnly = generateSignal(duration: 0.6, sampleRate: sampleRate, noiseLevel: 0.02,
                                       speech: { _ in 0 })
        _ = denoiser.processBuffer(noiseOnly)

        // 稳态 300 Hz 纯音 + 少量噪声：与稳态噪声不可区分，应被压掉
        let tone = generateSignal(duration: 1.0, sampleRate: sampleRate, noiseLevel: 0.02,
                                  speech: { t in Float(sin(2 * .pi * 300 * t)) * 0.4 })
        let output = denoiser.processBuffer(tone)

        let start = Int(0.4 * sampleRate)
        let inputRMS = AudioMath.rms(tone[start..<tone.count])
        let outputRMS = AudioMath.rms(output[start..<output.count])

        XCTAssertLessThan(outputRMS, inputRMS * 0.5,
                          "稳态纯音应被压制：输入 \(inputRMS) → 输出 \(outputRMS)")
    }

    /// reset 后应重新进入学习状态。
    func testResetRestoresLearningState() {
        let denoiser = SpectralDenoiser(configuration: makeConfig())
        let input = [Float](repeating: 0.05, count: 4800)
        _ = denoiser.processBuffer(input)

        XCTAssertFalse(denoiser.isLearningNoise, "处理足够帧后应离开学习状态")

        denoiser.reset()
        XCTAssertTrue(denoiser.isLearningNoise, "reset 后应重新学习")
        XCTAssertEqual(denoiser.processedFrames, 0)
    }

    /// **时序回归测试**：把增益强制为 1，整条 STFT 链路必须逐点重建原信号。
    ///
    /// 这是整个降噪器最关键的测试。重叠相加的索引只要错一位，
    /// 实时表现就是「延迟」或「回声」，离线表现是「重建误差巨大」，
    /// 而在噪声段测 RMS 时这种错位往往**不会**被发现。
    ///
    /// 把 `spectralFloor` 设为 1.0（增益下限拉到 1）、`gainSmoothing` 设为 0
    /// （不做时间平滑），Wiener 增益就会被 max(g, 1.0) 抬到恒等于 1，
    /// 于是输出应当逐点等于输入。
    func testPerfectReconstructionWithUnityGain() {
        var cfg = SpectralDenoiser.Configuration()
        cfg.sampleRate = 48_000
        cfg.frameSize = 512
        cfg.hopSize = 128
        cfg.spectralFloor = 1.0      // 增益下限 = 1 → 恒等
        cfg.gainSmoothing = 0.0      // 不做时间平滑
        cfg.noiseLearningFrames = 5

        let denoiser = SpectralDenoiser(configuration: cfg)

        // 用双音信号，便于发现相位/错位问题
        let n = 24_000
        var input = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / 48_000
            input[i] = Float(0.4 * sin(2 * .pi * 440 * t) + 0.2 * sin(2 * .pi * 1330 * t))
        }

        let output = denoiser.processBuffer(input)

        XCTAssertEqual(output.count, input.count, "输出长度必须与输入一致")

        var maxError: Float = 0
        for i in 0..<n {
            maxError = max(maxError, abs(output[i] - input[i]))
        }
        XCTAssertLessThan(maxError, 1e-3,
                          "恒等增益下必须逐点重建，实际最大误差 \(maxError)")

        // 相对信号幅度而言，误差必须小到可忽略
        let signalPeak = AudioMath.peak(input[0..<n])
        XCTAssertLessThan(maxError / signalPeak, 1e-3,
                          "相对误差应小于千分之一")
    }

    /// 输出不能整体错位（延迟/超前）。
    func testOutputIsTimeAlignedWithInput() {
        var cfg = SpectralDenoiser.Configuration()
        cfg.frameSize = 512
        cfg.hopSize = 128
        cfg.spectralFloor = 1.0
        cfg.gainSmoothing = 0.0
        cfg.noiseLearningFrames = 5

        let denoiser = SpectralDenoiser(configuration: cfg)
        let n = 16_000
        var input = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / 48_000
            input[i] = Float(0.5 * sin(2 * .pi * 700 * t))
        }
        let output = denoiser.processBuffer(input)

        // 直接逐点比较：如果能对上，说明零延迟、零超前
        var directError: Float = 0
        for i in 1000..<(n - 1000) {
            directError += abs(output[i] - input[i])
        }
        directError /= Float(n - 2000)

        // 与人为平移若干点的误差对比：直接对齐必须是最小的
        for shift in [1, 4, 16, -1, -4, -16] {
            var shiftedError: Float = 0
            var count = 0
            for i in 1000..<(n - 1000) {
                let j = i + shift
                if j >= 0 && j < n {
                    shiftedError += abs(output[i] - input[j])
                    count += 1
                }
            }
            shiftedError /= Float(max(count, 1))
            XCTAssertLessThan(directError, shiftedError,
                              "输出不应相对输入偏移 \(shift) 个样本")
        }
    }

    /// 非法配置应被纠正为安全值，而不是崩溃。
    func testInvalidConfigurationIsSanitized() {
        var cfg = SpectralDenoiser.Configuration()
        cfg.frameSize = 1000   // 不是 2 的幂
        cfg.hopSize = 0        // 非法
        cfg.spectralFloor = 5  // 越界

        let denoiser = SpectralDenoiser(configuration: cfg)
        XCTAssertEqual(denoiser.config.frameSize, 1024)
        XCTAssertGreaterThan(denoiser.config.hopSize, 0)
        XCTAssertLessThanOrEqual(denoiser.config.spectralFloor, 1.0)
    }
}
