import Foundation
import SwiftUI
import Combine

/// 音频接管路线。
///
/// - `systemDriver`：系统级虚拟麦克风（DriverKit 音频驱动扩展）。
///   若扩展已安装并被系统接受，可直接在其他 App 的麦克风列表里选中。
/// - `speakerRelay`：外放接管。降噪后的音频从扬声器播放，
///   由目标 App 的麦克风拾取。兼容性最好，但受房间声学影响。
enum AudioRoute: String, CaseIterable {
    case systemDriver
    case speakerRelay

    var displayName: String {
        switch self {
        case .systemDriver: return "系统驱动"
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

    private let engine = NoiseSuppressionEngine()
    private var statsTimer: Timer?
    private var profileTimer: Timer?

    var isRunning: Bool {
        switch state {
        case .idle: return false
        case .learningNoise, .running: return true
        case .failed: return false
        }
    }

    var isLearning: Bool {
        if case .learningNoise = state { return true }
        return false
    }

    var learningProgress: Double {
        // 噪声学习阶段大致占整个学习帧数的前 40%
        let total = Double(SpectralDenoiser.Configuration().noiseLearningFrames)
        guard total > 0 else { return 0 }
        let learned = Double(stats.noiseLearnCount * 0 + min(stats.processedFrames, Int(total)))
        return min(learned / total, 1)
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
        } else {
            do {
                try engine.start(mode: mode, useHardwareVoiceProcessing: useHardwareVoiceProcessing)
                engine.setStrength(strength)
                startProfileTimer()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func relearn() {
        engine.relearnNoise()
    }

    func applyStrength(_ value: Float) {
        engine.setStrength(value)
    }

    // MARK: - 统计刷新

    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.stats = self.engine.stats
            self.state = self.engine.state
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
