import Foundation

// MARK: - Edge0TensorBytes

/// Raw payload bytes for one tensor or tensor row.
struct Edge0TensorBytes: Sendable {
    let location: Edge0TensorLocation
    let bytes: Data

    var byteCount: Int { bytes.count }
}

// MARK: - Edge0TensorStoreError

enum Edge0TensorStoreError: Error, Equatable, Sendable {
    case openFailed(path: String, errno: Int32)
    case closed(path: String)
    case readFailed(path: String, errno: Int32)
    case unexpectedEOF(path: String, expected: Int, received: Int)
    case offsetTooLarge(tensor: String)
    case invalidReadLength(tensor: String)
}

extension Edge0TensorStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .openFailed(let path, let code):
            return "Could not open \(path) (errno \(code))."
        case .closed(let path):
            return "The tensor store for \(path) is closed."
        case .readFailed(let path, let code):
            return "Reading \(path) failed (errno \(code))."
        case .unexpectedEOF(let path, let expected, let received):
            return "Reading \(path) hit EOF after \(received) of \(expected) bytes."
        case .offsetTooLarge(let tensor):
            return "Tensor '\(tensor)' has an offset that cannot be addressed."
        case .invalidReadLength(let tensor):
            return "Tensor '\(tensor)' has an invalid read length."
        }
    }
}

// MARK: - Edge0TensorStore
//
// Range-based tensor byte access. Implementations must not require the whole
// checkpoint to be resident: opening a 4+ GB model may only hold an fd.

protocol Edge0TensorStore: Sendable {
    func read(_ location: Edge0TensorLocation) async throws -> Edge0TensorBytes
    func close() async
}

// MARK: - Edge0Readahead

/// Pure page-range math for advisory readahead hints. The kernel hint
/// (`F_RDADVISE`) consumes file-byte ranges; rounding outward to page
/// boundaries keeps one expert slice from dragging in the neighbouring
/// expert's rows more than the page cache already does.
enum Edge0Readahead {
    /// Returns the page-aligned (offset, byteCount) covering the requested
    /// range, clamped to the file size, or nil when there is nothing to hint
    /// (empty range, zero-size file, or the range starts past EOF).
    static func alignedRange(
        offset: UInt64,
        count: Int,
        fileSize: UInt64,
        pageSize: UInt64
    ) -> (offset: UInt64, count: UInt64)? {
        guard count > 0, fileSize > 0, pageSize > 1 else { return nil }
        guard offset < fileSize else { return nil }
        let alignedOffset = offset & ~(pageSize - 1)
        let clampedEnd = min(offset + UInt64(count), fileSize)
        let alignedEnd = min((clampedEnd + pageSize - 1) & ~(pageSize - 1), fileSize)
        guard alignedEnd > alignedOffset else { return nil }
        return (alignedOffset, alignedEnd - alignedOffset)
    }
}

// MARK: - Edge0PreadFile

/// Explicit file-range reads over a single descriptor. `pread` is stateless,
/// so concurrent reads share the fd safely; `close()` is synchronized and
/// idempotent.
final class Edge0PreadFile: @unchecked Sendable {
    let path: String
    let size: UInt64

    private let fd: Int32
    private let lock = NSLock()
    private var isClosed = false

    init(path: String) throws {
        self.path = path
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else {
            throw Edge0TensorStoreError.openFailed(path: path, errno: errno)
        }
        self.fd = descriptor
        var info = stat()
        if fstat(descriptor, &info) == 0 {
            self.size = UInt64(max(0, info.st_size))
        } else {
            self.size = 0
        }
    }

