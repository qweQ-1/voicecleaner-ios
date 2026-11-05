import Foundation

/// 纯 Swift 基-2 迭代式 FFT。
///
/// 之所以不用 Accelerate 的 `vDSP_fft_zrip`：那套 real-FFT 的输入打包/输出解包规则
/// 很容易写错，而这里要求「零第三方依赖 + 可被单元测试逐点验证」，
/// 所以自己实现一份带预计算旋转因子和位反转表的版本。
///
/// 复杂度 O(n log n)，512 点约 2304 个蝶形运算，
/// 48 kHz / hop=128 时每秒约 375 次前向 + 375 次逆向，CPU 占用在 5% 以内。
final class FFT {
    let size: Int
    private let levels: Int
    /// 旋转因子：cosTable[k] = cos(-2πk/n)，sinTable[k] = sin(-2πk/n)
    private let cosTable: [Float]
    private let sinTable: [Float]
    /// 位反转置换表
    private let reversed: [Int]

    init(size: Int) {
        precondition(size > 1 && (size & (size - 1)) == 0, "FFT 长度必须是 2 的幂")
        self.size = size
        self.levels = Int(log2(Double(size)).rounded())

        var cosT = [Float](repeating: 0, count: size / 2)
        var sinT = [Float](repeating: 0, count: size / 2)
        for i in 0..<(size / 2) {
            let angle = -2.0 * Double.pi * Double(i) / Double(size)
            cosT[i] = Float(cos(angle))
            sinT[i] = Float(sin(angle))
        }
        cosTable = cosT
        sinTable = sinT

        var rev = [Int](repeating: 0, count: size)
        for i in 0..<size {
            rev[i] = FFT.reverseBits(i, levels)
        }
        reversed = rev
    }

    /// 就地复数 FFT。
    /// - Parameters:
    ///   - real: 长度必须等于 `size`
    ///   - imag: 长度必须等于 `size`
    ///   - inverse: true 时做逆变换并包含 1/n 归一化
    func transform(real: inout [Float], imag: inout [Float], inverse: Bool) {
        precondition(real.count == size && imag.count == size, "缓冲区长度必须等于 FFT size")

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                let r = rp.baseAddress!
                let i = ip.baseAddress!
                let n = size

                // 1) 位反转置换
                for idx in 0..<n {
                    let j = reversed[idx]
                    if j > idx {
                        let tr = r[idx], ti = i[idx]
                        r[idx] = r[j]; i[idx] = i[j]
                        r[j] = tr;    i[j] = ti
                    }
                }

                // 2) 蝶形运算
                var len = 2
                while len <= n {
                    let half = len >> 1
                    let step = n / len
                    var base = 0
                    while base < n {
                        var k = 0
                        for j in base..<(base + half) {
                            let t = j + half
                            let wr = cosTable[k]
                            let wi = inverse ? -sinTable[k] : sinTable[k]
                            let br = r[t], bi = i[t]
                            // tr + ti = (br + bi*i) * (wr + wi*i)
                            let tr = br * wr - bi * wi
                            let ti = br * wi + bi * wr
                            r[t] = r[j] - tr
                            i[t] = i[j] - ti
                            r[j] += tr
                            i[j] += ti
                            k += step
                        }
                        base += len
                    }
                    len <<= 1
                }

                // 3) 逆变换归一化
                if inverse {
                    let inv = 1.0 / Float(n)
                    for idx in 0..<n {
                        r[idx] *= inv
                        i[idx] *= inv
                    }
                }
            }
        }
    }

    private static func reverseBits(_ value: Int, _ bits: Int) -> Int {
        var v = value
        var out = 0
        for _ in 0..<bits {
            out = (out << 1) | (v & 1)
            v >>= 1
        }
        return out
    }
}
