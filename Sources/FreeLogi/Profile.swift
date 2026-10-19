import Foundation

// 마우스 버튼 식별자
enum ButtonID: Codable, Hashable {
    case standard(Int)   // CGEvent mouseEventButtonNumber (>=3)
    case hidpp(UInt16)   // HID++ 0x1B04 control ID
}

// 키 조합
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt64  // CGEventFlags rawValue (cmd/shift/opt/ctrl 만)
}

enum GestureDirectionEnum: String, Codable, CaseIterable {
    case up, down, left, right

    var displayName: String {
        switch self {
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        }
    }
}

struct BindingID: Hashable {
    let button: ButtonID
    var gesture: GestureDirectionEnum? = nil
}

// 버튼·동작-키 바인딩. gesture가 없는 기존 JSON도 클릭으로 읽힌다.
struct ButtonBinding: Codable, Hashable {
    var button: ButtonID
    var keys: KeyCombo
    var gesture: GestureDirectionEnum? = nil

    var id: BindingID { BindingID(button: button, gesture: gesture) }
}

// 프로필
struct Profile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var bindings: [ButtonBinding]
    var buttonNames: [ButtonID: String]

    init(id: UUID, name: String, bindings: [ButtonBinding], buttonNames: [ButtonID: String] = [:]) {
        self.id = id
        self.name = name
        self.bindings = bindings
        self.buttonNames = buttonNames
        fillButtonNames()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, bindings, buttonNames
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        bindings = try container.decode([ButtonBinding].self, forKey: .bindings)
        buttonNames = try container.decodeIfPresent([ButtonID: String].self, forKey: .buttonNames) ?? [:]
        fillButtonNames()
    }

    var nextButtonName: String {
        let usedNames = Set(buttonNames.values)
        var number = 1
        while usedNames.contains("버튼 \(number)") { number += 1 }
        return "버튼 \(number)"
    }

    func buttonName(for button: ButtonID) -> String {
        buttonNames[button] ?? nextButtonName
    }

    // 이름 없는 기존 파일은 바인딩 순서대로 번호를 붙인다. 방향 행은 같은 이름을 쓴다.
    private mutating func fillButtonNames() {
        let buttons = Set(bindings.map(\.button))
        buttonNames = buttonNames.filter { buttons.contains($0.key) && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for binding in bindings where buttonNames[binding.button] == nil {
            buttonNames[binding.button] = nextButtonName
        }
    }
}

// 스토어 상태
struct ProfileStoreState: Codable, Equatable {
    var profiles: [Profile]
    var activeID: UUID
}
