import CoreGraphics
import XCTest
@testable import FreeLogi

final class ScrollTapTests: XCTestCase {
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