    /// Reads exactly `count` bytes at `offset`, retrying interrupted reads
    /// and failing with a typed error on EOF.
    ///
    /// The destination block is allocated UNINITIALIZED and only handed to
    /// `Data` (zero-copy) after the read fully succeeds. `Data(count:)`
    /// guarantees zeroed contents, so the previous version paid a full memset
    /// over every expert slice before the `pread` immediately overwrote it —
    /// one redundant pass over all 270 MiB read per decoded token. Ownership
    /// transfers exactly once: every early throw deallocates explicitly, and
    /// the successful path attaches a deallocating finalizer.
    func read(offset: UInt64, count: Int) throws -> Data {
        if count == 0 { return Data() }
        guard count > 0 else {
            throw Edge0TensorStoreError.invalidReadLength(tensor: path)
        }
        guard offset <= UInt64(Int64.max) else {
            throw Edge0TensorStoreError.offsetTooLarge(tensor: path)
        }
        let descriptor = try openDescriptor()

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: count,
            // 16-byte aligned: these bytes become MLX weight buffers, and
            // malloc's minimum alignment is not guaranteed to satisfy the
            // vectorized loads the kernels use.
            alignment: 16
        )
        do {
            var total = 0
            while total < count {
                let request = count - total
                let result = pread(
                    descriptor,
                    buffer.advanced(by: total),
                    request,
                    off_t(offset) + off_t(total)
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw Edge0TensorStoreError.readFailed(path: path, errno: errno)
                }
                if result == 0 {
                    throw Edge0TensorStoreError.unexpectedEOF(
                        path: path,
                        expected: count,
                        received: total
                    )
                }
                total += result
            }
        } catch {
            buffer.deallocate()
            throw error
        }
        return Data(
            bytesNoCopy: buffer,
            count: count,
            deallocator: .custom { pointer, _ in
                pointer.deallocate()
            }
        )
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fd)
    }

    /// Issues a kernel readahead hint (Darwin `F_RDADVISE`) over one file
    /// byte range. Advisory only: the call never blocks meaningfully, never
    /// throws, and failure (including on kernels without the hint) is for
    /// the caller to ignore. Returns whether a syscall was issued; the read
    /// path must not depend on that value.
    @discardableResult
    func advise(offset: UInt64, count: Int) -> Bool {
        guard let range = Edge0Readahead.alignedRange(
            offset: offset,
            count: count,
            fileSize: size,
            pageSize: UInt64(sysconf(Int32(_SC_PAGESIZE)))
        ) else {
            return false
        }
        guard let descriptor = try? openDescriptor() else {
            return false
        }
        // The imported `radvisory` fields are not name-accessible in Swift,
        // so the struct is filled through its C-managed layout:
        // off_t radv_offset, off_t radv_count, int radv_flags.
        var advisory = radvisory()
        withUnsafeMutableBytes(of: &advisory) { raw in
            guard let base = raw.baseAddress else { return }
            let wordBytes = MemoryLayout<off_t>.size
            base.storeBytes(of: off_t(bitPattern: range.offset), as: off_t.self)
            base.storeBytes(
                of: off_t(bitPattern: range.count),
                toByteOffset: wordBytes,
                as: off_t.self
            )
            base.storeBytes(
                of: Int32(0),
                toByteOffset: 2 * wordBytes,
                as: Int32.self
            )
        }
        let result = withUnsafeMutablePointer(to: &advisory) { pointer in
            fcntl(descriptor, F_RDADVISE, pointer)
        }
        return result == 0
    }

    private func openDescriptor() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else {
            throw Edge0TensorStoreError.closed(path: path)
        }
        return fd
    }

    deinit {
        close()
    }
}

// MARK: - Edge0PreadTensorStore

/// Default range-read backend: explicit `pread` into controlled buffers.
/// This is deliberately the first implementation — a 4+ GB checkpoint opened
/// through this store adds no resident payload pages of its own.
final class Edge0PreadTensorStore: Edge0TensorStore, @unchecked Sendable {
    let shardName: String
    private let file: Edge0PreadFile

    init(path: String, shardName: String) throws {
        self.shardName = shardName
        self.file = try Edge0PreadFile(path: path)
    }

    func read(_ location: Edge0TensorLocation) async throws -> Edge0TensorBytes {
        try Task.checkCancellation()
        let bytes = try readSync(location)
        try Task.checkCancellation()
        return bytes
    }

    /// Blocking range read. Callers on Swift concurrency threads should go
    /// through `Edge0TensorStoreSet`, which dispatches I/O on a bounded queue.
    /// Synchronous sub-range read (see `Edge0TensorStoreSet.readSlice`).
    func readSync(
        _ location: Edge0TensorLocation,
        byteOffset: UInt64,
        byteLength: Int
    ) throws -> Data {
        try file.read(
            offset: location.payloadOffset + byteOffset,
            count: byteLength
        )
    }

    func readSync(_ location: Edge0TensorLocation) throws -> Edge0TensorBytes {
        guard location.byteCount <= UInt64(Int.max) else {
            throw Edge0TensorStoreError.invalidReadLength(tensor: location.name)
        }
        let data = try file.read(
            offset: location.payloadOffset,
            count: Int(location.byteCount)
        )
        return Edge0TensorBytes(location: location, bytes: data)
    }

    /// Kernel readahead hint over a tensor sub-range. Advisory only,
    /// synchronous, and never throws; see `Edge0PreadFile.advise`.
    @discardableResult
    func adviseSlice(
        _ location: Edge0TensorLocation,
        byteOffset: UInt64,
        byteLength: Int
    ) -> Bool {
        guard byteLength > 0,
              byteOffset + UInt64(byteLength) <= location.byteCount else {
            return false
        }
        return file.advise(
            offset: location.payloadOffset + byteOffset,
            count: byteLength
        )
    }

    func close() async {
        file.close()
    }
}

