import Foundation
import IOKit.hid

// 디버그(--hid-access): 입력 모니터링 없이 HID++ 장치를 쓸 수 있는지 본다.
// IOHIDRequestAccess는 부르지 않는다. 상태가 "미결정"이면 장치를 여는 것만으로 시스템 프롬프트가 뜰 수 있어서 열지 않는다.
@MainActor
func checkHIDAccess() async {
    let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    switch access {
    case kIOHIDAccessTypeGranted: print("IOHIDCheckAccess: granted")
    case kIOHIDAccessTypeDenied: print("IOHIDCheckAccess: denied")
    default:
        print("IOHIDCheckAccess: unknown(\(access.rawValue)) — 열면 프롬프트가 뜰 수 있어 열지 않는다")
        return
    }

    let manager = HIDPPManager()
    print(String(format: "IOHIDManagerOpen: 0x%08X", manager.openResult))
    print("HID++ 인터페이스 \(manager.nodes.count)개")
    for node in manager.nodes {
        do {
            let version = try await node.channel.protocolVersion(deviceIndex: HIDPPChannel.directDeviceIndex)
            print("  \(node.name): ping 0xFF → HID++ \(version.major).\(version.minor)")
        } catch {
            print("  \(node.name): ping 0xFF 실패 (\(error))")
        }
    }
}
