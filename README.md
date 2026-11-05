# 净声 VoiceCleaner

iOS 实时降噪 App：采集麦克风 → 实时降噪 → 输出，供其他需要用麦克风的软件使用。

---

## 先说最重要的一件事

**iPhone 上做不到「系统级虚拟麦克风」。**

这不是工程难度问题，是平台限制。我查了 Apple 官方文档并逐条核实：

| 候选方案 | 结论 | 依据 |
| --- | --- | --- |
| DriverKit 音频驱动（虚拟麦克风设备） | **iOS 上不存在** | AudioDriverKit 文档原文："available on macOS for Intel and Apple Silicon devices, and on **iPadOS for devices with an M-series processor**" —— 只有 macOS 和 M 芯片 iPadOS，**没有 iOS** |
| DriverKit 权限 | 个人账号拿不到 | `com.apple.developer.driverkit` 必须向 Apple 单独申请（developer.apple.com/system-extensions/），人工审批并绑定开发团队；App 还需 System Extension capability |
| `requestMicrophoneInjectionPermission`（iOS 26） | **不能用于此目的** | 文档定义为 "add audio to **calls**"，是给无障碍类 App 向 FaceTime 通话注入合成语音用的，不是往任意 App 的麦克风输入注入 |
| 第三方 App 内降噪 | ✅ 可行 | `AVAudioEngine` + 自研 DSP |

所以本 App 采取两条路线，**能落地的都做了，做不到的明确说明**：

1. **App 内实时降噪**（主力）——采集、降噪、外放/录制，质量可验证。
2. **外放接管**（让别的 App 用上）——降噪后的音频从扬声器播放，目标 App 的麦克风拾取。
   这是 iOS 上唯一可行的「传给别的软件」路线，代价是受房间声学影响。

---

## 降噪是怎么做的

两条链路叠加，这是效果好坏的关键：

### 1. Apple 硬件语音处理单元（免费的大幅增益）

```swift
try inputNode.setVoiceProcessingEnabled(true)
```

由系统 DSP 提供 **AEC（回声消除）+ AGC（自动增益）+ 硬件降噪**，跑在硬件上，CPU 占用几乎为零，
效果远好于纯软件算法。

⚠️ 两个必须遵守的前提（都踩过坑）：
- 必须在 `installTap` **之前**调用，否则不生效；
- 音频会话必须用 `.voiceChat` 模式，`.measurement` 模式不会走这条链路。

### 2. 自研 STFT 谱降噪

`VoiceCleaner/Core/Denoise/SpectralDenoiser.swift`，纯 Swift、零依赖、可被逐帧单元测试：

1. **加窗分帧**：周期型 Hann 窗，512 点 / 跳 128（75% 重叠）
2. **噪声剖面估计**：持续跟踪每频点噪声功率，只在判定为非语音时更新，
   向上快（0.3）、向下慢（0.02）——噪声变响立刻跟上，变安静缓慢释放
3. **先验 SNR**：判决引导法（decision-directed）
   `SNR = α·|X(k-1)|²/λd(k) + (1-α)·max(|X(k)|²/λd(k) - 1, 0)`
4. **增益**：Wiener `G = SNR/(1+SNR)`，再做时间平滑 + 频率三点平滑 + 谱底下限，
   三层防「音乐噪声」（musical noise）
5. **WOLA 重叠相加重建**：输出除以累积窗平方和，抵消 75% 重叠的幅度起伏

---

## 离线验证（重要）

iSH 里没有 Swift 工具链，本地编译不了。所以我写了一份**逐点复刻 Swift 算法**的
Python 脚本 `Tools/verify_dsp.py`，用 numpy 在本地验证数学正确性：

```bash
python3 Tools/verify_dsp.py
```

它抓出过一个真实的时序缺陷：**第 m 步输出的是 `[m*hop - frame, m*hop - frame + hop)`，
比当时已消费的输入滞后 `frame - hop` 个样本**。`processBuffer` 没做这个对齐的话，
输出会整体错位 384 点——实时听起来是「延迟/回声」，而按噪声段测 RMS 时**根本发现不了**。

修正后的验证结果：

| 验证项 | 结果 |
| --- | --- |
| STFT 恒等重建（增益强制为 1） | 最大误差 **3.3e-16**，对齐偏移 **0 点** ✅ |
| 噪声压制 | 噪声段 **-21.9 dB** ✅ |
| 语音保留 | 保留 **68.8%** 能量（未被过度压制）✅ |
| 直流偏置抑制 | 残余 **0.025**（输入 0.3）✅ |

