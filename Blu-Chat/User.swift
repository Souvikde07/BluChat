import Foundation
import SwiftData

@Model
final class User {
    @Attribute(.unique) var id: UUID
    var name: String
    var contactID: String? // e.g. phone number or Contacts identifier
    // Add other user properties as needed
    
    init(id: UUID = UUID(), name: String, contactID: String? = nil) {
        self.id = id
        self.name = name
        self.contactID = contactID
    }
}
