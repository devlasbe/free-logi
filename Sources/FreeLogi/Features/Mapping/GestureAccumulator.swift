// ponytail: GESTURE_DISTANCE_THRESHOLD is the tuning knob for gesture travel in raw HID++ units.
private let GESTURE_DISTANCE_THRESHOLD = 50

// 눌림부터 뗌까지의 순이동량. 화면 좌표처럼 +y는 아래쪽이다.
struct GestureAccumulator {
    private var dx = 0
    private var dy = 0

    mutating func add(dx: Int16, dy: Int16) {
        self.dx += Int(dx)
        self.dy += Int(dy)
    }

    var direction: GestureDirectionEnum? {
        let horizontalDistance = abs(dx)
        let verticalDistance = abs(dy)
        let dominantDistance = max(horizontalDistance, verticalDistance)
        if dominantDistance < GESTURE_DISTANCE_THRESHOLD { return nil }
        if horizontalDistance >= verticalDistance {
            return dx < 0 ? .left : .right
        }
        return dy < 0 ? .up : .down
    }
}
