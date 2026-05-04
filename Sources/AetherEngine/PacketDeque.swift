import Foundation

/// FIFO buffer with O(1) front-removal, replacement for the
/// `[Element].removeFirst()` pattern used by the Atmos audio and
/// video drains. `Array.removeFirst()` is O(n) because it shifts
/// every remaining element down one slot; at typical Atmos rates
/// (24-60 fps video, ~30 audio packets/s) and a 384-element video
/// cap, that's ~10 000 element shifts per second of pure overhead.
///
/// This deque keeps a head index instead of compacting on every
/// pop. Storage compaction happens lazily when more than half of
/// the storage has been consumed past the head, bounded amortised
/// cost without wasting memory on a permanently growing buffer.
///
/// Not thread-safe on its own, every caller in the engine guards
/// the buffer with the existing `atmos*Lock` NSLock. The API mirrors
/// the Array methods we used before so the call sites stay readable.
struct PacketDeque<Element>: Sequence {
    private var storage: [Element] = []
    private var head: Int = 0

    var isEmpty: Bool { head >= storage.count }
    var count: Int { storage.count - head }

    mutating func append(_ element: Element) {
        storage.append(element)
    }

    /// Removes and returns the first element. Precondition: not empty.
    /// Mirrors `Array.removeFirst()` semantics so the previous call
    /// sites (which guard with `isEmpty` first) didn't have to grow
    /// extra `if let` ceremony.
    mutating func popFront() -> Element {
        precondition(head < storage.count, "popFront on empty PacketDeque")
        let element = storage[head]
        head += 1
        // Compact when most of the storage is consumed dead space
        // (head past the midpoint and at least 32 popped). Keeps
        // memory bounded without paying for compaction on every pop.
        if head >= 32 && head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
        return element
    }

    mutating func removeAll() {
        storage.removeAll()
        head = 0
    }

    func makeIterator() -> AnyIterator<Element> {
        var index = head
        let snapshot = storage
        return AnyIterator {
            guard index < snapshot.count else { return nil }
            let e = snapshot[index]
            index += 1
            return e
        }
    }
}
