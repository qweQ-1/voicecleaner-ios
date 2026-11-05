import XCTest
@testable import VoiceCleaner

/// 环形缓冲区测试。
///
/// 这是麦克风线程与处理线程之间的通道，一旦读写指针逻辑写错，
/// 表现出来是音频断续、爆音或延迟累积。
final class AudioRingBufferTests: XCTestCase {

    func testWriteThenReadReturnsSameSamples() {
        let buffer = AudioRingBuffer(capacity: 16)
        let input: [Float] = [1, 2, 3, 4, 5]
        let written = buffer.write(input)
        XCTAssertEqual(written, 5)

        var output = [Float](repeating: 0, count: 5)
        let read = buffer.read(into: &output, count: 5)
        XCTAssertEqual(read, 5)
        XCTAssertEqual(output, input)
    }

    func testReadsInOrderAcrossWrapAround() {
        let buffer = AudioRingBuffer(capacity: 8)
        // 先写 6 个，读走 6 个，读指针回到起点附近
        _ = buffer.write([1, 2, 3, 4, 5, 6])
        var tmp = [Float](repeating: 0, count: 6)
        _ = buffer.read(into: &tmp, count: 6)

        // 再写 8 个（跨过环尾），再读回来，顺序必须保持
        let second: [Float] = [7, 8, 9, 10, 11, 12, 13, 14]
        XCTAssertEqual(buffer.write(second), 8)

        var out = [Float](repeating: 0, count: 8)
        XCTAssertEqual(buffer.read(into: &out, count: 8), 8)
        XCTAssertEqual(out, second)
    }

    func testWriteTruncatesWhenFull() {
        let buffer = AudioRingBuffer(capacity: 8)
        let written = buffer.write([Float](repeating: 1, count: 20))
        XCTAssertEqual(written, 8, "空间不足时应截断而不是崩溃")
        XCTAssertEqual(buffer.availableToWrite, 0)
    }

    func testReadReturnsZeroWhenEmpty() {
        let buffer = AudioRingBuffer(capacity: 8)
        var out = [Float](repeating: 0, count: 4)
        XCTAssertEqual(buffer.read(into: &out, count: 4), 0)
    }

    func testAvailableCountsTrackData() {
        let buffer = AudioRingBuffer(capacity: 16)
        XCTAssertEqual(buffer.availableToRead, 0)
        _ = buffer.write([1, 2, 3])
        XCTAssertEqual(buffer.availableToRead, 3)
        var out = [Float](repeating: 0, count: 3)
        _ = buffer.read(into: &out, count: 3)
        XCTAssertEqual(buffer.availableToRead, 0)
    }

    func testResetClearsData() {
        let buffer = AudioRingBuffer(capacity: 16)
        _ = buffer.write([1, 2, 3])
        buffer.reset()
        XCTAssertEqual(buffer.availableToRead, 0)
        XCTAssertEqual(buffer.availableToWrite, 16)
    }

    /// 大量往复读写后，索引不能错乱。
    func testSustainedReadWriteStaysConsistent() {
        let buffer = AudioRingBuffer(capacity: 1024)
        var counter: Float = 0
        for _ in 0..<2000 {
            let chunk = [Float](repeating: counter, count: 8)
            _ = buffer.write(chunk)
            var out = [Float](repeating: 0, count: 8)
            let read = buffer.read(into: &out, count: 8)
            if read == 8 {
                for value in out {
                    XCTAssertEqual(value, counter)
                }
            }
            counter += 1
        }
    }
}
