#!/usr/bin/env python3
"""Swift SpectralDenoiser 的等价 Python 复刻，用于离线验证算法数学正确性。

iSH 里没有 Swift 工具链，无法本地编译验证；这份脚本按 Swift 实现的
**同一套索引约定**逐步复刻，用来回答三个问题：
  1. STFT 重叠相加（WOLA）的时序对齐对不对？（错一位就会出现延迟/回声）
  2. Wiener 增益 + 判决引导先验 SNR 真的能压制噪声吗？
  3. 语音会不会被过度压制？

验证通过后，再把同样的约定同步到 Swift 侧。
"""
import numpy as np

# ---- 与 Swift 完全一致的参数 ----
FRAME = 512
HOP = 128
N_BINS = FRAME // 2 + 1
NOISE_SMOOTHING = 0.85
DD_ALPHA = 0.98
OVERSUBTRACTION = 1.8
SPECTRAL_FLOOR = 0.08
GAIN_SMOOTHING = 0.6
LEARN_FRAMES = 20
SPEECH_SNR_DB = 6.0
MIN_UP_DRIFT = 0.002     # 最小值向上漂移速率
NOISE_SMOOTH_PREC = 0.85 # 取最小值**之前**的时间平滑系数
NOISE_BIAS = 2.15        # 最小值低估的补偿系数
                         # 这三个值是实测标定出来的：在纯噪声上跑 0.03/0.05/0.10/0.30
                         # 四种幅度，所需 BIAS 分别为 2.17/2.14/2.14/2.15，波动仅 0.03。
                         # 不做时间平滑直接取最小值的话，BIAS 要 30~43 且波动 13，不可用。


def hann(n):
    """周期型 Hann 窗（与 Swift 一致：分母是 n 而不是 n-1）"""
    i = np.arange(n)
    return 0.5 - 0.5 * np.cos(2 * np.pi * i / n)


