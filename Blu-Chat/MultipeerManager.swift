import Foundation
import MultipeerConnectivity
import SwiftData
import Combine

/// Payload wrapper sent over the network for text messages and file metadata.
struct NetworkMessage: Codable {
    let id: UUID
    let senderID: UUID
    let senderName: String
    let conversationID: UUID
    let content: String
    let type: MessageType
    let fileSize: Int64
    let timestamp: Date
}

@MainActor
final class MultipeerManager: ObservableObject {
    @Published var connectedPeers: [MCPeerID] = []
    @Published var availablePeers: [MCPeerID] = []
    
    let myUser: User
    let advertiser: ChatAdvertiser
    let browser: ChatBrowser
    let sessionManager: SessionManager
    
    private var modelContext: ModelContext?
    
    init(myUser: User) {
        self.myUser = myUser
        
        let peerID = MCPeerID(displayName: myUser.name)
        self.advertiser = ChatAdvertiser(displayName: myUser.name)
        self.browser = ChatBrowser(displayName: myUser.name)
        self.sessionManager = SessionManager(myPeerID: peerID)
        
        setupHandlers()
    }
    
    /// Assigns the SwiftData ModelContext for persistent message saving.
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }
    
    /// Starts advertising and browsing for nearby peers.
    func start() {
        advertiser.startAdvertising()
        browser.startBrowsing()
    }
    
    /// Stops all networking activities.
    func stop() {
        advertiser.stopAdvertising()
        browser.stopBrowsing()
        sessionManager.session.disconnect()
    }
    
    // MARK: - Handlers Setup
    private func setupHandlers() {
        // Discovered peers
        browser.onPeerFound = { [weak self] peer in
            guard let self = self else { return }
            if !self.availablePeers.contains(peer) {
                self.availablePeers.append(peer)
            }
        }
        
        browser.onPeerLost = { [weak self] peer in
            guard let self = self else { return }
            self.availablePeers.removeAll { $0 == peer }
        }
        
        // Incoming invitations (Auto-accept)
        advertiser.onInvitationReceived = { [weak self] peer, context, invitationHandler in
            guard let self = self else { return }
            invitationHandler(true, self.sessionManager.session)
        }
        
        // MCSession State changes
        sessionManager.onPeerStateChanged = { [weak self] peer, state in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch state {
                case .connected:
                    if !self.connectedPeers.contains(peer) {
                        self.connectedPeers.append(peer)
                    }
                case .notConnected:
                    self.connectedPeers.removeAll { $0 == peer }
                case .connecting:
                    break
                @unknown default:
                    break
                }
            }
        }
        
        // Received JSON Message
        sessionManager.onDataReceived = { [weak self] data, peer in
            Task { @MainActor [weak self] in
                self?.handleReceivedData(data)
            }
        }
        
        // Received Media File / Resource
        sessionManager.onResourceReceived = { [weak self] localURL, peer in
            Task { @MainActor [weak self] in
                self?.handleReceivedResource(at: localURL)
            }
        }
    }
    
    // MARK: - Peer Connections
    func invitePeer(_ peer: MCPeerID) {
        browser.invite(peer: peer, to: sessionManager.session)
    }
    
    // MARK: - Message Sending
    
    /// Sends a text message to specified recipients and saves locally.
    func sendTextMessage(_ text: String, to conversation: Conversation) {
        guard let context = modelContext else { return }
        
        let message = Message(
            sender: myUser,
            content: text,
            type: .text,
            status: .sent,
            timestamp: Date(),
            conversation: conversation
        )
        context.insert(message)
        
        let payload = NetworkMessage(
            id: message.id,
            senderID: myUser.id,
            senderName: myUser.name,
            conversationID: conversation.id,
            content: text,
            type: .text,
            fileSize: 0,
            timestamp: message.timestamp
        )
        
        if let data = try? JSONEncoder().encode(payload) {
            let targetPeers = sessionManager.session.connectedPeers
            try? sessionManager.send(data: data, to: targetPeers)
        }
    }
    
    /// Sends media (Image, Video, or File up to 100MB) over MCSession.
    func sendMediaFile(fileURL: URL, type: MessageType, caption: String = "", to conversation: Conversation) throws {
        let maxLimit: Int64 = 100 * 1024 * 1024 // 100 MB
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (fileAttributes[.size] as? Int64) ?? 0
        
        guard fileSize <= maxLimit else {
            throw NSError(
                domain: "MultipeerManager",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "File size exceeds the maximum limit of 100 MB."]
            )
        }
        
        guard let context = modelContext else { return }
        
        let message = Message(
            sender: myUser,
            content: caption,
            type: type,
            mediaPath: fileURL.lastPathComponent,
            fileSize: fileSize,
            status: .sending,
            timestamp: Date(),
            conversation: conversation
        )
        context.insert(message)
        
        let targetPeers = sessionManager.session.connectedPeers
        
        for peer in targetPeers {
            let resourceName = "\(message.id.uuidString)|\(myUser.id.uuidString)|\(conversation.id.uuidString)|\(type.rawValue)|\(caption)"
            sessionManager.session.sendResource(at: fileURL, withName: resourceName, toPeer: peer) { error in
                Task { @MainActor in
                    if let error = error {
                        print("Failed sending resource to \(peer.displayName): \(error)")
                        message.status = .failed
                    } else {
                        message.status = .sent
                    }
                }
            }
        }
    }
    
    // MARK: - Incoming Data Processing
    private func handleReceivedData(_ data: Data) {
        guard let context = modelContext,
              let payload = try? JSONDecoder().decode(NetworkMessage.self, from: data) else { return }
        
        let sender = fetchOrCreateUser(id: payload.senderID, name: payload.senderName)
        let conversation = fetchOrCreateConversation(id: payload.conversationID, sender: sender)
        
        let message = Message(
            id: payload.id,
            sender: sender,
            content: payload.content,
            type: payload.type,
            fileSize: payload.fileSize,
            status: .sent,
            timestamp: payload.timestamp,
            conversation: conversation
        )
        context.insert(message)
    }
    
    private func handleReceivedResource(at localURL: URL) {
        guard let context = modelContext else { return }
        
        // Parse metadata encoded in resource name
        let resourceName = localURL.lastPathComponent
        let components = resourceName.components(separatedBy: "|")
        
        guard components.count >= 5 else {
            // Save plain received file locally
            return
        }
        
        let messageID = UUID(uuidString: components[0]) ?? UUID()
        let senderID = UUID(uuidString: components[1]) ?? UUID()
        let conversationID = UUID(uuidString: components[2]) ?? UUID()
        let type = MessageType(rawValue: components[3]) ?? .file
        let caption = components[4]
        
        // Copy file to local Documents directory for persistent storage
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = documentsDirectory.appendingPathComponent("\(messageID.uuidString)_\(localURL.lastPathComponent)")
        
        try? FileManager.default.moveItem(at: localURL, to: destinationURL)
        
        let sender = fetchOrCreateUser(id: senderID, name: "Peer")
        let conversation = fetchOrCreateConversation(id: conversationID, sender: sender)
        
        let message = Message(
            id: messageID,
            sender: sender,
            content: caption,
            type: type,
            mediaPath: destinationURL.path,
            status: .sent,
            timestamp: Date(),
            conversation: conversation
        )
        context.insert(message)
    }
    
    // MARK: - SwiftData Helpers
    private func fetchOrCreateUser(id: UUID, name: String) -> User {
        guard let context = modelContext else { return User(id: id, name: name) }
        
        let descriptor = FetchDescriptor<User>(predicate: #Predicate { $0.id == id })
        if let existingUser = try? context.fetch(descriptor).first {
            return existingUser
        }
        let newUser = User(id: id, name: name)
        context.insert(newUser)
        return newUser
    }
    
    private func fetchOrCreateConversation(id: UUID, sender: User) -> Conversation {
        guard let context = modelContext else {
            return Conversation(id: id, participants: [myUser, sender])
        }
        
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let newConversation = Conversation(id: id, participants: [myUser, sender])
        context.insert(newConversation)
        return newConversation
    }
}
