import Foundation
import IOKit.hid

// 로지텍 HID++ 컬렉션: 수신기·USB는 0xFF00/0x0002, BLE 직결은 0xFF43/0x0202
private let logitechVendorId = 0x046D
private let hidppUsages: [(page: Int, usage: Int)] = [(0xFF00, 0x0002), (0xFF43, 0x0202)]
private let inputReportBufferSize = 64
// 기본 모드에만 걸면 종료를 미루는 중첩 루프(NSApplication.terminate)나 메뉴 추적 중에는 HID 콜백이 안 온다.
private var hidRunLoopMode: CFString { CFRunLoopMode.commonModes.rawValue }

private let inputReportCallback: IOHIDReportCallback = { context, _, _, _, _, report, reportLength in
    guard let context else { return }
    let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
    let node = Unmanaged<HIDPPNode>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { node.channel.handleReport(bytes) }
}

private let deviceMatchedCallback: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    let manager = Unmanaged<HIDPPManager>.fromOpaque(context).takeUnretainedValue()
    nonisolated(unsafe) let matchedDevice = device
    MainActor.assumeIsolated { manager.deviceMatched(matchedDevice) }
}

private let deviceRemovedCallback: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    let manager = Unmanaged<HIDPPManager>.fromOpaque(context).takeUnretainedValue()
    nonisolated(unsafe) let removedDevice = device
    MainActor.assumeIsolated { manager.deviceRemoved(removedDevice) }
}

// 열린 HID++ 인터페이스 하나. input 리포트는 메인 run loop에서 channel로 들어간다.
// 장치가 빠지면 HIDPPManager가 close()하고 노드를 버린다. 다시 연결되면 새 노드가 생긴다.
@MainActor
final class HIDPPNode {
    let device: IOHIDDevice
    let name: String
    let productId: Int
    let transport: String
    let usagePage: Int
    let usage: Int
    let channel: HIDPPChannel
    private let reportBuffer: UnsafeMutablePointer<UInt8>

    init?(device: IOHIDDevice) {
        guard let (usagePage, usage) = hidppUsages.first(where: {
            IOHIDDeviceConformsTo(device, UInt32($0.page), UInt32($0.usage))
        }) else { return nil }

        self.device = device
        self.name = HIDPPNode.stringProperty(device, kIOHIDProductKey) ?? "?"
        self.transport = HIDPPNode.stringProperty(device, kIOHIDTransportKey) ?? "?"
        self.productId = HIDPPNode.intProperty(device, kIOHIDProductIDKey)
        self.usagePage = usagePage
        self.usage = usage
        let reportQueue = DispatchQueue(label: "kr.lasbe.freelogi.hidpp.output")
        // 큐의 블록이 장치를 보유한다. output만 직렬 큐에서 보내고 input·채널 상태는 메인에 둔다.
        nonisolated(unsafe) let outputDevice = device
        self.channel = HIDPPChannel { frame, completion in
            reportQueue.async {
                let reportId = CFIndex(frame[0])
                let result = IOHIDDeviceSetReport(outputDevice, kIOHIDReportTypeOutput, reportId, frame, frame.count)
                let isSent = result == kIOReturnSuccess
                Task { @MainActor in completion(isSent) }
            }
        }

        self.reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputReportBufferSize)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, inputReportBufferSize, inputReportCallback, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), hidRunLoopMode)
    }

    // 리포트 콜백이 이 노드(context)를 더 부르지 않게 풀고 버퍼를 돌려준다.
    func close() {
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, inputReportBufferSize, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), hidRunLoopMode)
        reportBuffer.deallocate()
    }

    private static func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int ?? 0
    }
}

// 연결된 로지텍 HID++ 인터페이스를 모두 열어 노드로 돌려준다. 입력 모니터링 권한이 필요하다.
// 이후 장치가 빠지거나(onNodeRemoved) 다시 붙으면(onNodeAdded) 알린다. 재연결이면 새 IOHIDDevice라 새 노드다.
@MainActor
final class HIDPPManager {
    private let manager: IOHIDManager
    // IOHIDManagerOpen의 결과. 입력 모니터링이 막혀 있으면 kIOReturnNotPermitted(0xE00002E2)가 온다.
    let openResult: IOReturn
    private(set) var nodes: [HIDPPNode]
    var onNodeAdded: ((HIDPPNode) -> Void)?
    var onNodeRemoved: ((HIDPPNode) -> Void)?

    init() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matchings = hidppUsages.map { usage in
            [
                kIOHIDVendorIDKey: logitechVendorId,
                kIOHIDDeviceUsagePageKey: usage.page,
                kIOHIDDeviceUsageKey: usage.usage,
            ] as CFDictionary
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchings as CFArray)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), hidRunLoopMode)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        self.manager = manager
        self.openResult = openResult
        self.nodes = devices.compactMap { HIDPPNode(device: $0) }

        // 이미 있는 장치도 등록 직후 matching 콜백이 한 번 더 불린다(실측). deviceMatched가 걸러낸다.
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceMatchedCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemovedCallback, context)
    }

    // 콜백을 풀고 노드를 모두 닫는다. 이 뒤로 이 매니저는 쓰지 않는다.
    func close() {
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        for node in nodes { node.close() }
        nodes = []
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), hidRunLoopMode)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    fileprivate func deviceMatched(_ device: IOHIDDevice) {
        let isKnown = nodes.contains { $0.device == device }
        if isKnown { return }
        guard let node = HIDPPNode(device: device) else { return }
        nodes.append(node)
        onNodeAdded?(node)
    }

    fileprivate func deviceRemoved(_ device: IOHIDDevice) {
        guard let index = nodes.firstIndex(where: { $0.device == device }) else { return }
        let node = nodes.remove(at: index)
        node.close()
        onNodeRemoved?(node)
    }
}
