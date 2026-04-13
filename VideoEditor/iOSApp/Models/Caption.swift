import Foundation

struct Caption: Codable, Identifiable, Hashable {
    let id: UUID
    let shortID: UUID
    let platform: String
    var title: String?
    var body: String
    var hashtags: [String]
    var lastEditedBy: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case shortID = "short_id"
        case platform, title, body, hashtags
        case lastEditedBy = "last_edited_by"
        case updatedAt = "updated_at"
    }
}
