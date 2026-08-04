import Foundation
import MultipeerConnectivity
import SwiftData
import Combine

/// Payload wrapper sent over the network for text messages, file metadata, and read receipts.
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
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }
    
    func start() {
        advertiser.startAdvertising()
        browser.startBrowsing()
    }
    
    func stop() {
        advertiser.stopAdvertising()
        browser.stopBrowsing()
        sessionManager.session.disconnect()
    }
    
    private func setupHandlers() {
        browser.onPeerFound = { [weak self] peer in
            guard let self = self else { return }
            let isSelf = peer == self.sessionManager.myPeerID || peer.displayName == self.myUser.name
            if !isSelf && !self.availablePeers.contains(peer) {
                self.availablePeers.append(peer)
            }
        }
        
        browser.onPeerLost = { [weak self] peer in
            guard let self = self else { return }
            self.availablePeers.removeAll { $0 == peer }
        }
        
        advertiser.onInvitationReceived = { [weak self] peer, _, invitationHandler in
            guard let self = self else { return }
            // Always auto-accept invitations into the shared MCSession
            invitationHandler(true, self.sessionManager.session)
        }
        
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
        
        sessionManager.onDataReceived = { [weak self] data, _ in
            Task { @MainActor [weak self] in
                self?.handleReceivedData(data)
            }
        }
        
        sessionManager.onResourceReceived = { [weak self] localURL, _ in
            Task { @MainActor [weak self] in
                self?.handleReceivedResource(at: localURL)
            }
        }
    }
    
    func invitePeer(_ peer: MCPeerID) {
        // Invite peer into session if not already connected or connecting
        if !sessionManager.session.connectedPeers.contains(peer) {
            browser.invite(peer: peer, to: sessionManager.session)
        }
    }
    
    func sendTextMessage(_ text: String, to conversation: Conversation) {
        guard let context = modelContext else { return }
        
        let message = Message(
            sender: myUser,
            content: text,
            type: .text,
            status: .sending,
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
        
        let targetPeers = sessionManager.session.connectedPeers
        guard !targetPeers.isEmpty else {
            print("Warning: MCSession not in connected state yet. Retrying when connection completes.")
            message.status = .failed
            return
        }
        
        if let data = try? JSONEncoder().encode(payload) {
            do {
                try sessionManager.send(data: data, to: targetPeers)
                message.status = .sent
            } catch {
                print("Failed to send message over MCSession: \(error)")
                message.status = .failed
            }
        }
    }
    
    func markConversationAsRead(_ conversation: Conversation) {
        guard let context = modelContext else { return }
        
        let unreadMessages = conversation.messages.filter { $0.sender.id != myUser.id && $0.status != .read }
        for msg in unreadMessages {
            msg.status = .read
        }
        
        let targetPeers = sessionManager.session.connectedPeers
        guard !targetPeers.isEmpty else { return }
        
        let payload = NetworkMessage(
            id: UUID(),
            senderID: myUser.id,
            senderName: myUser.name,
            conversationID: conversation.id,
            content: "",
            type: .readReceipt,
            fileSize: 0,
            timestamp: Date()
        )
        
        if let data = try? JSONEncoder().encode(payload) {
            try? sessionManager.send(data: data, to: targetPeers)
        }
    }
    
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
        
        let targetPeers = sessionManager.session.connectedPeers
        guard !targetPeers.isEmpty else {
            throw NSError(
                domain: "MultipeerManager",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "No connected peer found. Please wait for connection to establish."]
            )
        }
        
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
    
    private func handleReceivedData(_ data: Data) {
        guard let context = modelContext,
              let payload = try? JSONDecoder().decode(NetworkMessage.self, from: data) else { return }
        
        if payload.type == .readReceipt {
            let descriptor = FetchDescriptor<Conversation>()
            if let conversations = try? context.fetch(descriptor) {
                for conversation in conversations {
                    for msg in conversation.messages where msg.sender.id == myUser.id {
                        msg.status = .read
                    }
                }
            }
            return
        }
        
        let sender = fetchOrCreateUser(id: payload.senderID, name: payload.senderName)
        let conversation = findOrCreateConversationForSender(sender: sender)
        
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
        
        let resourceName = localURL.lastPathComponent
        let components = resourceName.components(separatedBy: "|")
        
        guard components.count >= 5 else { return }
        
        let messageID = UUID(uuidString: components[0]) ?? UUID()
        let senderID = UUID(uuidString: components[1]) ?? UUID()
        let type = MessageType(rawValue: components[3]) ?? .file
        let caption = components[4]
        
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = documentsDirectory.appendingPathComponent("\(messageID.uuidString)_\(localURL.lastPathComponent)")
        
        try? FileManager.default.moveItem(at: localURL, to: destinationURL)
        
        let sender = fetchOrCreateUser(id: senderID, name: "Peer")
        let conversation = findOrCreateConversationForSender(sender: sender)
        
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
    
    private func fetchOrCreateUser(id: UUID, name: String) -> User {
        guard let context = modelContext else { return User(id: id, name: name) }
        
        let descriptor = FetchDescriptor<User>()
        let users = (try? context.fetch(descriptor)) ?? []
        if let existingUser = users.first(where: { $0.id == id || $0.name == name }) {
            return existingUser
        }
        let newUser = User(id: id, name: name)
        context.insert(newUser)
        return newUser
    }
    
    private func findOrCreateConversationForSender(sender: User) -> Conversation {
        guard let context = modelContext else {
            return Conversation(participants: [myUser, sender])
        }
        
        let descriptor = FetchDescriptor<Conversation>()
        let existingConvs = (try? context.fetch(descriptor)) ?? []
        
        if let existing = existingConvs.first(where: { !$0.isGroup && $0.participants.contains(where: { $0.name == sender.name }) }) {
            return existing
        }
        
        let newConversation = Conversation(participants: [myUser, sender])
        context.insert(newConversation)
        return newConversation
    }
}
