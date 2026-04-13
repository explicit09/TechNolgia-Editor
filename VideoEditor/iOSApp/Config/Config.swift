import Foundation
import SwiftUI

enum Config {
    static let appName = "TechNolgia"
    static let brandPalette: [BrandColor] = [
        .init(name: "Gold", color: Color(red: 201 / 255, green: 160 / 255, blue: 40 / 255)),
        .init(name: "Navy", color: Color(red: 7 / 255, green: 13 / 255, blue: 23 / 255)),
        .init(name: "White", color: .white),
        .init(name: "Pink", color: Color(red: 233 / 255, green: 30 / 255, blue: 99 / 255)),
        .init(name: "Green", color: Color(red: 0 / 255, green: 200 / 255, blue: 83 / 255)),
    ]
}

struct BrandColor: Identifiable, Hashable {
    let name: String
    let color: Color

    var id: String { name }
}
