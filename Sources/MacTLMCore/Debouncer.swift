import Foundation

/// Coalesces bursts of calls into one, on the main queue.
/// With `maxDelay`, guarantees firing within `maxDelay` of the burst's first
/// call even under continuous churn (used for launch-settle detection).
public final class Debouncer {
    private let delay: TimeInterval
    private let maxDelay: TimeInterval?
    private var pending: DispatchWorkItem?
    private var burstStart: Date?

    public init(delay: TimeInterval, maxDelay: TimeInterval? = nil) {
        self.delay = delay
        self.maxDelay = maxDelay
    }

    public func call(_ action: @escaping () -> Void) {
        pending?.cancel()
        let now = Date()
        if burstStart == nil { burstStart = now }
        var effectiveDelay = delay
        if let maxDelay, let start = burstStart {
            effectiveDelay = min(delay, max(0, maxDelay - now.timeIntervalSince(start)))
        }
        let item = DispatchWorkItem { [weak self] in
            self?.burstStart = nil
            self?.pending = nil
            action()
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDelay, execute: item)
    }

    public func cancel() {
        pending?.cancel()
        pending = nil
        burstStart = nil
    }
}
