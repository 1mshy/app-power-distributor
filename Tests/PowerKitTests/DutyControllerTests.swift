import Foundation
import Testing
@testable import PowerKit

struct DutyControllerTests {
    @Test func settlesOnTheCapForAProportionalLoad() {
        var controller = DutyController()
        var power = 120.0
        for _ in 0..<20 {
            controller.update(measured: power, cap: 40)
            power = 120 * controller.duty
        }
        #expect(abs(power - 40) < 40 * 0.04)
    }

    @Test func settlesWhenPowerRespondsALateAndNonlinearly() {
        // Clocks rise as fewer cores are busy, so power is concave in run time, and
        // it shows up one interval late.
        var controller = DutyController()
        var previousDuty = 1.0
        var readings: [Double] = []
        for _ in 0..<40 {
            let power = 130 * pow(previousDuty, 0.6)
            readings.append(power)
            previousDuty = controller.duty
            controller.update(measured: power, cap: 50)
        }
        let settled = readings.suffix(10)
        #expect(settled.allSatisfy { abs($0 - 50) < 50 * 0.08 })
    }

    @Test func letsAnIdleAppRunFreely() {
        var controller = DutyController()
        controller.update(measured: 200, cap: 20)
        #expect(controller.duty < 1)
        for _ in 0..<10 { controller.update(measured: 0, cap: 20) }
        #expect(controller.duty == 1)
    }

    @Test func neverGoesBelowTheMinimumRunShare() {
        var controller = DutyController(minimumDuty: 0.1)
        for _ in 0..<20 { controller.update(measured: 500, cap: 1) }
        #expect(controller.duty == 0.1)
        controller.update(measured: 500, cap: 0)
        #expect(controller.duty == 0.1)
    }

    @Test func ignoresSmallErrors() {
        var controller = DutyController()
        controller.update(measured: 80, cap: 40)
        let duty = controller.duty
        controller.update(measured: 40.8, cap: 40)
        #expect(controller.duty == duty)
    }

    @Test func dropsFasterThanItRises() {
        var down = DutyController()
        down.update(measured: 80, cap: 40)
        var up = DutyController()
        up.update(measured: 160, cap: 40)
        up.update(measured: 160, cap: 40)
        let before = up.duty
        up.update(measured: 20, cap: 40)
        #expect(1 - down.duty > (up.duty - before) / before / 2)
    }
}
