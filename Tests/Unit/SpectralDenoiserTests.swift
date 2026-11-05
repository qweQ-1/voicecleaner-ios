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

    /// 语音段应被保留（不能把整段都压掉）。
    func testPreservesSpeechContent() {
        let denoiser = SpectralDenoiser(configuration: makeConfig())
        let sampleRate = 48_000.0

        let noiseOnly = generateSignal(duration: 0.2, sampleRate: sampleRate, noiseLevel: 0.05,
                                       speech: { _ in 0 })
        _ = denoiser.processBuffer(noiseOnly)

        // 持续语音 + 噪声
        let speech = generateSignal(duration: 0.4, sampleRate: sampleRate, noiseLevel: 0.05,
                                    speech: { t in Float(sin(2 * .pi * 300 * t)) * 0.4 })
        let output = denoiser.processBuffer(speech)

        let speechStart = Int(0.2 * sampleRate)
        let inputRMS = AudioMath.rms(speech[speechStart..<speech.count])
        let outputRMS = AudioMath.rms(output[speechStart..<output.count])

        // 语音应保留大部分能量（不能衰减到 30% 以下）
        XCTAssertGreaterThan(outputRMS, inputRMS * 0.3,
                             "语音能量不应被过度压制：输入 \(inputRMS) → 输出 \(outputRMS)")
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
