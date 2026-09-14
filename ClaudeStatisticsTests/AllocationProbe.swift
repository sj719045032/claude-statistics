import Foundation

/// Live bytes in the process allocator. Unlike a physical-footprint delta this
/// is not hidden by malloc reusing pages another test freed, so it is stable
/// inside the shared XCTest host.
enum AllocationProbe {
    static func liveBytes() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    /// Bytes still live when `work` returns. Autoreleased objects it piled up
    /// count, because nothing drains them until the caller's pool pops — which
    /// is exactly the failure mode worth catching: a "chunked" reader whose
    /// chunks are all still alive at the end of the parse.
    static func liveAtReturn(of work: () -> Void) -> Int {
        let before = liveBytes()
        work()
        return liveBytes() - before
    }
}
