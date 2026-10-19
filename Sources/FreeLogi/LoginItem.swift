import ServiceManagement
import Carbon

// 로그인 시 실행. 등록하면 시스템의 로그인 항목에 추가된다(기기 설정 변경이라 확인 중에는 등록하지 않는다).
enum LoginItem {
    static func isLoginItemLaunch(_ eventValue: OSType?) -> Bool {
        eventValue == OSType(keyAELaunchedAsLogInItem)
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
