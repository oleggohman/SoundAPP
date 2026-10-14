import Foundation
import Synchronization

/// Single-producer / single-consumer lock-free ring buffer of interleaved floats.
///
/// The input device and the output device run on separate Core Audio clocks, so
/// the capture callback writes here and the render callback reads. Nothing in
/// either path allocates or locks.
public final class FloatRingBuffer: @unchecked Sendable {
    private var storage: UnsafeMutablePointer<Float>
    private let capacity: Int                 // in frames
    private let channels: Int
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    public private(set) var overruns = 0
    public private(set) var underruns = 0

    public init(frames: Int, channels: Int) {
        self.capacity = max(frames, 2)
        self.channels = max(channels, 1)
        self.storage = .allocate(capacity: self.capacity * self.channels)
        self.storage.initialize(repeating: 0, count: self.capacity * self.channels)
    }

    deinit {
        storage.deinitialize(count: capacity * channels)
        storage.deallocate()
    }

    public var framesAvailable: Int {
        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .relaxed)
        return w >= r ? w - r : capacity - r + w
    }

    public var framesFree: Int { capacity - framesAvailable - 1 }

    public func reset() {
        writeIndex.store(0, ordering: .releasing)
        readIndex.store(0, ordering: .releasing)
        storage.update(repeating: 0, count: capacity * channels)
        overruns = 0
        underruns = 0
    }

    /// Producer side. Drops the block and counts an overrun when there is no room.
    @discardableResult
    public func write(_ source: UnsafePointer<Float>, frames: Int) -> Bool {
        guard frames <= framesFree else { overruns += 1; return false }
        var w = writeIndex.load(ordering: .relaxed)
        var remaining = frames
        var offset = 0
        while remaining > 0 {
            let chunk = min(remaining, capacity - w)
            storage.advanced(by: w * channels)
                .update(from: source.advanced(by: offset * channels), count: chunk * channels)
            w = (w + chunk) % capacity
            offset += chunk
            remaining -= chunk
        }
        writeIndex.store(w, ordering: .releasing)
        return true
    }

    /// Consumer side. Fills the tail with silence and counts an underrun when short.
    @discardableResult
    public func read(into destination: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        let available = framesAvailable
        let toRead = min(frames, available)
        if toRead < frames {
            underruns += 1
            destination.advanced(by: toRead * channels)
                .update(repeating: 0, count: (frames - toRead) * channels)
        }
        guard toRead > 0 else { return false }
        var r = readIndex.load(ordering: .relaxed)
        var remaining = toRead
        var offset = 0
        while remaining > 0 {
            let chunk = min(remaining, capacity - r)
            destination.advanced(by: offset * channels)
                .update(from: storage.advanced(by: r * channels), count: chunk * channels)
            r = (r + chunk) % capacity
            offset += chunk
            remaining -= chunk
        }
        readIndex.store(r, ordering: .releasing)
        return toRead == frames
    }
}
