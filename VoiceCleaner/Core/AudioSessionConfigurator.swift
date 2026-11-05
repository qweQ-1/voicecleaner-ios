import Foundation
import AVFoundation

/// 音频会话配置：统一处理 iOS 上的录音权限、采样率、扬声器路由。
///
/// 关于 `.voiceChat` 模式：Apple 的硬件语音处理单元（AEC + AGC + 硬件降噪）
/// 只在 `.voiceChat` 模式下生效，这是降噪效果的最大变量，所以默认开启。
enum AudioSessionConfigurator {
    static let sampleRate: Double = 48_000

    /// 请求麦克风权限。
    ///
    /// 统一走 completion-handler 形式 + continuation，
    /// 不依赖 ObjC importer 自动生成 async 版本（跨 SDK 版本更稳）。
    /// - Returns: 是否已授权
    static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    static var permissionGranted: Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        } else {
            return AVAudioSession.sharedInstance().recordPermission == .granted
        }
    }

    /// 配置会话。
    ///
    /// 一律使用 `.playAndRecord`：即使当前不外放（没有连接输出节点），
    /// 扬声器也是静音的，同时又能满足硬件语音处理单元对 category 的要求。
    ///
    /// - Parameter voiceChatMode: 是否启用 `.voiceChat` 模式（硬件语音处理单位生效的前提）
    static func configure(voiceChatMode: Bool = true) throws {
        let session = AVAudioSession.sharedInstance()
        let mode: AVAudioSession.Mode = voiceChatMode ? .voiceChat : .measurement
        // 不用 .allowBluetoothA2DP：它和 .voiceChat 组合会改变路由行为，
        // 而本项目不需要 A2DP 播放能力。
        try session.setCategory(.playAndRecord, mode: mode, options: [.defaultToSpeaker])
        try session.setPreferredSampleRate(sampleRate)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 实际可用的输入采样率（真机麦克风通常不是请求的 48k）
    static var actualSampleRate: Double {
        AVAudioSession.sharedInstance().sampleRate
    }
}
