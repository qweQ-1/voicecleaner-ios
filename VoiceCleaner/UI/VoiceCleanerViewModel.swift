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
    /// 默认用实时外放：这是唯一能把降噪音频「交给别的 App」的模式，
    /// 静音模式只处理不外放，用户点了会觉得「没反应」。
    @Published var mode: NoiseSuppressionEngine.OutputMode = .monitor
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
    private var stopObserver: NSObjectProtocol?

    init() {
        // **状态用推送，不用轮询。**
        // 轮询一旦没跑起来（视图生命周期提前触发 onDisappear、run loop 切到
        // tracking 模式等），界面就永远停在「开始降噪」：用户点了没反应，
        // 其实引擎已经启动成功——这次线上反馈踩的就是这个坑。
        engine.onStateChange = { [weak self] newState in
            self?.state = newState
        }

        // 统计定时器在 init 里就启动，不依赖任何视图生命周期回调
        startStatsTimer()

        // 退到后台时释放麦克风（系统本来也不允许后台录音）
        stopObserver = NotificationCenter.default.addObserver(
            forName: .voiceCleanerShouldStop,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isRunning else { return }
            self.engine.stop()
            self.stopProfileTimer()
            self.noAudioDetected = false
            self.runningSince = nil
        }
    }

    deinit {
        statsTimer?.invalidate()
        profileTimer?.invalidate()
        if let observer = stopObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

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
    }

    /// 彻底停止并释放（视图消失时不再调用它——那会把统计定时器一起弄死，
    /// 界面从此不再刷新。退到后台的释放走通知观察者。）
    func shutdown() {
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
            // 立即同步状态：即便引擎回调有任何延迟，按钮也必须马上变成「停止」
            state = .learningNoise
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
        // 用 .common 模式：scheduledTimer 默认只在 .default 模式跑，
        // 用户按住/拖动滚动视图时 run loop 切到 .tracking，定时器会暂停。
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
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
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    private func startProfileTimer() {
        profileTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.noiseProfile = self.engine.noiseProfileSnapshot()
        }
        RunLoop.main.add(timer, forMode: .common)
        profileTimer = timer
    }

    private func stopProfileTimer() {
        profileTimer?.invalidate()
        profileTimer = nil
    }
}
