import Foundation
import AVFoundation

/// 音频会话配置：统一处理 iOS 上的录音权限、采样率、扬声器路由。
enum AudioSessionConfigurator {
    static let sampleRate: Double = 48_000

    /// 请求麦克风权限。
    /// - Returns: 是否已授权
    static func requestMicrophonePermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
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

    /// 配置会话用于「麦克风采集 + 处理后播放」。
    ///
    /// - Parameter allowBluetooth: 是否允许蓝牙耳机（延迟较高，但可以戴着耳机实时听效果）
    /// - Parameter voiceChatMode: 是否使用 `.voiceChat` 模式。
    ///   Apple 的硬件语音处理单元（AEC + AGC + 硬件降噪）**只在 `.voiceChat` 模式下生效**，
    ///   这是降噪效果的最大变量，必须默认开启。
    static func configure(allowBluetooth: Bool, voiceChatMode: Bool = true) throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .defaultToSpeaker]
        if allowBluetooth {
            options.insert(.allowBluetooth)
        }
        let mode: AVAudioSession.Mode = voiceChatMode ? .voiceChat : .measurement
        try session.setCategory(.playAndRecord, mode: mode, options: options)
        try session.setPreferredSampleRate(sampleRate)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// 配置会话用于「只采集不外放」（避免回授）。
    ///
    /// 仍然使用 `.voiceChat` 模式以启用硬件语音处理。
    static func configureForCaptureOnly(voiceChatMode: Bool = true) throws {
        let session = AVAudioSession.sharedInstance()
        let mode: AVAudioSession.Mode = voiceChatMode ? .voiceChat : .measurement
        try session.setCategory(.record, mode: mode, options: [])
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
