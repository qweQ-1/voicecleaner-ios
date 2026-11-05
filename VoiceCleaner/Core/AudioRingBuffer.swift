import Foundation

/// 单生产者单消费者（SPSC）无锁环形缓冲区。
///
/// 用途：把「麦克风采集线程」产出的音频，安全地交给「渲染线程」消费。
/// - 生产者：`installTap` 的音频回调（写）
/// - 消费者：`AVAudioSourceNode` 的渲染回调（读）
///
/// 实现要点：
/// - 容量固定为 2 的幂，用位与代替取模。
/// - 读写索引在 ARM64 上是原子读写；生产者写完数据再更新 `writeIndex`，
///   消费者读完数据再更新 `readIndex`，依赖 ARM64 的顺序保证构成发布/订阅关系。
/// - **不分配内存**：初始化时一次性分配，运行时零堆分配，满足实时线程要求。
final class AudioRingBuffer {
    private let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>

    private var writeIndex: Int = 0
    private var readIndex: Int = 0

    init(capacity: Int) {
        precondition(capacity > 0 && (capacity & (capacity - 1)) == 0, "容量必须是 2 的幂")
        self.capacity = capacity
        self.mask = capacity - 1
        storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// 可读样本数
    var availableToRead: Int {
        writeIndex - readIndex
    }

    /// 可写空间（样本数）
    var availableToWrite: Int {
        capacity - (writeIndex - readIndex)
    }

    /// 写入样本。返回实际写入的数量（空间不足时截断）。
    /// - Note: 仅生产者线程调用。
    @discardableResult
    func write(_ samples: UnsafePointer<Float>, count: Int) -> Int {
        var written = 0
        while written < count {
            let space = capacity - (writeIndex - readIndex)
            if space == 0 { break }
            let chunk = min(count - written, space)
            for i in 0..<chunk {
                storage[(writeIndex + i) & mask] = samples[i]
            }
            writeIndex += chunk
            written += chunk
        }
        return written
    }

    @discardableResult
    func write(_ samples: [Float]) -> Int {
        samples.withUnsafeBufferPointer { buf in
            write(buf.baseAddress!, count: buf.count)
        }
    }

    /// 读取样本到缓冲区。返回实际读取的数量。
    /// - Note: 仅消费者线程调用。
    @discardableResult
    func read(into output: UnsafeMutablePointer<Float>, count: Int) -> Int {
        var read = 0
        while read < count {
            let avail = writeIndex - readIndex
            if avail == 0 { break }
            let chunk = min(count - read, avail)
            for i in 0..<chunk {
                output[i] = storage[(readIndex + i) & mask]
            }
            readIndex += chunk
            read += chunk
        }
        return read
    }

    @discardableResult
    func read(into output: inout [Float], count: Int) -> Int {
        output.withUnsafeMutableBufferPointer { buf in
            read(into: buf.baseAddress!, count: count)
        }
    }

    /// 清空缓冲区（重置时调用）
    func reset() {
        readIndex = 0
        writeIndex = 0
    }
}
