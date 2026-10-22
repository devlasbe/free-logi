import XCTest
@testable import FreeLogi

final class GestureAccumulatorTests: XCTestCase {
    func testThresholdDominantAxisAndSigns() {
        let cases: [(Int16, Int16, GestureDirectionEnum?)] = [
            (0, 0, nil), (49, -49, nil),
            (50, 0, .right), (-50, 0, .left), (0, -50, .up), (0, 50, .down),
            (80, -100, .up), (-100, 80, .left), (50, 50, .right),
            (Int16.min, 0, .left), (0, Int16.max, .down),
        ]
        for (dx, dy, expected) in cases {
            var accumulator = GestureAccumulator()
            accumulator.add(dx: dx, dy: dy)
            XCTAssertEqual(accumulator.direction, expected, "dx=\(dx), dy=\(dy)")
        }
    }

    func testAccumulatesNetTravelBeyondInt16Range() {
        var accumulator = GestureAccumulator()
        accumulator.add(dx: 30, dy: 0)
        XCTAssertNil(accumulator.direction)
        accumulator.add(dx: 20, dy: 0)
        XCTAssertEqual(accumulator.direction, .right)
        accumulator.add(dx: -50, dy: 0)
        XCTAssertNil(accumulator.direction)
        accumulator.add(dx: .min, dy: 0)
        accumulator.add(dx: .min, dy: 0)
        XCTAssertEqual(accumulator.direction, .left)
    }
}
