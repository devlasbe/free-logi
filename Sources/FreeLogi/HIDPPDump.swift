import Foundation

// 디버그(--dump): 연결된 HID++ 인터페이스마다 프로토콜 버전과 0x1B04 컨트롤 목록을 출력한다.
// 직결(BLE·USB)이면 0xFF에 ping하고, 0xFF가 HID++ 1.0 오류로 답하면 수신기로 보고 슬롯 1~6에 ping한다.
@MainActor
func dumpHIDPP() async {
    let manager = HIDPPManager()
    defer { withExtendedLifetime(manager) {} }

    print("HID++ 인터페이스 \(manager.nodes.count)개")
    for node in manager.nodes {
        let usage = String(format: "0x%04X/0x%04X", node.usagePage, node.usage)
        print("== \(node.name) (\(node.transport), PID 0x\(String(node.productId, radix: 16, uppercase: true)), \(usage))")
        await dumpDevices(of: node)
    }
}

@MainActor
private func dumpDevices(of node: HIDPPNode) async {
    let directVersion: (major: UInt8, minor: UInt8)
    do {
        directVersion = try await node.channel.protocolVersion(deviceIndex: HIDPPChannel.directDeviceIndex)
    } catch {
        print("  인덱스 0xFF: 응답 없음 (\(error))")
        return
    }

    if directVersion.major >= 2 {
        await dumpDevice(on: node.channel, deviceIndex: HIDPPChannel.directDeviceIndex, version: directVersion)
        return
    }

    print("  인덱스 0xFF: HID++ 1.0 → 수신기로 보고 슬롯 1~6을 확인한다")
    do {
        let pairedCount = try await node.channel.pairedDeviceCount()
        print("  수신기에 페어링된 기기: \(pairedCount)개")
    } catch {
        print("  페어링 수 읽기 실패 (\(error))")
    }
    for slot in HIDPPChannel.receiverSlotIndexes {
        do {
            let version = try await node.channel.protocolVersion(deviceIndex: slot)
            await dumpDevice(on: node.channel, deviceIndex: slot, version: version)
        } catch {
            print("  슬롯 \(slot): 응답 없음 (\(error))")
        }
    }
}

@MainActor
private func dumpDevice(on channel: HIDPPChannel, deviceIndex: UInt8, version: (major: UInt8, minor: UInt8)) async {
    let index = String(format: "0x%02X", deviceIndex)
    if version.major < 2 {
        print("  [\(index)] HID++ \(version.major).\(version.minor) — feature 목록이 없다")
        return
    }

    let name = (try? await channel.deviceName(deviceIndex: deviceIndex)) ?? "?"
    print("  [\(index)] \(name) — HID++ \(version.major).\(version.minor)")

    do {
        guard let controls = try await channel.controls(deviceIndex: deviceIndex),
              let reprogIndex = try await channel.featureIndex(of: HIDPPFeatureId.reprogControls, deviceIndex: deviceIndex)
        else {
            print("    0x1B04 없음")
            return
        }
        print("    0x1B04 컨트롤 \(controls.count)개")
        for control in controls {
            let cid = String(format: "0x%04X", control.cid)
            let taskId = String(format: "0x%04X", control.taskId)
            let flags = String(format: "0x%04X", control.flags)
            let divertable = control.isDivertable ? "divertable" : "-"
            let persistent = control.isPersistentlyDivertable ? "persistent" : "-"
            let rawXY = control.supportsRawXY ? "rawXY" : "-"
            var diverted = "-"
            if control.isDivertable {
                let reporting = try await channel.cidReporting(cid: control.cid, featureIndex: reprogIndex, deviceIndex: deviceIndex)
                if reporting.diverted { diverted = reporting.rawXY ? "diverted(rawXY)" : "diverted" }
            }
            print("    cid=\(cid) tid=\(taskId) flags=\(flags) \(divertable) \(persistent) \(rawXY) \(diverted)")
        }
    } catch {
        print("    0x1B04 읽기 실패 (\(error))")
    }
}
