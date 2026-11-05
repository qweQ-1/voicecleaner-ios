# AI 协作规则

- 本项目用 [ios-ci-workflows](https://github.com/wenjinliuu/ios-ci-workflows) 编译和测试；本地不跑 Xcode。改完代码 push，读 Build & Test 的测试报告再修。
- 新功能必须带测试；能用逻辑测试验证的不写成 UI 测试；删测试、改断言的预期值都要在提交里写明理由。
- 部署只走 git → CI。
- 更多细节见 ios-ci-workflows 的 Skill：skills/ios-ci-workflows/SKILL.md。

## 本项目约定

- **降噪算法放在 `VoiceCleaner/Core/Denoise/`**，是纯 Swift、零依赖的值类型，方便用逻辑测试逐帧验证；渲染和输入只读取物理状态，不反向写入。
- **`VoiceCleaner/Core/DSP/FFT.swift` 是自研 FFT**，不用 Accelerate 的 `vDSP_fft_zrip`（real-FFT 打包规则易错）。改动它必须同步更新 `FFTTests`。
- **实时线程不做堆分配**：`SpectralDenoiser` 和 `AudioRingBuffer` 的所有缓冲区在 `init` 时预分配，`process` 只做原地运算。
- **降噪运算不能放在音频渲染回调里**：引擎用独立的处理线程 + `DispatchSourceTimer` 驱动，掉队时宁可欠载补零也不能阻塞渲染线程（否则爆音）。
- **Apple 硬件语音处理必须在 `installTap` 之前启用**：见 `NoiseSuppressionEngine.enableHardwareVoiceProcessing()`。会话必须用 `.voiceChat` 模式，否则系统 DSP 链路不生效。
- **STFT 重叠相加的时序约定**：第 m 步消费 hop 个样本，帧覆盖 `[m*hop - frameSize, m*hop)`，输出该帧的前一个 hop。改动 `SpectralDenoiser.process` 时务必保持这个对齐，否则会出现延迟或回声。
