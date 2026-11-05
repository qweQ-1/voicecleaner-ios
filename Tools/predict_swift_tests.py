#!/usr/bin/env python3
"""离线预测 Swift 单元测试的结果。

iSH 里没有 Swift 工具链，本地跑不了 XCTest。这份脚本用 Python 复刻
`Tests/Unit/SpectralDenoiserTests.swift` 里每个测试的**信号生成方式与断言阈值**，
跑一遍看哪些会过、哪些会挂 —— 避免每轮 CI 等 8 分钟才发现阈值定错。

注意：这里的伪随机序列与 Swift 版逐位对齐（同一个 LCG、同样的截断规则），
所以测出来的结论对 Swift 有参考价值。
"""
import numpy as np
import importlib.util

spec = importlib.util.spec_from_file_location("vd", "Tools/verify_dsp.py")
vd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vd)

SR = 48000.0


def swift_random_signal(duration, sample_rate, noise_level, speech_fn):
    """与 Swift 的 generateSignal 逐位对齐：同一个 LCG。"""
    count = int(duration * sample_rate)
    out = np.zeros(count)
    seed = 42
    for i in range(count):
        seed = (seed * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
        r = ((seed >> 33) % 20000) / 10000.0 - 1.0
        out[i] = speech_fn(i / sample_rate) + noise_level * r
    return out


def rms(x):
    return float(np.sqrt(np.mean(np.square(x)))) if len(x) else 0.0


def new_denoiser():
    return vd.Denoiser()


results = []


def check(name, condition, detail):
    results.append((name, condition, detail))
    print(f"  {'✅' if condition else '❌'} {name}\n       {detail}")


print("=" * 70)
print("预测 Swift 单元测试结果")
print("=" * 70)

# --- testSilentInputProducesSilentOutput ---
d = new_denoiser()
out = d.process_buffer(np.zeros(4800))
r = rms(out)
check("testSilentInputProducesSilentOutput", r < 1e-4, f"输出 RMS = {r:.3e}（阈值 < 1e-4）")

# --- testRemovesDCOffset ---
d = new_denoiser()
x = np.full(4800, 0.3)
x[:1000] += 0.2 * np.sin(np.arange(1000) * 0.1)
out = d.process_buffer(x)
mean = float(np.mean(out[3000:]))
check("testRemovesDCOffset", abs(mean) < 0.05, f"残余直流 = {mean:+.4f}（阈值 < 0.05）")

# --- testSuppressesNoiseInSilentSegments ---
d = new_denoiser()
d.process_buffer(swift_random_signal(0.2, SR, 0.1, lambda t: 0.0))
noisy = swift_random_signal(0.4, SR, 0.1, lambda t: np.sin(2*np.pi*220*t)*0.3 if t < 0.15 else 0.0)
out = d.process_buffer(noisy)
n0 = int(0.25 * SR)
i_n, o_n = rms(noisy[n0:]), rms(out[n0:])
check("testSuppressesNoiseInSilentSegments", o_n < i_n * 0.6,
      f"噪声 RMS {i_n:.5f} → {o_n:.5f}（阈值 < {i_n*0.6:.5f}）")

# --- testOutputLengthMatchesInputLength ---
d = new_denoiser()
out = d.process_buffer(np.full(1000, 0.1))
check("testOutputLengthMatchesInputLength", len(out) == 1000, f"输出长度 {len(out)}（期望 1000）")

# --- testNoSpuriousDCInOutput ---
d = new_denoiser()
x = swift_random_signal(0.3, SR, 0.02, lambda t: np.sin(2*np.pi*440*t)*0.2)
out = d.process_buffer(x)
mean = float(np.mean(out[2000:]))
check("testNoSpuriousDCInOutput", abs(mean) < 0.02, f"输出均值 = {mean:+.5f}（阈值 < 0.02）")

# --- testPreservesSpeechContent ---
d = new_denoiser()
d.process_buffer(swift_random_signal(0.6, SR, 0.08, lambda t: 0.0))
def syllabic(t):
    env = 0.5*(1.0+np.sin(2*np.pi*4.0*t))
    return env*(0.30*np.sin(2*np.pi*220*t)+0.15*np.sin(2*np.pi*440*t)+0.08*np.sin(2*np.pi*880*t))
speech = swift_random_signal(1.0, SR, 0.08, syllabic)
out = d.process_buffer(speech)
st = int(0.2*SR)
i_r, o_r = rms(speech[st:]), rms(out[st:])
check("testPreservesSpeechContent", o_r > i_r * 0.3,
      f"语音 RMS {i_r:.5f} → {o_r:.5f}（阈值 > {i_r*0.3:.5f}，保留 {o_r/i_r*100:.1f}%）")

# --- testSuppressesStationaryTone ---
d = new_denoiser()
d.process_buffer(swift_random_signal(0.6, SR, 0.02, lambda t: 0.0))
tone = swift_random_signal(1.0, SR, 0.02, lambda t: np.sin(2*np.pi*300*t)*0.4)
out = d.process_buffer(tone)
st = int(0.4*SR)
i_r, o_r = rms(tone[st:]), rms(out[st:])
check("testSuppressesStationaryTone", o_r < i_r * 0.5,
      f"纯音 RMS {i_r:.5f} → {o_r:.5f}（阈值 < {i_r*0.5:.5f}，压制 {o_r/i_r*100:.1f}%）")

# --- testResetRestoresLearningState ---
d = new_denoiser()
d.process_buffer(np.full(4800, 0.05))
was = d.is_learning
d.reset()
check("testResetRestoresLearningState", (not was) and d.is_learning,
      f"处理前 learning={was}，reset 后 learning={d.is_learning}")

# --- testPerfectReconstructionWithUnityGain ---
d = new_denoiser()
d.smoothed_gain = np.ones(vd.N_BINS)   # 见下方说明
class UnityPassthrough(vd.Denoiser):
    def _compute_gain(self, power):
        self.gain = np.ones(vd.N_BINS)
        self.smoothed_gain = np.ones(vd.N_BINS)
d = UnityPassthrough()
n = 24000
t = np.arange(n)/SR
x = 0.4*np.sin(2*np.pi*440*t) + 0.2*np.sin(2*np.pi*1330*t)
out = d.process_buffer(x)
maxerr = float(np.max(np.abs(out - x)))
check("testPerfectReconstructionWithUnityGain", maxerr < 1e-3, f"最大误差 = {maxerr:.3e}（阈值 < 1e-3）")

# --- testOutputIsTimeAlignedWithInput ---
d = UnityPassthrough()
n = 16000
t = np.arange(n)/SR
x = 0.5*np.sin(2*np.pi*700*t)
out = d.process_buffer(x)
direct = float(np.mean(np.abs(out[1000:n-1000] - x[1000:n-1000])))
worst_shift_ok = True
worst = None
for s in [1, 4, 16, -1, -4, -16]:
    idx = np.arange(1000, n-1000) + s
    m = (idx >= 0) & (idx < n)
    e = float(np.mean(np.abs(out[1000:n-1000][m] - x[idx[m]])))
    if e <= direct:
        worst_shift_ok = False
        worst = (s, e, direct)
check("testOutputIsTimeAlignedWithInput", worst_shift_ok,
      f"直接对齐误差 {direct:.3e}，无平移更优" if worst_shift_ok else f"偏移 {worst[0]} 更好：{worst[1]:.3e} < {worst[2]:.3e}")

print()
print("=" * 70)
passed = sum(1 for _, c, _ in results if c)
total = len(results)
print(f"预测结果：{passed}/{total} 会通过")
for name, c, _ in results:
    if not c:
        print(f"  ⚠️  预计失败：{name} —— 需要调整实现或阈值")
print("=" * 70)
raise SystemExit(0 if passed == total else 1)
