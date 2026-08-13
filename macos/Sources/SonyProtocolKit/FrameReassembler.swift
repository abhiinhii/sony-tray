import Foundation

/// Accumulates raw socket bytes and yields complete decoded frames.
public final class FrameReassembler {
    private var buffer = [UInt8]()
    private var frames = [Frame]()

    public init() {}

    public func feed<C: Collection>(_ chunk: C) where C.Element == UInt8 {
        buffer.append(contentsOf: chunk)
        while true {
            guard let start = buffer.firstIndex(of: Framing.startMarker) else {
                buffer.removeAll(keepingCapacity: true)
                return
            }
            guard let end = buffer[start...].firstIndex(of: Framing.endMarker) else {
                // keep from start marker onward, wait for more bytes
                buffer.removeFirst(start)
                return
            }
            let candidate = Array(buffer[start...end])
            buffer.removeFirst(end + 1)
            if let frame = Framing.tryUnpack(candidate) {
                frames.append(frame)
            }
            // else: corrupt between markers — drop and continue scanning
        }
    }

    public func tryDequeue() -> Frame? {
        frames.isEmpty ? nil : frames.removeFirst()
    }
}
