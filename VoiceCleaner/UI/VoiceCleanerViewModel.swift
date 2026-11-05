import Foundation
import SwiftUI
import Combine
import UIKit

/// 音频接管路线。
///
/// iPhone 上**没有**系统级虚拟麦克风：Apple 的 AudioDriverKit 官方只支持
/// macOS 和 M 芯片 iPadOS，且需要单独向 Apple 申请 `com.apple.developer.driverkit` 权限。
/// 因此 iOS 上唯一能落地的路线是「外放接管」——
/// 降噪后的音频从扬声器播放，由目标 App 的麦克风拾取。
enum AudioRoute: String {
    /// 外放接管：降噪后从扬声器播放，目标 App 拾取
    case speakerRelay

    var displayName: String {
        switch self {
        case .speakerRelay: return "外放接管"
        }
    }
}

/// 界面状态容器。
final class VoiceCleanerViewModel: ObservableObject {
    @Published private(set) var state: NoiseSuppressionEngine.State = .idle
    @Published private(set) var stats = EngineStats()
    @Published var mode: NoiseSuppressionEngine.OutputMode = .silent
    @Published var strength: Float = 0.5
    @Published private(set) var noiseProfile: [Float] = []
    @Published private(set) var route: AudioRoute = .speakerRelay
    @Published private(set) var hasMicrophonePermission = false
    /// 是否启用 Apple 硬件语音处理单元（AEC + AGC + 硬件降噪）
    @Published var useHardwareVoiceProcessing = true

    /// 启动失败信息。
    ///
    /// **单独存一份**，不跟 `state` 走：轮询定时器会持续把 `state` 同步成
    /// 引擎状态，早先的写法里错误刚写进 `state` 就被同步覆盖掉，
    /// 界面表现是「点开始完全没反应」——正是这个坑。
    @Published private(set) var startupFailure: AudioStartupAdvice.Advice?
    /// 启动成功后是否发生了自动降级（硬件语音处理不可用）
    @Published private(set) var didFallBack = false
    /// 引擎已启动但迟迟收不到麦克风数据
    @Published private(set) var noAudioDetected = false

    private var runningSince: Date?

    /// 引擎内部记录的分步日志
    var diagnosticLog: DiagnosticLog { engine.log }

    private let engine = NoiseSuppressionEngine()
    private var statsTimer: Timer?
    private var profileTimer: Timer?

    var isRunning: Bool {
        switch state {
        case .idle, .failed: return false
        case .learningNoise, .running: return true
        }
    }

    var isLearning: Bool {
        if case .learningNoise = state { return true }
        return false
    }

    var learningProgress: Double {
        let total = max(SpectralDenoiser.Configuration().noiseLearningFrames, 1)
        return min(Double(stats.processedFrames) / Double(total), 1)
    }

    var statusText: String {
        switch state {
        case .idle: return "未启动"
        case .learningNoise: return "学习环境噪声中"
        case .running: return "降噪运行中"
        case .failed(let message): return "出错：\(message)"
        }
    }

    var statusColor: Color {
        switch state {
        case .idle: return .gray
        case .learningNoise: return .blue
        case .running: return .green
        case .failed: return .red
        }
    }

    // MARK: - 生命周期

    func bootstrap() async {
        hasMicrophonePermission = AudioSessionConfigurator.permissionGranted
        if !hasMicrophonePermission {
            hasMicrophonePermission = await AudioSessionConfigurator.requestMicrophonePermission()
        }
        startStatsTimer()
    }

    func shutdown() {
        statsTimer?.invalidate()
        statsTimer = nil
        profileTimer?.invalidate()
        profileTimer = nil
        engine.stop()
    }

    // MARK: - 控制

    func toggle() {
        if isRunning {
            engine.stop()
            stopProfileTimer()
            didFallBack = false
            startupFailure = nil
            noAudioDetected = false
            runningSince = nil
            return
        }

        do {
            try engine.start(mode: mode, useHardwareVoiceProcessing: useHardwareVoiceProcessing)
            startupFailure = nil
            didFallBack = engine.hardwareVoiceProcessingFallback
            runningSince = Date()
            noAudioDetected = false
            engine.setStrength(strength)
            startProfileTimer()
        } catch {
            // 权限可能在系统设置里被改过，失败时重新读一次真实状态
            hasMicrophonePermission = AudioSessionConfigurator.permissionGranted
            startupFailure = AudioStartupAdvice.advice(for: error,
                                                       permissionGranted: hasMicrophonePermission)
            state = .failed(error.localizedDescription)
        }
    }

    func relearn() {
        engine.relearnNoise()
    }

    func applyStrength(_ value: Float) {
        engine.setStrength(value)
    }

    /// 重新申请一次麦克风权限（用户从系统设置回来后调用）
    func refreshPermission() async {
        hasMicrophonePermission = AudioSessionConfigurator.permissionGranted
        if !hasMicrophonePermission {
            hasMicrophonePermission = await AudioSessionConfigurator.requestMicrophonePermission()
        }
    }

    /// 跳转到系统的本 App 设置页
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func dismissFailure() {
        startupFailure = nil
    }

    var diagnosticReport: String {
        diagnosticLog.report
    }

    // MARK: - 统计刷新

    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let newStats = self.engine.stats
            self.stats = newStats
            // 注意：这里只能同步引擎状态，**不要**动 startupFailure，
            // 否则失败信息会在 100ms 内被冲掉，表现为「点了没反应」。
            self.state = self.engine.state

            // 看门狗：起来了却一帧都没处理 → 采集链路没真正跑起来
            if let since = self.runningSince, self.isRunning {
                let elapsed = Date().timeIntervalSince(since)
                if AudioFlowWatchdog.shouldWarn(processedFrames: newStats.processedFrames,
                                                runningSeconds: elapsed) {
                    self.noAudioDetected = true
                }
            }
        }
    }

    private func startProfileTimer() {
        profileTimer?.invalidate()
        profileTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.noiseProfile = self.engine.noiseProfileSnapshot()
        }
    }

    private func stopProfileTimer() {
        profileTimer?.invalidate()
        profileTimer = nil
    }
}
