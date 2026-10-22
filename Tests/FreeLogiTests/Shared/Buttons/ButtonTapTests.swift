import CoreGraphics
import Foundation
import XCTest
@testable import FreeLogi

// 실제 이벤트 탭을 만든다. 손쉬운 사용 권한이 없는 환경(CI 등)에서는 건너뛴다.
@MainActor
final class ButtonTapTests: XCTestCase {
    // 콜백이 이만큼 막히면 시스템이 탭을 끈다(실측 약 1초).
    private static let blockSeconds: TimeInterval = 1.5
    private static let syntheticButtonNumber: Int64 = 9

    private func postSyntheticClick() {
        let cursor = CGEvent(source: nil)?.location ?? .zero
        for type in [CGEventType.otherMouseDown, CGEventType.otherMouseUp] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: cursor, mouseButton: .center)
            event?.setIntegerValueField(.mouseEventButtonNumber, value: ButtonTapTests.syntheticButtonNumber)
            event?.post(tap: .cghidEventTap)
        }
    }

    private func pumpRunLoop(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(ButtonTapTests.blockSeconds + 3)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testTapTurnedOffBecauseHandlerBlockedIsTurnedBackOn() throws {
        var handledDowns = 0
        let tap = ButtonTap { _, isDown in
            if isDown {
                handledDowns += 1
                Thread.sleep(forTimeInterval: ButtonTapTests.blockSeconds)
            }
            return true
        }
        let blockingTap = try XCTUnwrap(tap, "손쉬운 사용 권한이 없어 탭을 만들 수 없다")

        postSyntheticClick()
        pumpRunLoop { handledDowns == 1 }
        pumpRunLoop { blockingTap.reenabledCount > 0 || !blockingTap.isEnabled }
        // 시스템이 알림 콜백을 보내 스스로 다시 켰거나(reenabledCount > 0) 꺼진 채다.
        // 꺼진 채라면 주기 점검(reenableIfDisabled)이 켠다.
        blockingTap.reenableIfDisabled()
        XCTAssertTrue(blockingTap.isEnabled)

        postSyntheticClick()
        pumpRunLoop { handledDowns == 2 }
        XCTAssertEqual(handledDowns, 2, "다시 켠 탭이 이벤트를 받는다")
        blockingTap.stop()
    }
}
