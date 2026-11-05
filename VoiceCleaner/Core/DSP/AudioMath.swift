import Foundation

/// 常用音频数学工具。
enum AudioMath {
    /// 峰值归一化系数：把 [-1, 1] 以外的样本压回范围，避免削波失真。
    static func softClip(_ x: Float, threshold: Float = 0.98) -> Float {
        let a = abs(x)
        guard a > threshold else { return x }
        let sign: Float = x < 0 ? -1 : 1
        // 平方根软限幅：超过阈值后增益按 sqrt 曲线衰减，听感比硬削波自然
        let over = (a - threshold) / (1 - threshold)
        return sign * (threshold + (1 - threshold) * sqrt(over))
    }

    /// 直流偏置移除（一阶高通），返回新的状态滤波器。
    static func makeDCBlocker(cutoffHz: Float, sampleRate: Float) -> (filter: (Float) -> Float) {
        let rc = 1.0 / (2.0 * Float.pi * cutoffHz)
        let dt = 1.0 / sampleRate
        let alpha = rc / (rc + dt)
        var lastIn: Float = 0
        var lastOut: Float = 0
        return { input -> Float in
            let out = alpha * (lastOut + input - lastIn)
            lastIn = input
            lastOut = out
            return out
        }
    }

    /// RMS
    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return sqrt(sum / Float(samples.count))
    }

    /// 峰值
    static func peak(_ samples: ArraySlice<Float>) -> Float {
        var p: Float = 0
        for s in samples { p = max(p, abs(s)) }
        return p
    }

    /// 线性幅度转 dBFS（-160 为静音底）
    static func db(_ amplitude: Float) -> Float {
        guard amplitude > 1e-7 else { return -160 }
        return 20 * log10(amplitude)
    }

    /// dBFS 转线性幅度
    static func amplitude(_ db: Float) -> Float {
        guard db > -160 else { return 0 }
        return pow(10, db / 20)
    }
}