// MARK: - Edge0TensorStoreSet
//
// Maps shard names to stores and dispatches blocking reads onto a bounded
// concurrent queue so long file I/O does not occupy Swift concurrency
// threads. Concurrency is capped; no task-per-tensor fan-out.

struct Edge0TensorStoreReadStats: Sendable, Equatable {
    var configuredMaxConcurrentReads = 0
    var peakConcurrentReads = 0
    var activeReadsAtSnapshot = 0
    var totalReads = 0
}

final class Edge0TensorStoreSet: @unchecked Sendable {
    private let stores: [String: Edge0PreadTensorStore]
    private let directory: URL
    private let ioQueue: DispatchQueue
    private let ioLimit: DispatchSemaphore
    private let readLock = NSLock()
    private var readStats = Edge0TensorStoreReadStats()

    init(
        directory: URL,
        shardNames: [String],
        maxConcurrentReads: Int = 4
    ) throws {
        var stores: [String: Edge0PreadTensorStore] = [:]
        stores.reserveCapacity(shardNames.count)
        for shard in shardNames {
            let url = directory.appendingPathComponent(shard)
            stores[shard] = try Edge0PreadTensorStore(
                path: url.path,
                shardName: shard
            )
        }
        self.directory = directory
        self.stores = stores
        self.ioQueue = DispatchQueue(
            label: "com.ondevice.edge0.tensor-io",
            qos: .userInitiated,
            attributes: .concurrent
        )
        self.ioLimit = DispatchSemaphore(value: max(1, maxConcurrentReads))
        self.readStats.configuredMaxConcurrentReads = max(1, maxConcurrentReads)
    }

    /// Cheap concurrency counters: configured limit, observed peak, and
    /// active reads at the moment of the snapshot.
    func readStatistics() -> Edge0TensorStoreReadStats {
        readLock.lock()
        defer { readLock.unlock() }
        var stats = readStats
        stats.activeReadsAtSnapshot = readStats.activeReadsAtSnapshot
        return stats
    }

    func read(_ location: Edge0TensorLocation) async throws -> Edge0TensorBytes {
        try Task.checkCancellation()
        return try await readSlice(
            location,
            byteOffset: 0,
            byteLength: Int(location.byteCount)
        )
    }

    /// Reads an arbitrary byte sub-range of a tensor's payload. Used for
    /// per-expert slices inside stacked expert tensors: the slice of one
    /// first-axis row is contiguous, so `rowByteCount * index` addresses it
    /// without materializing the full tensor.
    func readSlice(
        _ location: Edge0TensorLocation,
        byteOffset: UInt64,
        byteLength: Int
    ) async throws -> Edge0TensorBytes {
        try Task.checkCancellation()
        guard let store = stores[location.shard] else {
            throw Edge0SafetensorsError.unknownShard(location.shard)
        }
        guard byteLength >= 0,
              byteOffset + UInt64(byteLength) <= location.byteCount else {
            throw Edge0TensorStoreError.invalidReadLength(tensor: location.name)
        }
        return try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                self.ioLimit.wait()
                self.readLock.lock()
                self.readStats.activeReadsAtSnapshot += 1
                self.readStats.totalReads += 1
                self.readStats.peakConcurrentReads = max(
                    self.readStats.peakConcurrentReads,
                    self.readStats.activeReadsAtSnapshot
                )
                self.readLock.unlock()
                defer {
                    self.readLock.lock()
                    self.readStats.activeReadsAtSnapshot -= 1
                    self.readLock.unlock()
                    self.ioLimit.signal()
                }
                do {
                    let bytes = try store.readSync(
                        location, byteOffset: byteOffset, byteLength: byteLength
                    )
                    continuation.resume(returning: Edge0TensorBytes(
                        location: location, bytes: bytes
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Kernel readahead hint for an expert slice about to be read via
    /// `readSlice`. Advisory only: synchronous `fcntl` (never throws),
    /// issued on the calling thread because a hint costs a few hundred
    /// nanoseconds and must not occupy the bounded I/O queue. Unknown
    /// shards and out-of-range slices are silently skipped.
    @discardableResult
    func adviseSlice(
        _ location: Edge0TensorLocation,
        byteOffset: UInt64,
        byteLength: Int
    ) -> Bool {
        guard let store = stores[location.shard] else {
            return false
        }
        return store.adviseSlice(
            location, byteOffset: byteOffset, byteLength: byteLength
        )
    }

    /// Deterministically closes every shard. Outstanding reads that already
    /// entered `read` complete first because `read` holds the store only for
    /// the duration of one synchronous pread; closed descriptors cause new
    /// reads to fail with a typed error.
    func closeAll() async {
        for store in stores.values {
            await store.close()
        }
    }
}
