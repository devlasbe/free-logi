import SwiftUI

let MAIN_WINDOW_SIZE = CGSize(width: 780, height: 420)
private let PERMISSION_SPACING: CGFloat = 32
private let PERMISSION_PADDING: CGFloat = 40
private let APP_ICON_SIZE: CGFloat = 64

enum MainScreenEnum {
    case permissions
    case mapping

    static func select(granted: [Permission: Bool]) -> MainScreenEnum {
        let allGranted = Permission.allCases.allSatisfy { granted[$0] == true }
        return allGranted ? .mapping : .permissions
    }
}

struct MainView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Group {
            switch model.screen {
            case .permissions:
                permissionView
            case .mapping:
                SettingsView(model: model)
            }
        }
        .frame(width: MAIN_WINDOW_SIZE.width, height: MAIN_WINDOW_SIZE.height)
    }

    private var permissionView: some View {
        VStack(spacing: PERMISSION_SPACING) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: APP_ICON_SIZE, height: APP_ICON_SIZE)
                .accessibilityHidden(true)
            Text("FreeLogi를 사용하려면 권한을 허용해 주세요")
                .font(.title2)
            VStack(spacing: PERMISSION_SPACING) {
                ForEach(Permission.allCases, id: \.self) { permission in
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(permission.title).font(.headline)
                            Text(permission.reason)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if model.grantedPermissions[permission] == true {
                            Text("✓")
                                .foregroundStyle(.green)
                                .accessibilityLabel("\(permission.title) 허용됨")
                        } else {
                            Button("허용하러 가기") {
                                permission.requestAndOpenSettings()
                            }
                        }
                    }
                }
            }
        }
        .padding(PERMISSION_PADDING)
    }
}