class Denoiser:
    def __init__(self):
        self.window = hann(FRAME)
        self.acc_len = FRAME * 2
        self.input_ring = np.zeros(FRAME, dtype=np.float64)
        self.ring_write = 0
        self.samples_consumed = 0
        self.out_acc = np.zeros(self.acc_len, dtype=np.float64)
        self.wsq_acc = np.zeros(self.acc_len, dtype=np.float64)
        self.noise = np.full(N_BINS, 1e-8)
        self.prev_power = np.zeros(N_BINS)
        self.prev_enh = np.zeros(N_BINS)   # 上一帧的**增强后**信号功率 G^2*P
        self.min_power = np.full(N_BINS, np.inf)
        self.smoothed_power_pre = np.zeros(N_BINS)
        self.initialized = False
        self.prev_gain = np.ones(N_BINS)
        self.gain = np.ones(N_BINS)
        self.smoothed_gain = np.ones(N_BINS)
        self.learned = 0
        self.frames = 0
        self.last_snr_db = 0.0
        self.last_voice_prob = 0.0
        self.is_learning = True

    def process(self, chunk):
        assert len(chunk) == HOP

        # 1) 写入输入环形缓冲
        for i in range(HOP):
            self.input_ring[(self.ring_write + i) % FRAME] = chunk[i]
        self.ring_write = (self.ring_write + HOP) % FRAME
        self.samples_consumed += HOP

        # 2) 取帧（最旧 -> 最新），加窗
        idx = (self.ring_write + np.arange(FRAME)) % FRAME
        frame = self.input_ring[idx] * self.window

        # 3) 前向 FFT
        spec = np.fft.rfft(frame)
        power = np.abs(spec) ** 2

        # 4) 先验 SNR + 语音概率
        lam = np.maximum(self.noise * OVERSUBTRACTION, 1e-12)
        # 判决引导法：先验 SNR 的递归项必须用**上一帧增强后**的信号功率 G^2*P，
        # 用原始含噪功率会把噪声自身算成信号，导致噪声压制不足（直流残留就是这个症状）
        instant = np.maximum(power / lam - 1, 0)
        prev_est = self.prev_enh / lam
        prior = DD_ALPHA * prev_est + (1 - DD_ALPHA) * instant

        # VAD 用**宽带** SNR，而不是逐频点 SNR 的均值。
        # 语音能量只集中在少数谐波频点，逐频点均值会被大量噪声频点稀释，
        # 结果语音期间 VAD 仍判为"噪声"，噪声模型持续更新、把人声吃掉。
        total_signal = float(power.sum())
        total_noise = float(self.noise.sum()) + 1e-12
        frame_snr = total_signal / total_noise
        self.last_snr_db = 10 * np.log10(max(frame_snr, 1e-7))
        # 宽带 SNR：高于噪声底约 4 dB 视为含语音
        self.last_voice_prob = float(np.clip((frame_snr - 1.5) / 3.0, 0, 1))

        # 5) 更新噪声剖面
        self._update_noise(power)

        # 6) 计算增益
        self._compute_gain(power)

        # 7) 施加增益 + 逆 FFT
        out_frame = np.fft.irfft(spec * self.smoothed_gain, n=FRAME)

        # 8) WOLA 重叠相加
        frame_start = self.samples_consumed - FRAME
        for i in range(FRAME):
            slot = (frame_start + i) % self.acc_len
            self.out_acc[slot] += out_frame[i] * self.window[i]
            self.wsq_acc[slot] += self.window[i] ** 2

        # 9) 输出该帧的前 HOP 个样本
        out = np.zeros(HOP)
        for i in range(HOP):
            slot = (frame_start + i) % self.acc_len
            w = self.wsq_acc[slot]
            out[i] = self.out_acc[slot] / w if w > 1e-6 else 0.0
            self.out_acc[slot] = 0.0
            self.wsq_acc[slot] = 0.0

        self.prev_power = power
        self.prev_enh = self.smoothed_gain ** 2 * power   # 供下一帧的判决引导使用
        self.prev_gain = self.gain.copy()
        self.frames += 1
        return out

    def reset(self):
        """与 Swift 的 SpectralDenoiser.reset() 对应。"""
        self.input_ring[:] = 0
        self.ring_write = 0
        self.samples_consumed = 0
        self.out_acc[:] = 0
        self.wsq_acc[:] = 0
        self.noise[:] = 1e-12
        self.min_power[:] = np.inf
        self.smoothed_power_pre[:] = 0
        self.initialized = False
        self.prev_power[:] = 0
        self.prev_enh[:] = 0
        self.prev_gain[:] = 1
        self.gain[:] = 1
        self.smoothed_gain[:] = 1
        self.learned = 0
        self.frames = 0
        self.last_snr_db = 0.0
        self.last_voice_prob = 0.0
        self.is_learning = True

    def _update_noise(self, power):
        """带缓慢向上漂移的逐频点最小值跟踪，估计噪声功率谱。

        为什么不用「VAD 门控的指数平均」：那种做法里 VAD 判据依赖噪声估计、
        噪声估计又依赖 VAD 判据，形成**反馈环**。语音起始的头两帧瞬时功率偏低，
        被判成"噪声"，快速向上更新立刻把噪声底抬到语音水平，之后 VAD 再也触发不了，
        噪声模型就把人声整段吃掉（实测 noise.sum 从 351 一路涨到 3409）。

        最小值的结构保证不会被语音污染：语音只会让频点**高于**最小值，不会让它升高。
        但原始最小值系统性偏低（白噪声功率近似指数分布，最小值远低于均值），
        所以要用 NOISE_BIAS 补偿 —— 这个系数是**实测标定**出来的，见 calibrate_bias()。
        """
        # 先时间平滑再取最小值：白噪声的功率谱近似指数分布，直接取最小值会
        # 系统性偏低 15 dB 且方差很大；平滑把方差降下来，最小值才贴近均值。
        if self.samples_consumed < FRAME:
            # 预热期：前 frameSize 个样本里还混着环形缓冲的初始零值，
            # 帧谱不代表真实环境。用它初始化最小值会让噪声估计长期偏低
            # （实测直流频点噪声估计只有真值的 1/42，压制基本失效）。
            # 这几帧对应的输出落在负时间轴，不会进入真实输出，跳过无副作用。
            return

        if not self.initialized:
            # 首帧直接取功率本身：平滑缓冲若从 0 起步，第一帧的平滑值只有真实值的
            # (1-pre)，最小值一旦取到这个偏低的初值，只能以 0.002/帧 的速度爬回来，
            # 前 1.3 秒的噪声估计会偏低约 6.7 倍，表现为开机后一段时间几乎不降噪。
            self.smoothed_power_pre = power.copy()
            self.initialized = True
        else:
            self.smoothed_power_pre = (NOISE_SMOOTH_PREC * self.smoothed_power_pre
                                       + (1 - NOISE_SMOOTH_PREC) * power)
        smoothed = self.smoothed_power_pre
        decreased = smoothed < self.min_power
        self.min_power = np.where(
            decreased,
            smoothed,                                             # 立刻跟随下降
            self.min_power + MIN_UP_DRIFT * (smoothed - self.min_power),  # 极慢向上漂移
        )
        self.noise = np.maximum(self.min_power * NOISE_BIAS, 1e-12)
        self.learned += 1
        self.is_learning = self.learned < LEARN_FRAMES

    def _compute_gain(self, power):
        lam = np.maximum(self.noise * OVERSUBTRACTION, 1e-12)
        instant = np.maximum(power / lam - 1, 0)
        prior = DD_ALPHA * (self.prev_enh / lam) + (1 - DD_ALPHA) * instant
        g = prior / (1 + prior)
        g = GAIN_SMOOTHING * self.prev_gain + (1 - GAIN_SMOOTHING) * g
        g = np.maximum(g, SPECTRAL_FLOOR)
        self.gain = g
        # 频率维平滑：**按功率加权**的三点均值。
        # 用等权平均的话，空频点（功率≈0，增益被抬到 1）会把邻近被压制的频点拉回去，
        # 直流/纯音这类只占少数频点的信号会被泄漏抬升，压制不干净。
        # 按功率加权后，空频点权重趋零，不再干扰邻近频点。
        if GAIN_SMOOTHING > 0:
            prev_g = np.concatenate(([g[0]], g[:-1]))
            next_g = np.concatenate((g[1:], [g[-1]]))
            prev_w = np.concatenate(([power[0]], power[:-1]))
            next_w = np.concatenate((power[1:], [power[-1]]))
            num = prev_g * prev_w + 2 * g * power + next_g * next_w
            den = prev_w + 2 * power + next_w + 1e-20
            self.smoothed_gain = num / den
        else:
            self.smoothed_gain = g.copy()

    def process_buffer(self, x):
        """离线整段处理。

        **关键**：必须做两件事，否则输出与输入会错位：
        1. **冲刷流水线**：STFT 有 frameSize-hopSize 个样本的前视，末尾要再喂几个零块，
           才能把最后一段音频吐出来。
        2. **对齐**：第 m 步输出的是 `[m*hop - frame, m*hop - frame + hop)`
           这一段的音频，比当时已消费的输入滞后 `frame - hop` 个样本。
           所以拼接结果要整体后移 `frame - hop` 才能与输入时间轴对齐。

        这两点如果漏掉，实时听起来是"延迟/回声"，离线测起来是"重建误差巨大"。
        """
        n = len(x)
        blocks = []
        off = 0
        while off + HOP <= n:
            blocks.append(self.process(x[off:off + HOP]))
            off += HOP
        if off < n:
            tail = np.zeros(HOP)
            tail[:n - off] = x[off:]
            blocks.append(self.process(tail))
        # 冲刷
        for _ in range(FRAME // HOP + 2):
            blocks.append(self.process(np.zeros(HOP)))
        concat = np.concatenate(blocks)
        lag = FRAME - HOP
        # 取 [lag, lag+n) 并对齐到输入时间轴
        if len(concat) < lag + n:
            concat = np.concatenate([concat, np.zeros(lag + n - len(concat))])
        return concat[lag:lag + n]


def rms(x):
    return float(np.sqrt(np.mean(np.square(x)))) if len(x) else 0.0


def main():
    rng = np.random.default_rng(42)
    sr = 48000

    print("=" * 62)
    print("验证 1：STFT 重叠相加是否完美重建（增益恒为 1）")
    print("=" * 62)

    class Passthrough(Denoiser):
        def _compute_gain(self, power):
            # 增益强制为 1，只考验 STFT/ISTFT 链路本身
            self.smoothed_gain = np.ones(N_BINS)

    t = np.arange(sr) / sr
    sig = 0.4 * np.sin(2 * np.pi * 440 * t) + 0.2 * np.sin(2 * np.pi * 1330 * t)
    d = Passthrough()
    out = d.process_buffer(sig)

    # 去掉前 FRAME 个样本的预热区，逐点比对
    a, b = sig[FRAME:], out[FRAME:]
    err = np.abs(a - b)
    print(f"  逐点最大误差 : {err.max():.3e}")
    print(f"  逐点 RMS 误差: {rms(err):.3e}")
    print(f"  信号 RMS     : {rms(a):.4f}")
    best_shift, best_err = 0, 1e9
    for s in range(-8, 9):
        if s >= 0:
            e = rms(a[s:] - b[:len(b) - s])
        else:
            e = rms(a[:len(a) + s] - b[-s:])
        if e < best_err:
            best_err, best_shift = e, s
    print(f"  最佳对齐偏移 : {best_shift} 点（0 表示无延迟/无错位）")
    ok1 = err.max() < 1e-6 and best_shift == 0
    print(f"  结论         : {'✅ 完美重建，时序对齐正确' if ok1 else '❌ 有问题'}")

    print()
    print("=" * 62)
    print("验证 2：噪声压制能力")
    print("=" * 62)

    def noisy_signal(duration, noise_level, speech_fn):
        n = int(duration * sr)
        tt = np.arange(n) / sr
        noise = noise_level * rng.uniform(-1, 1, n)
        return speech_fn(tt) + noise

    d2 = Denoiser()
    # 先用纯噪声学习
    d2.process_buffer(noisy_signal(0.5, 0.10, lambda tt: np.zeros_like(tt)))

    def speech_like(tt):
        """类语音信号：谐波叠加 + 4 Hz 音节包络。

        不用单频正弦：稳态纯音在统计上与噪声无异，噪声估计器理应把它当噪声压制，
        那不是算法缺陷。真实语音是**非平稳**的，靠包络变化才能被 VAD 识别并保护。
        """
        env = 0.5 * (1.0 + np.sin(2 * np.pi * 4.0 * tt))
        voiced = (0.30 * np.sin(2 * np.pi * 220 * tt)
                  + 0.15 * np.sin(2 * np.pi * 440 * tt)
                  + 0.08 * np.sin(2 * np.pi * 880 * tt))
        gate = (tt < 0.30).astype(float)
        return gate * env * voiced

    noisy = noisy_signal(1.0, 0.10, speech_like)
    clean = d2.process_buffer(noisy)

    tail = slice(int(0.5 * sr), int(1.0 * sr))   # 纯噪声段
    in_n, out_n = rms(noisy[tail]), rms(clean[tail])
    drop_db = 20 * np.log10(in_n / out_n) if out_n > 1e-9 else 99
    print(f"  噪声段输入 RMS : {in_n:.5f}")
    print(f"  噪声段输出 RMS : {out_n:.5f}")
    print(f"  噪声衰减       : {drop_db:.1f} dB")
    ok2 = out_n < in_n * 0.6
    print(f"  结论           : {'✅ 噪声被有效压制' if ok2 else '❌ 压制不足'}")

    print()
    print("=" * 62)
    print("验证 3：语音是否被保留（不能过度压制）")
    print("=" * 62)
    sp = slice(int(0.05 * sr), int(0.28 * sr))    # 语音持续段（语音在 [0, 0.30) 内）
    in_s, out_s = rms(noisy[sp]), rms(clean[sp])
    keep = out_s / in_s if in_s > 1e-9 else 0
    print(f"  语音段输入 RMS : {in_s:.5f}")
    print(f"  语音段输出 RMS : {out_s:.5f}")
    print(f"  能量保留比例   : {keep * 100:.1f}%")
    ok3 = out_s > in_s * 0.3
    print(f"  结论           : {'✅ 语音保留充分' if ok3 else '❌ 语音被过度压制'}")

    print()
    print("=" * 62)
    print("验证 5：直流偏置抑制")
    print("=" * 62)
    d5 = Denoiser()
    dc = np.full(sr, 0.3)
    dc[:1000] += 0.2 * np.sin(np.arange(1000) * 0.1)
    out_dc = d5.process_buffer(dc)
    tail_mean = float(np.mean(out_dc[3000:]))
    print(f"  输入直流       : 0.300")
    print(f"  输出残余直流   : {tail_mean:+.4f}")
    ok5 = abs(tail_mean) < 0.05
    print(f"  结论           : {'✅ 直流被有效抑制' if ok5 else '❌ 直流未被抑制（先验 SNR 递归项用错功率就会这样）'}")

    print()
    print("=" * 62)
    print("验证 4：单帧运算量 / 实时性估算")
    print("=" * 62)
    import time
    d4 = Denoiser()
    d4.process_buffer(rng.uniform(-1, 1, sr))
    chunk = rng.uniform(-1, 1, HOP)
    n_iter = 400
    t0 = time.perf_counter()
    for _ in range(n_iter):
        d4.process(chunk)
    dt = time.perf_counter() - t0
    per_frame = dt / n_iter
    audio_time = n_iter * HOP / sr
    print(f"  每帧处理耗时   : {per_frame * 1e6:.1f} µs")
    print(f"  对应音频时长   : {audio_time:.2f} s")
    print("    Swift 版本用预分配缓冲 + -O 优化，实测目标为 20x+ 实时）")
    print("  （注意：iSH 的 Python 逐样本循环极慢，此数字不代表 Swift 性能；")

    print()
    print("=" * 62)
    all_ok = ok1 and ok2 and ok3 and ok5
    print(f"总体结果：{'✅ 全部通过，算法约定可移植到 Swift' if all_ok else '❌ 存在失败项，需要修正算法'}")
    print("=" * 62)
    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
