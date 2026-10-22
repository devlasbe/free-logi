import CoreGraphics
import XCTest
@testable import FreeLogi

final class ScrollTapTests: XCTestCase {
    func testDecaySplitsPreservesDistanceAndSettles() {
        var decay = ScrollDecay()
        var output: [(Int32, Int32)] = []
        decay.add(vertical: 1000, horizontal: -500, at: 0)
        for tick in 1...24 {
            decay.tick(at: Double(tick) / 120) { output.append(($0, $1)) }
        }
        XCTAssertGreaterThan(output.count, 1)
        XCTAssertGreaterThanOrEqual(output.reduce(0) { $0 + $1.0 }, 950)
        XCTAssertLessThanOrEqual(output.reduce(0) { $0 + $1.1 }, -475)
        for tick in 25...120 {
            decay.tick(at: Double(tick) / 120) { output.append(($0, $1)) }
        }
        XCTAssertEqual(output.reduce(0) { $0 + $1.0 }, 1000)
        XCTAssertEqual(output.reduce(0) { $0 + $1.1 }, -500)
        XCTAssertFalse(decay.isActive)
    }

    func testDecayAccumulatesInputsAndKeepsAxesIndependent() {
        var decay = ScrollDecay()
        var vertical: Int32 = 0
        var horizontal: Int32 = 0
        decay.add(vertical: 30, horizontal: 0, at: 10)
        decay.tick(at: 10) { _, _ in XCTFail("시각이 같으면 이동하지 않아야 한다") }
        decay.tick(at: 10.01) {
            vertical += $0
            horizontal += $1
        }
        XCTAssertEqual(horizontal, 0)
        decay.add(vertical: -7, horizontal: -50, at: 10.01)
        for tick in 2...120 {
            decay.tick(at: 10 + Double(tick) / 120) {
                vertical += $0
                horizontal += $1
            }
        }
        XCTAssertEqual(vertical, 23)
        XCTAssertEqual(horizontal, -50)
        XCTAssertFalse(decay.isActive)
    }

    func testReversedPointDeltasAreSmoothedAndFlagsAreCopied() throws {
        let input = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                         wheel1: 30, wheel2: -50, wheel3: 0))
        reverseScroll(input, vertical: true, horizontal: false)
        var decay = ScrollDecay()
        decay.add(vertical: input.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                  horizontal: input.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), at: 0)
        var total = SIMD2<Int32>.zero
        for tick in 1...120 {
            decay.tick(at: Double(tick) / 120) { total &+= SIMD2($0, $1) }
        }
        XCTAssertEqual(total, SIMD2(-30, -50))
        let event = try XCTUnwrap(makeSmoothScrollEvent(vertical: 3, horizontal: -5, flags: [.maskCommand, .maskShift]))
        XCTAssertEqual(event.flags, [.maskCommand, .maskShift])
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), smoothScrollMarker)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 3)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), -5)
    }

    func testSmoothScrollPixelsUseLinesTimesTwenty() throws {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                         wheel1: 0, wheel2: 0, wheel3: 0))
        // 실제 휠에서 본 값: 1.69줄(point 17), -5줄
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 111159)
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -327680)
        let pixels = smoothScrollPixels(event)
        XCTAssertEqual(pixels.vertical, 34)
        XCTAssertEqual(pixels.horizontal, -100)
    }

    func testFinishDrainsAndCanStartAgain() {
        var decay = ScrollDecay()
        decay.add(vertical: 30, horizontal: -50, at: 0)
        var total = SIMD2<Int32>.zero
        decay.tick(at: 0.01) { total &+= SIMD2($0, $1) }
        decay.finish { total &+= SIMD2($0, $1) }
        XCTAssertEqual(total, SIMD2(30, -50))
        XCTAssertFalse(decay.isActive)
        decay.add(vertical: 1, horizontal: -1, at: 1)
        decay.tick(at: 2) { total &+= SIMD2($0, $1) }
        XCTAssertEqual(total, SIMD2(31, -51))
        XCTAssertFalse(decay.isActive)
    }

    func testOnlySelectedWheelAxesAreReversed() throws {
        let verticalFields: [CGEventField] = [.scrollWheelEventDeltaAxis1, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1]
        let horizontalFields: [CGEventField] = [.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2]
        for (vertical, horizontal) in [(true, false), (false, true), (true, true), (false, false)] {
            for (phase, momentum): (Int64, Int64) in [(0, 0), (1, 0), (0, 1), (2, 2)] {
                let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 3, wheel1: 0, wheel2: 0, wheel3: 7))
                for (index, field) in (verticalFields + horizontalFields).enumerated() {
                    event.setIntegerValueField(field, value: Int64(index + 1) * (index.isMultiple(of: 2) ? 1 : -1))
                }
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
                let original = (verticalFields + horizontalFields).map { event.getIntegerValueField($0) }
                let originalAxis3 = event.getIntegerValueField(.scrollWheelEventDeltaAxis3)
                reverseScroll(event, vertical: vertical, horizontal: horizontal)
                for (index, field) in (verticalFields + horizontalFields).enumerated() {
                    let enabled = index < verticalFields.count ? vertical : horizontal
                    let shouldReverse = enabled && phase == 0 && momentum == 0
                    XCTAssertEqual(event.getIntegerValueField(field), shouldReverse ? -original[index] : original[index])
                }
                XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis3), originalAxis3)
                XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventScrollPhase), phase)
                XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventMomentumPhase), momentum)
            }
        }
    }
}
