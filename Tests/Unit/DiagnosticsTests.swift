import XCTest
@testable import VoiceCleaner

/// 启动诊断与错误建议的测试。
///
/// 为什么值得认真测：这两个类型是「用户点了没反应」和「开发者拿不到真机」之间
/// 唯一的桥。它们错了，排查就退化成猜。
final class DiagnosticsTests: XCTestCase {

    // MARK: - DiagnosticLog

    func testRecordsSuccessAndFailureEntries() {
        let log = DiagnosticLog()
        log.record("音频会话", "playAndRecord")
        log.failure("引擎 start()", "OSStatus -10875")

        XCTAssertEqual(log.entries.count, 2)
        XCTAssertFalse(log.entries[0].isFailure)
        XCTAssertTrue(log.entries[1].isFailure)
        XCTAssertTrue(log.hasFailure)
    }

    func testReportRendersOneLinePerEntryWithMarkers() {
        let log = DiagnosticLog()
        log.record("麦克风权限", "已授权")
        log.failure("输入格式", "0 Hz")

        let lines = log.report.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("✓"))
        XCTAssertTrue(lines[0].contains("麦克风权限"))
        XCTAssertTrue(lines[1].hasPrefix("✗"))
        XCTAssertTrue(lines[1].contains("0 Hz"))
    }

    func testEntryWithEmptyDetailFallsBackToStepName() {
        let log = DiagnosticLog()
        log.record("引擎")
        XCTAssertEqual(log.entries[0].line, "✓ 引擎")
    }

    func testClearRemovesEverything() {
        let log = DiagnosticLog()
        log.record("a")
        log.failure("b", "c")
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertFalse(log.hasFailure)
        XCTAssertEqual(log.report, "")
    }

    func testHasFailureIsFalseWhenAllSucceeded() {
        let log = DiagnosticLog()
        log.record("一")
        log.record("二", "正常")
        XCTAssertFalse(log.hasFailure)
    }

    // MARK: - AudioStartupAdvice

    /// 未授权时必须明确指向系统设置，而不是泛泛的"启动失败"。
    func testPermissionDeniedAdvicePointsToSettings() {
        let advice = AudioStartupAdvice.advice(
            for: EngineStartupError.microphonePermissionDenied,
            permissionGranted: false)

        XCTAssertTrue(advice.title.contains("权限"))
        XCTAssertTrue(advice.suggestion.contains("设置"))
        XCTAssertTrue(advice.suggestion.contains("麦克风"))
    }

    /// 权限看似正常但错误码是权限类时，也应给出权限建议。
    func testPermissionDeniedAdviceWorksEvenIfFlagIsStale() {
        let advice = AudioStartupAdvice.advice(
            for: EngineStartupError.microphonePermissionDenied,
            permissionGranted: true)
        XCTAssertTrue(advice.suggestion.contains("设置"))
    }

    /// 会话配置失败最常见的原因是别的 App 占着麦克风，建议里要点出来。
    func testSessionConfigurationAdviceMentionsOtherApps() {
        let advice = AudioStartupAdvice.advice(
            for: EngineStartupError.sessionConfigurationFailed("category 被拒绝"),
            permissionGranted: true)

        XCTAssertTrue(advice.suggestion.contains("通话") || advice.suggestion.contains("占用"))
        XCTAssertTrue(advice.suggestion.contains("category 被拒绝"), "原始细节要保留，便于定位")
    }

    /// 输入格式为 0 是权限之外的典型症状，建议里要带原始格式。
    func testInputUnavailableAdviceKeepsRawFormat() {
        let advice = AudioStartupAdvice.advice(
            for: EngineStartupError.inputUnavailable("0.0 Hz / 0 声道"),
            permissionGranted: true)

        XCTAssertTrue(advice.suggestion.contains("0.0 Hz / 0 声道"))
    }

    /// 引擎启动失败要提到硬件语音处理（这是自动降级后仍失败时的主因）。
    func testEngineStartAdviceMentionsHardwareVoiceProcessing() {
        let advice = AudioStartupAdvice.advice(
            for: EngineStartupError.engineStartFailed("kAudioUnitErr_FailedInitialization"),
            permissionGranted: true)

        XCTAssertEqual(advice.title, "音频引擎起不来")
        XCTAssertTrue(advice.suggestion.contains("硬件语音处理"))
    }

    /// 未知错误至少要把 domain / code 带出来，方便继续查。
    func testUnknownErrorSurfacesDomainAndCode() {
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800)
        let advice = AudioStartupAdvice.advice(for: error, permissionGranted: true)

        XCTAssertTrue(advice.suggestion.contains("AVFoundationErrorDomain"))
        XCTAssertTrue(advice.suggestion.contains("-11800"))
    }

    /// 权限标志为 false 但错误类型未知时，优先提示权限。
    func testUnknownErrorWithMissingPermissionPrefersPermissionAdvice() {
        let error = NSError(domain: "X", code: 1)
        let advice = AudioStartupAdvice.advice(for: error, permissionGranted: false)
        XCTAssertTrue(advice.suggestion.contains("设置"))
    }

    // MARK: - 错误描述

    func testEngineStartupErrorDescriptionsAreHumanReadable() {
        XCTAssertEqual(EngineStartupError.microphonePermissionDenied.errorDescription,
                       "麦克风权限未开启")
        XCTAssertEqual(
            EngineStartupError.inputUnavailable("0 Hz").errorDescription,
            "麦克风输入不可用：0 Hz")
        XCTAssertEqual(
            EngineStartupError.engineStartFailed("boom").errorDescription,
            "音频引擎启动失败：boom")
    }
}

// MARK: - 音频流看门狗

extension DiagnosticsTests {

    /// 启动后一直没有帧 → 必须告警。
    func testWatchdogWarnsWhenNoFramesArriveAfterThreshold() {
        XCTAssertTrue(AudioFlowWatchdog.shouldWarn(processedFrames: 0, runningSeconds: 2.5))
        XCTAssertTrue(AudioFlowWatchdog.shouldWarn(processedFrames: 0, runningSeconds: 2.0))
    }

    /// 阈值内不告警——正常启动 100ms 内就有第一帧，2 秒足够宽容。
    func testWatchdogStaysQuietBeforeThreshold() {
        XCTAssertFalse(AudioFlowWatchdog.shouldWarn(processedFrames: 0, runningSeconds: 1.9))
        XCTAssertFalse(AudioFlowWatchdog.shouldWarn(processedFrames: 0, runningSeconds: 0))
    }

    /// 只要有帧进来就绝不告警。
    func testWatchdogStaysQuietOnceFramesArrive() {
        XCTAssertFalse(AudioFlowWatchdog.shouldWarn(processedFrames: 1, runningSeconds: 100))
        XCTAssertFalse(AudioFlowWatchdog.shouldWarn(processedFrames: 5000, runningSeconds: 100))
    }

    /// 阈值可配置，且默认值符合"两秒"这个承诺。
    func testWatchdogThresholdIsConfigurable() {
        XCTAssertEqual(AudioFlowWatchdog.defaultThresholdSeconds, 2.0)
        XCTAssertTrue(AudioFlowWatchdog.shouldWarn(processedFrames: 0, runningSeconds: 0.5,
                                                   thresholdSeconds: 0.4))
        XCTAssertFalse(AudioFlowWatchdog.shouldWarn(processedFrames: 0, runningSeconds: 0.4,
                                                    thresholdSeconds: 0.5))
    }
}
