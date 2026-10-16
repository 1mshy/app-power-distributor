import Foundation

/// Picks how much of each period the target may run, from what it used last interval.
///
/// Usage roughly scales with run time, so the duty is multiplied by `cap / measured`,
/// damped (a fraction of that step in log space). It's an integral controller: it
/// settles where the measurement equals the cap, whatever the exact relationship
/// between run time and power — which shifts as the CPU and GPU change clock speed.
public struct DutyController: Sendable, Equatable {
    public var minimumDuty: Double
    /// 0...1. How much of the full step to take when over the cap. Quick, so fans
    /// calm down fast.
    public var gainDown: Double
    /// The same when under the cap. Slower: clock speeds and the power sensor react
    /// with a lag, and rising too fast overshoots.
    public var gainUp: Double
    /// Within this fraction of the cap, leave the duty alone.
    public var deadband: Double
    public private(set) var duty: Double = 1

    public init(minimumDuty: Double = 0.05, gainDown: Double = 0.5, gainUp: Double = 0.25, deadband: Double = 0.03) {
        self.minimumDuty = minimumDuty
        self.gainDown = gainDown
        self.gainUp = gainUp
        self.deadband = deadband
    }

    public mutating func reset() { duty = 1 }

    /// - Parameters:
    ///   - measured: the capped quantity over the last interval.
    ///   - cap: the limit, in the same unit. Zero or less throttles as hard as allowed.
    ///   - idle: the target used too little for throttling to make a difference, so
    ///     let it run.
    @discardableResult
    public mutating func update(measured: Double, cap: Double, idle: Bool = false) -> Double {
        let step: Double
        if cap <= 0 {
            step = 0
        } else if idle || measured <= 0.01 * cap {
            step = 4
        } else if abs(measured - cap) <= deadband * cap {
            return duty
        } else {
            step = cap / measured
        }
        let clamped = min(max(step, 0.25), 4)
        duty = min(max(duty * pow(clamped, clamped < 1 ? gainDown : gainUp), minimumDuty), 1)
        return duty
    }
}
