import Foundation
import Combine
import AVFoundation

/// 启动过程中某一步的记录。
struct DiagnosticEntry: Equatable, Identifiable {
    let id = UUID()
    let step: String
    let detail: String
    let isFailure: Bool
    let timestamp: Date

    var line: String {
        let mark = isFailure ? "✗" : "✓"
        let text = detail.isEmpty ? step : "\(step)：\(detail)"
        return "\(mark) \(text)"
    }
}

/// 启动诊断日志。
///
/// 存在的意义：iOS 上音频启动失败的原因五花八门（权限、会话冲突、机型不支持
/// 硬件语音处理、采样率为 0…），而开发者手上未必有同型号真机。
/// 把每一步的结果记下来显示在 App 里，用户截图就能定位问题——比"点了没反应"有用得多。
final class DiagnosticLog: ObservableObject {
    @Published private(set) var entries: [DiagnosticEntry] = []

    func record(_ step: String, _ detail: String = "") {
        append(step: step, detail: detail, isFailure: false)
    }

    func failure(_ step: String, _ detail: String) {
        append(step: step, detail: detail, isFailure: true)
    }

    private func append(step: String, detail: String, isFailure: Bool) {
        let entry = DiagnosticEntry(step: step, detail: detail,
                                    isFailure: isFailure, timestamp: Date())
        if Thread.isMainThread {
            entries.append(entry)
        } else {
            DispatchQueue.main.async { [weak self] in self?.entries.append(entry) }
        }
    }

    func clear() {
        if Thread.isMainThread {
            entries.removeAll()
        } else {
            DispatchQueue.main.async { [weak self] in self?.entries.removeAll() }
        }
    }

    /// 一行一条的可复制文本，用于反馈问题
    var report: String {
        entries.map { $0.line }.joined(separator: "\n")
    }

    var hasFailure: Bool {
        entries.contains { $0.isFailure }
    }
}

/// 音频启动相关的错误。
enum EngineStartupError: LocalizedError {
    case microphonePermissionDenied
    case sessionConfigurationFailed(String)
    case inputUnavailable(String)
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "麦克风权限未开启"
        case .sessionConfigurationFailed(let detail):
            return "音频会话配置失败：\(detail)"
        case .inputUnavailable(let detail):
            return "麦克风输入不可用：\(detail)"
        case .engineStartFailed(let detail):
            return "音频引擎启动失败：\(detail)"
        }
    }
}

/// 音频流看门狗。
///
/// 覆盖一种很隐蔽的失败：`engine.start()` 成功、界面显示"运行中"，
/// 但采集 tap 一次都没触发（会话在图里没有真正跑起来）。
/// 用户看到的是"点了没反应"，跟启动抛错的表现一模一样。
///
/// 纯函数，方便单元测试。
enum AudioFlowWatchdog {
    /// 默认容忍 2 秒：正常情况启动后 100ms 内就会有第一帧。
    static let defaultThresholdSeconds: Double = 2.0

    static func shouldWarn(processedFrames: Int,
                           runningSeconds: Double,
                           thresholdSeconds: Double = defaultThresholdSeconds) -> Bool {
        processedFrames <= 0 && runningSeconds >= thresholdSeconds
    }
}

/// 把底层错误翻译成「人能看懂 + 知道下一步做什么」的说明。
///
/// 纯函数，方便单元测试覆盖各种错误码对应的建议。
enum AudioStartupAdvice {

    struct Advice: Equatable {
        let title: String
        let suggestion: String
    }

    /// 根据错误与当前权限状态给出建议。
    static func advice(for error: Error, permissionGranted: Bool) -> Advice {
        if let engineError = error as? EngineStartupError {
            switch engineError {
            case .microphonePermissionDenied:
                return Advice(
                    title: "需要麦克风权限",
                    suggestion: "去「设置 → 隐私与安全性 → 麦克风」打开「净声」的开关，然后回到 App 重新点开始。")
            case .sessionConfigurationFailed(let detail):
                return Advice(
                    title: "音频被占用或配置被拒绝",
                    suggestion: "如果有其他 App 正在通话或录音（微信语音、录音机、相机），先退掉它们再试。详情：\(detail)")
            case .inputUnavailable(let detail):
                return Advice(
                    title: "读不到麦克风输入",
                    suggestion: "先确认没插着被系统禁用的外接设备；再试一次。若一直失败，把下面的诊断信息发我。详情：\(detail)")
            case .engineStartFailed(let detail):
                return Advice(
                    title: "音频引擎起不来",
                    suggestion: "多半是本机不支持硬件语音处理链路，或采样率被外接设备改成了非常规值。详情：\(detail)")
            }
        }

        if !permissionGranted {
            return Advice(
                title: "需要麦克风权限",
                suggestion: "去「设置 → 隐私与安全性 → 麦克风」打开「净声」的开关，然后回到 App 重新点开始。")
        }

        let ns = error as NSError
        return Advice(
            title: "启动失败",
            suggestion: "错误域 \(ns.domain)，代码 \(ns.code)。把下面的诊断信息发我，我来定位。")
    }
}
