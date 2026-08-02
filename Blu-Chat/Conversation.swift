import Foundation
import SwiftData

/// Represents a chat conversation, either one-on-one or group, containing participants and messages.
@Model
final class Conversation {
    /// Unique identifier for the conversation
    @Attribute(.unique) var id: UUID
    /// Optional conversation name (for group chats)
    var name: String?
    /// List of users in the conversation
    var participants: [User]
    /// Messages exchanged in this conversation
    var messages: [Message]
    /// Indicates if this is a group chat
    var isGroup: Bool
    
    init(id: UUID = UUID(), name: String? = nil, participants: [User], messages: [Message] = [], isGroup: Bool = false) {
        self.id = id
        self.name = name
        self.participants = participants
        self.messages = messages
        self.isGroup = isGroup
    }
}
