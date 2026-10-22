import Foundation

extension ButtonID {
    var rawValueText: String {
        switch self {
        case .standard(let buttonNumber):
            return "btn \(buttonNumber)"
        case .hidpp(let cid):
            return String(format: "cid 0x%04X", cid)
        }
    }
}
