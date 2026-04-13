import Foundation

struct ThumbnailSettings: Codable, Hashable {
    let shortID: UUID
    var labelText: String
    var labelColor: String        // hex like "#C9A028"
    var labelPosition: Position
    var frameIndex: Int
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case shortID = "short_id"
        case labelText = "label_text"
        case labelColor = "label_color"
        case labelPosition = "label_position"
        case frameIndex = "frame_index"
        case updatedAt = "updated_at"
    }

    enum Position: String, CaseIterable, Codable {
        case topLeft = "top-left"
        case topCenter = "top-center"
        case topRight = "top-right"
        case centerLeft = "center-left"
        case center = "center"
        case centerRight = "center-right"
        case bottomLeft = "bottom-left"
        case bottomCenter = "bottom-center"
        case bottomRight = "bottom-right"
    }
}
