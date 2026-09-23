import Foundation
import Network

/// Brute-force guard shared by the Local API server and the Mac bridge's
/// pairing route, keyed by the remote host.
///
/// It used to be one global counter, so any LAN peer sending five bad
/// credentials a minute locked every legitimate client out. Keying by host
/// confines the lockout to the peer that failed. The secrets it protects
/// (bearer key, pairing nonce) are UUID-derived, so per-host counting does not
/// make guessing practical even from many addresses.
struct AuthFailureThrottle {
    static let maxFailures = 5
    static let window: TimeInterval = 60
    static let lockout: TimeInterval = 60

    private var failures: [String: [Date]] = [:]
    private var lockedUntil: [String: Date] = [:]

    func isLocked(_ host: String, now: Date = Date()) -> Bool {
        (lockedUntil[host] ?? .distantPast) > now
    }

    mutating func recordFailure(_ host: String, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.window)
        // Prune every host, not just this one, so a stream of distinct
        // addresses cannot grow either table without bound.
        failures = failures.compactMapValues { dates in
            let recent = dates.filter { $0 > cutoff }
            return recent.isEmpty ? nil : recent
        }
        lockedUntil = lockedUntil.filter { $0.value > now }

        var recent = failures[host] ?? []
        recent.append(now)
        if recent.count >= Self.maxFailures {
            lockedUntil[host] = now.addingTimeInterval(Self.lockout)
            failures[host] = nil
        } else {
            failures[host] = recent
        }
    }

    mutating func recordSuccess(_ host: String) {
        failures[host] = nil
        lockedUntil[host] = nil
    }

    /// The peer's address without its port, so reconnecting from a new
    /// ephemeral port does not reset the count.
    static func host(of connection: NWConnection) -> String {
        if case .hostPort(let host, _) = connection.endpoint { return "\(host)" }
        return "\(connection.endpoint)"
    }
}