### Python 与 Swift 双眼交叉验证

`Tools/predict_swift_tests.py` 用 Python 复刻 `Tests/Unit/SpectralDenoiserTests.swift`
里每个测试的**信号生成方式（逐位对齐的 LCG）与断言阈值**，本地先预测一遍，
避免每轮 CI 等 8 分钟才发现阈值定错。

这套双轨验证抓出过一个只有 Swift 侧才有的 bug：

> Python 用 `np.fft.irfft`，它会自动从半谱补全 Hermitian 对称性；
> 而自研 FFT 输出的是完整复数谱，我只对前半 257 个频点施加了增益，
> 负频率半边保持原值 → 频谱不再共轭对称 → 逆变换取实部等价于
> 把增益平均成 `(g+1)/2`，降噪量**直接减半**。
> 症状是稳态纯音只被压到 54%，正好等于 `(谱底 0.08 + 1) / 2`。

**两边结果不一致本身就是信号** —— 这正是保留两套实现的意义。

同一套时序约定在 `Tests/Unit/SpectralDenoiserTests.swift` 里用
`testPerfectReconstructionWithUnityGain` 和 `testOutputIsTimeAlignedWithInput`
两个测试守住，CI 每次都会跑。

---

## 架构

```
VoiceCleaner/
├── Core/                        纯 Swift，无 UIKit/AVFoundation 依赖，可完整单测
│   ├── DSP/
│   │   ├── FFT.swift            自研基-2 迭代 FFT（不用 vDSP_fft_zrip，那套打包规则易错）
│   │   └── AudioMath.swift      RMS / dB / 软限幅 / 直流阻断
│   ├── Denoise/
│   │   └── SpectralDenoiser.swift  STFT + Wiener 降噪核心
│   ├── AudioRingBuffer.swift    SPSC 无锁环形缓冲（采集线程 ↔ 处理线程）
│   └── AudioSessionConfigurator.swift  会话、权限、采样率
├── Engine/
│   └── NoiseSuppressionEngine.swift  三线程模型 + 硬件语音处理 + 录制
└── UI/
    ├── ContentView.swift        SwiftUI 界面
    └── VoiceCleanerViewModel.swift
```

### 线程模型

降噪运算**绝不放在音频渲染回调里**——一旦超时就是爆音（underrun）。所以拆成三条线程：

```
麦克风采集线程 ──写──> inputRing ──读──> 处理线程（DispatchSourceTimer）
                                              │  跑 FFT + Wiener 增益
                                              ├──写──> outputRing ──读──> 渲染线程（外放）
                                              └──────> 音频文件（录制）
```

处理线程掉队时**宁可欠载补零**，也不阻塞渲染线程。所有缓冲区在 `init` 时预分配，
实时路径上零堆分配。

---

## 怎么用

1. 打开 App，允许麦克风权限
2. 选 **「实时监听」** 模式 → 点「开始降噪」
3. 前 ~1 秒保持安静，让算法学习环境噪声剖面（界面有进度条）
4. 切到目标 App（微信 / 钉钉 / 录音机），正常说话即可——麦克风会拾取扬声器里干净的语音
5. 可通过「降噪强度」滑块在「压得狠」和「保真」之间取舍

界面上的 **「Apple 硬件语音处理」** 开关控制第 1 条链路（需停止后重新开始才生效）。
如果真机不支持（如部分模拟器环境）会自动降级到纯软件降噪，不会崩。

---

## 已知限制（不藏着）

- **不能替换其他 App 的麦克风输入**——平台不允许，见文首说明
- 外放接管方案下，目标 App 仍会录到少量环境底噪（它自己也开了麦克风）
- 外放时若同时开着本 App 的监听，注意别和目标 App 形成回授；建议把手机放远一点或降低外放音量
- 后台不能持续录音（iOS 限制，除非声明后台音频模式），切到后台会自动停止

---

## 开发

CI 走 [ios-ci-workflows](https://github.com/wenjinliuu/ios-ci-workflows)，本地不跑 Xcode。
改完 push，读 Build & Test 的报告再修。

```bash
python3 Tools/verify_dsp.py        # 离线验证 DSP 数学（本地可跑）
python3 Scripts/make_app_icon.py   # 重新生成 App 图标
```

出包：Actions → **Unsigned IPA** → Run workflow，产物供 AltStore / SideStore / Sideloadly 自签安装。

约定见 [AGENTS.md](AGENTS.md)。
