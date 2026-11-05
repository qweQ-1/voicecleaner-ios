import XCTest
@testable import VoiceCleaner

/// 输出模式的顺序与命名测试。
///
/// 不是可有可无的细节：**只有 `.monitor` 能把降噪音频交给其他 App**
/// （靠扬声器外放、目标 App 麦克风拾取）。它必须排在第一位并被标为推荐，
/// 否则用户会选到 `.silent`——那样点了开始什么也听不到、也传不出去，
/// 表现和「功能坏了」完全一样。
final class OutputModeTests: XCTestCase {

    func testMonitorIsFirstBecauseItIsTheOnlyUsefulDefault() {
        XCTAssertEqual(NoiseSuppressionEngine.OutputMode.allCases.first, .monitor,
                       "实时外放必须排第一：它是唯一能把降噪音频交给其他 App 的模式")
    }

    func testAllCasesArePresent() {
        let cases = NoiseSuppressionEngine.OutputMode.allCases
        XCTAssertEqual(cases.count, 3)
        XCTAssertTrue(cases.contains(.monitor))
        XCTAssertTrue(cases.contains(.silent))
        XCTAssertTrue(cases.contains(.record))
    }

    func testEveryModeHasNonEmptyDisplayName() {
        for mode in NoiseSuppressionEngine.OutputMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty, "\(mode.rawValue) 缺少显示名")
        }
    }

    /// 推荐标记要在名字里体现，用户才知道该选哪个。
    func testMonitorDisplayNameMarksItAsRecommended() {
        XCTAssertTrue(NoiseSuppressionEngine.OutputMode.monitor.displayName.contains("推荐"))
    }

    /// 静音模式的名字要让人预期"听不到声音"，避免误判成故障。
    func testSilentDisplayNameSetsExpectation() {
        XCTAssertTrue(NoiseSuppressionEngine.OutputMode.silent.displayName.contains("静音"))
    }

    /// rawValue 被用作持久化/日志键，改动要慎重，这里锁住。
    func testRawValuesAreStable() {
        XCTAssertEqual(NoiseSuppressionEngine.OutputMode.monitor.rawValue, "monitor")
        XCTAssertEqual(NoiseSuppressionEngine.OutputMode.silent.rawValue, "silent")
        XCTAssertEqual(NoiseSuppressionEngine.OutputMode.record.rawValue, "record")
    }
}
