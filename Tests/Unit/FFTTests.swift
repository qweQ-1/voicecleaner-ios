import XCTest
@testable import VoiceCleaner

/// FFT 正确性测试。
///
/// FFT 是整个降噪链的地基：一旦符号、归一化或位反转写错，
/// 上层算出来的增益就全是噪声，且现象非常难定位。
final class FFTTests: XCTestCase {

    /// 单频信号经过 FFT 后，能量应集中在对应 bin。
    func testSingleToneConcentratesEnergyAtExpectedBin() {
        let n = 512
        let fft = FFT(size: n)
        var real = [Float](repeating: 0, count: n)
        var imag = [Float](repeating: 0, count: n)

        // bin 32 对应频率 k/n，即 32/512 = 1/16 of sample rate
        let bin = 32
        for i in 0..<n {
            real[i] = Float(cos(2.0 * Double.pi * Double(bin) * Double(i) / Double(n)))
        }

        fft.transform(real: &real, imag: &imag, inverse: false)

        var magnitudes = [Float](repeating: 0, count: n / 2 + 1)
        var peakBin = 0
        var peakValue: Float = 0
        for k in 0..<(n / 2 + 1) {
            magnitudes[k] = (real[k] * real[k] + imag[k] * imag[k]).squareRoot()
            if magnitudes[k] > peakValue {
                peakValue = magnitudes[k]
                peakBin = k
            }
        }

        XCTAssertEqual(peakBin, bin, "峰值 bin 应与输入频率一致")
        // 峰值幅度应为 n/2（实余弦信号的双边幅度）
        XCTAssertEqual(peakValue, Float(n) / 2, accuracy: Float(n) / 2 * 0.01,
                       "峰值幅度应接近 n/2")
    }

    /// 正变换 → 逆变换 应还原原始信号。
    func testRoundTripRestoresOriginalSignal() {
        let n = 256
        let fft = FFT(size: n)
        var real = [Float](repeating: 0, count: n)
        var imag = [Float](repeating: 0, count: n)

        var original = [Float](repeating: 0, count: n)
        for i in 0..<n {
            original[i] = Float(sin(Double(i) * 0.3)) + Float(cos(Double(i) * 1.7)) * 0.5
            real[i] = original[i]
        }

        fft.transform(real: &real, imag: &imag, inverse: false)
        fft.transform(real: &real, imag: &imag, inverse: true)

        for i in 0..<n {
            XCTAssertEqual(real[i], original[i], accuracy: 1e-4, "第 \(i) 点应还原")
        }
    }

    /// 直流分量应落在 bin 0。
    func testDCComponentLandsInBinZero() {
        let n = 128
        let fft = FFT(size: n)
        var real = [Float](repeating: 1, count: n)
        var imag = [Float](repeating: 0, count: n)

        fft.transform(real: &real, imag: &imag, inverse: false)

        XCTAssertEqual(real[0], Float(n), accuracy: 1e-2)
        XCTAssertEqual(imag[0], 0, accuracy: 1e-2)
        for k in 1..<(n / 2 + 1) {
            XCTAssertEqual((real[k] * real[k] + imag[k] * imag[k]).squareRoot(), 0, accuracy: 1e-2,
                           "非直流 bin 应为空")
        }
    }

    /// 能量守恒（Parseval）：时域能量 == 频域能量 / n
    func testParsevalEnergyConservation() {
        let n = 256
        let fft = FFT(size: n)
        var real = [Float](repeating: 0, count: n)
        var imag = [Float](repeating: 0, count: n)

        var timeEnergy: Float = 0
        for i in 0..<n {
            real[i] = Float(sin(Double(i) * 0.11))
            timeEnergy += real[i] * real[i]
        }

        fft.transform(real: &real, imag: &imag, inverse: false)

        var freqEnergy: Float = 0
        for k in 0..<(n / 2 + 1) {
            freqEnergy += real[k] * real[k] + imag[k] * imag[k]
        }
        freqEnergy *= 2
        // 去掉直流和 Nyquist 的重复计数
        freqEnergy -= real[0] * real[0] + imag[0] * imag[0]

        XCTAssertEqual(timeEnergy, freqEnergy / Float(n), accuracy: 1e-2)
    }

    /// 合法尺寸可正常构造，且尺寸被如实记录。
    ///
    /// 非法尺寸（非 2 的幂）由 `precondition` 拦截并直接崩溃，
    /// XCTest 里无法断言崩溃，所以这里只守住合法路径。
    func testAcceptsPowerOfTwoSizes() {
        for size in [64, 128, 512, 1024] {
            let fft = FFT(size: size)
            XCTAssertEqual(fft.size, size)
            // 构造后应能立刻完成一次变换而不越界
            var real = [Float](repeating: 0, count: size)
            var imag = [Float](repeating: 0, count: size)
            real[0] = 1
            fft.transform(real: &real, imag: &imag, inverse: false)
            XCTAssertEqual(real[0], 1, accuracy: 1e-5)
        }
    }
}
