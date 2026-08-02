import Foundation
import SwiftData

/// Represents the type of content sent in a message.
enum MessageType: String, Codable {
    case text
    case image
    case video
    case file
}

/// Represents the state of message delivery over Multipeer Connectivity.
enum DeliveryStatus: String, Codable {
    case sending
    case sent
    case failed
}

/// Represents an individual message exchanged within a conversation.
@Model
final class Message {
    /// Unique identifier for the message
    @Attribute(.unique) var id: UUID
    /// The user who sent this message
    var sender: User
    /// The message text content or caption
    var content: String
    /// The type of message (text, image, video, file)
    var typeRaw: String
    /// Relative local path or file URL string for media attachments
    var mediaPath: String?
    /// File size in bytes for attachments
    var fileSize: Int64
    /// Status of sending over MultipeerConnectivity
    var statusRaw: String
    /// The date and time the message was sent
    var timestamp: Date
    /// The conversation this message belongs to
    var conversation: Conversation?
    
    var type: MessageType {
        get { MessageType(rawValue: typeRaw) ?? .text }
        set { typeRaw = newValue.rawValue }
    }
    
    var status: DeliveryStatus {
        get { DeliveryStatus(rawValue: statusRaw) ?? .sent }
        set { statusRaw = newValue.rawValue }
    }
    
    init(
        id: UUID = UUID(),
        sender: User,
        content: String,
        type: MessageType = .text,
        mediaPath: String? = nil,
        fileSize: Int64 = 0,
        status: DeliveryStatus = .sent,
        timestamp: Date = Date(),
        conversation: Conversation? = nil
    ) {
        self.id = id
        self.sender = sender
        self.content = content
        self.typeRaw = type.rawValue
        self.mediaPath = mediaPath
        self.fileSize = fileSize
        self.statusRaw = status.rawValue
        self.timestamp = timestamp
        self.conversation = conversation
    }
}
