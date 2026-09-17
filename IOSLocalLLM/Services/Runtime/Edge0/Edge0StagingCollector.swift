import Foundation

// MARK: - Edge0StagingCollector
//
// Scheduler-level counters for `.staged` expert execution. The staged
// pipeline keeps two banks of TRUE-router selected expert leases; while
// token i computes on the GPU, token i+1's bank is acquired from storage.
//
// Metric definitions:
//   banksScheduled        - acquire tasks started for a token's bank
//   banksCompleted        - banks whose acquire returned (loads finished)
//   bankSwitches          - times the collector promoted a new active bank
//   readyBeforeUse        - bank was already complete when compute needed it
//                           (await under `readyThresholdSeconds`)
//   lateAtUse             - compute had to wait for the bank beyond the
//                           threshold (staging did not fully hide the I/O)
//   criticalStageWaitSecs - true wall-clock time compute spent awaiting the
//                           pre-acquired bank (NOT summed concurrent waits)
//   cancellations         - bank acquires cancelled with the generation
//   staleBanksDiscarded   - banks released without being consumed

final class Edge0StagingCollector: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        var banksScheduled = 0
        var banksCompleted = 0
        var bankSwitches = 0
        var readyBeforeUse = 0
        var lateAtUse = 0
        var criticalStageWaitSeconds = 0.0
        var cancellations = 0
        var staleBanksDiscarded = 0

        var readyBeforeUseRate: Double {
            let uses = readyBeforeUse + lateAtUse
            return uses > 0 ? Double(readyBeforeUse) / Double(uses) : 0
        }
    }

    /// A bank that completes within this window of being awaited is counted
    /// as ready-before-use (the await observed an already-finished task).
    static let readyThresholdSeconds = 0.001

    private let lock = NSLock()
    private var snapshot = Snapshot()

    var current: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func recordBankScheduled() {
        mutate { $0.banksScheduled += 1 }
    }

    func recordBankCompleted() {
        mutate { $0.banksCompleted += 1 }
    }

    func recordBankUsed(waitSeconds: Double) {
        mutate {
            $0.bankSwitches += 1
            $0.criticalStageWaitSeconds += max(0, waitSeconds)
            if waitSeconds <= Self.readyThresholdSeconds {
                $0.readyBeforeUse += 1
            } else {
                $0.lateAtUse += 1
            }
        }
    }

    func recordCancellation() {
        mutate { $0.cancellations += 1 }
    }

    func recordStaleDiscard() {
        mutate { $0.staleBanksDiscarded += 1 }
    }

    private func mutate(_ body: (inout Snapshot) -> Void) {
        lock.lock()
        body(&snapshot)
        lock.unlock()
    }
}
