import XCTest
import MLX
@testable import IOSLocalLLM

// MARK: - Edge0EngineLifecycleTests
//
// Executable runtime lifecycle over the real checkpoint: load, generate,
// cancel mid-generation, generate again, unload, double unload, load again.

final class Edge0EngineLifecycleTests: Edge0MLXTestCase {

    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [Edge0EngineEvent] = []

        func append(_ event: Edge0EngineEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        var snapshot: [Edge0EngineEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }

        var tokenText: String {
            snapshot.compactMap {
                if case .token(let text) = $0 { return text }
                return nil
            }.joined()
        }

        var completedTokens: Int? {
            for event in snapshot.reversed() {
                if case .completed(let tokens, _) = event { return tokens }
            }
            return nil
        }
    }

    func testEngineLifecycleWithRealCheckpoint() async throws {
        guard let modelDirectory = ProcessInfo.processInfo.environment[
            "EDGE0_8B_MODEL"
        ], !modelDirectory.isEmpty else {
            throw XCTSkip("Set EDGE0_8B_MODEL to a real Edge0-8B directory")
        }
        let directory = URL(fileURLWithPath: modelDirectory)
        let budget = Edge0MemoryBudget.resolve(
            availableBytes: UInt64.max / 4,
            ceilingBytes: 6_200_000_000
        )
        let engine = Edge0Engine()
        try await engine.load(configuration: .init(
            modelDirectory: directory,
            expertPoolSlots: 64,
            expertPoolBytes: max(budget.expertPoolBytes, 128 * 1_048_576)
        ))
        XCTAssertTrue(engine.isLoaded)

        let messages: [[String: String]] = [
            ["role": "system", "content": "You are a helpful assistant."],
            ["role": "user", "content": "The capital of France is"],
        ]

        // 1) Short greedy generation.
        let first = EventCollector()
        try await engine.generate(
            messages: messages,
            options: Edge0EngineOptions(maxTokens: 4),
            onEvent: { first.append($0) }
        )
        XCTAssertTrue(first.snapshot.contains(.started))
        XCTAssertEqual(first.completedTokens, 4)
        XCTAssertFalse(first.tokenText.isEmpty)

        // 2) Cancel mid-generation, then generate again.
        let cancelled = EventCollector()
        let task = Task {
            try await engine.generate(
                messages: messages,
                options: Edge0EngineOptions(maxTokens: 32),
                onEvent: { cancelled.append($0) }
            )
        }
        try await waitUntil("first token before cancel", timeout: 120) {
            cancelled.snapshot.contains {
                if case .token = $0 { return true }
                return false
            }
        }
        engine.cancel()
        _ = try? await task.value
        XCTAssertTrue(cancelled.snapshot.contains(.cancelled))

        let second = EventCollector()
        try await engine.generate(
            messages: messages,
            options: Edge0EngineOptions(maxTokens: 2),
            onEvent: { second.append($0) }
        )
        XCTAssertEqual(second.completedTokens, 2)

        // 3) Pool stays bounded and leases release.
        let stats = await engine.expertPoolStatistics()
        XCTAssertLessThanOrEqual(
            stats?.occupancySlots ?? 0,
            stats?.capacitySlots ?? 0
        )
        XCTAssertLessThanOrEqual(
            stats?.occupancyBytes ?? 0,
            stats?.capacityBytes ?? 0
        )

        // 4) Unload, double unload, load again.
        await engine.unload()
        XCTAssertFalse(engine.isLoaded)
        await engine.unload()
        try await engine.load(configuration: .init(
            modelDirectory: directory,
            expertPoolSlots: 64,
            expertPoolBytes: max(budget.expertPoolBytes, 128 * 1_048_576)
        ))
        let third = EventCollector()
        try await engine.generate(
            messages: messages,
            options: Edge0EngineOptions(maxTokens: 1),
            onEvent: { third.append($0) }
        )
        XCTAssertEqual(third.completedTokens, 1)
        await engine.unload()
        XCTAssertFalse(engine.isLoaded)

        print("[Edge0 engine] lifecycle OK · first4=\(first.tokenText.debugDescription) pool=\(String(describing: stats.map { "\($0.occupancySlots)/\($0.capacitySlots)" }))")
    }
}
