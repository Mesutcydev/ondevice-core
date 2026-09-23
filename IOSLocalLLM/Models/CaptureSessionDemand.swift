import Foundation

/// Mutated only on the capture queue. A lifecycle resume cannot recreate departed UI demand.
struct CaptureSessionDemand: Equatable {
    var isRequested = false
    var isForeground = true
    var shouldRun: Bool { isRequested && isForeground }
}
