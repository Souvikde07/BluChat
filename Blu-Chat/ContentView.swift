//
//  ContentView.swift
//  Blu-Chat
//
//  Created by Souvik De on 28/07/26.
//

import SwiftUI
import SwiftData
import MultipeerConnectivity
import PhotosUI
import UIKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.id) private var conversations: [Conversation]
    
    @StateObject private var multipeerManager = MultipeerManager(
        myUser: User(name: UIDevice.current.name)
    )
    
    @State private var showingNewGroupSheet = false
    @State private var selectedConversation: Conversation?
    
    var body: some View {
        TabView {
            // MARK: - Tab 1: Chats
            NavigationStack {
                List {
                    if conversations.isEmpty {
                        ContentUnavailableView(
                            "No Chats Yet",
                            systemImage: "message.badge.circle",
                            description: Text("Discovered nearby users will appear in the Nearby tab below.")
                        )
                    } else {
                        Section("Recent Chats") {
                            ForEach(conversations) { conversation in
                                NavigationLink(destination: ChatDetailView(conversation: conversation, manager: multipeerManager)) {
                                    ConversationRow(conversation: conversation)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Chats")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingNewGroupSheet = true
                        } label: {
                            Image(systemName: "person.3.fill")
                        }
                    }
                }
                .sheet(isPresented: $showingNewGroupSheet) {
                    NewGroupView(manager: multipeerManager)
                }
            }
            .tabItem {
                Label("Chats", systemImage: "bubble.left.and.bubble.right.fill")
            }
            
            // MARK: - Tab 2: Nearby Peers
            NavigationStack {
                List {
                    Section("Discovered Nearby Users") {
                        if multipeerManager.availablePeers.isEmpty {
                            Text("Searching for nearby Bluetooth devices...")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(multipeerManager.availablePeers, id: \.displayName) { peer in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(peer.displayName)
                                            .font(.headline)
                                        Text(multipeerManager.connectedPeers.contains(peer) ? "Connected" : "Available")
                                            .font(.caption)
                                            .foregroundColor(multipeerManager.connectedPeers.contains(peer) ? .green : .secondary)
                                    }
                                    Spacer()
                                    Button("Chat") {
                                        multipeerManager.invitePeer(peer)
                                        startChatWithPeer(peer)
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Nearby")
            }
            .tabItem {
                Label("Nearby", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
        .onAppear {
            multipeerManager.setModelContext(modelContext)
            multipeerManager.start()
        }
        .onDisappear {
            multipeerManager.stop()
        }
    }
    
    private func startChatWithPeer(_ peer: MCPeerID) {
        let peerUser = User(name: peer.displayName)
        modelContext.insert(peerUser)
        
        let newConversation = Conversation(participants: [multipeerManager.myUser, peerUser])
        modelContext.insert(newConversation)
    }
}

// MARK: - Conversation Row Component
struct ConversationRow: View {
    let conversation: Conversation
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: conversation.isGroup ? "person.3.circle.fill" : "person.circle.fill")
                .resizable()
                .frame(width: 45, height: 45)
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.name ?? conversation.participants.compactMap { $0.name }.joined(separator: ", "))
                    .font(.headline)
                
                if let lastMessage = conversation.messages.last {
                    Text(lastMessage.content.isEmpty ? "Media File" : lastMessage.content)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text("No messages yet")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Chat Detail View
struct ChatDetailView: View {
    let conversation: Conversation
    @ObservedObject var manager: MultipeerManager
    
    @State private var messageText: String = ""
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var errorMessage: String?
    
    var body: some View {
        VStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(conversation.messages.sorted(by: { $0.timestamp < $1.timestamp })) { message in
                            MessageBubble(message: message, isFromCurrentUser: message.sender.id == manager.myUser.id)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: conversation.messages.count) { _, _ in
                    if let lastMessage = conversation.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            HStack(spacing: 8) {
                PhotosPicker(selection: $selectedPhotoItem, matching: .any(of: [.images, .videos])) {
                    Image(systemName: "paperclip")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                }
                .onChange(of: selectedPhotoItem) { _, newItem in
                    Task {
                        await handleSelectedPhoto(newItem)
                    }
                }
                
                TextField("Message", text: $messageText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                
                Button {
                    guard !messageText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    manager.sendTextMessage(messageText, to: conversation)
                    messageText = ""
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                }
            }
            .padding()
            .background(.thinMaterial)
        }
        .navigationTitle(conversation.name ?? conversation.participants.filter { $0.id != manager.myUser.id }.map { $0.name }.joined(separator: ", "))
        .navigationBarTitleDisplayMode(.inline)
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
    
    private func handleSelectedPhoto(_ item: PhotosPickerItem?) async {
        guard let item = item else { return }
        if let data = try? await item.loadTransferable(type: Data.self) {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            try? data.write(to: tempURL)
            
            do {
                try manager.sendMediaFile(fileURL: tempURL, type: .image, to: conversation)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Message Bubble
struct MessageBubble: View {
    let message: Message
    let isFromCurrentUser: Bool
    
    var body: some View {
        HStack {
            if isFromCurrentUser { Spacer() }
            
            VStack(alignment: isFromCurrentUser ? .trailing : .leading, spacing: 4) {
                if message.type == .image, let path = message.mediaPath, let uiImage = UIImage(contentsOfFile: path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220)
                        .cornerRadius(8)
                }
                
                if !message.content.isEmpty {
                    Text(message.content)
                        .padding(10)
                        .background(isFromCurrentUser ? Color.accentColor : Color(.systemGray5))
                        .foregroundColor(isFromCurrentUser ? .white : .primary)
                        .cornerRadius(16)
                }
                
                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            if !isFromCurrentUser { Spacer() }
        }
    }
}

// MARK: - New Group View
struct NewGroupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var manager: MultipeerManager
    
    @State private var groupName: String = ""
    @State private var selectedPeers: Set<String> = []
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Group Info") {
                    TextField("Group Name", text: $groupName)
                }
                
                Section("Select Nearby Contacts") {
                    ForEach(manager.availablePeers, id: \.displayName) { peer in
                        HStack {
                            Text(peer.displayName)
                            Spacer()
                            if selectedPeers.contains(peer.displayName) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedPeers.contains(peer.displayName) {
                                selectedPeers.remove(peer.displayName)
                            } else {
                                selectedPeers.insert(peer.displayName)
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createGroup()
                        dismiss()
                    }
                    .disabled(groupName.isEmpty || selectedPeers.isEmpty)
                }
            }
        }
    }
    
    private func createGroup() {
        let participants = selectedPeers.map { name in
            User(name: name)
        } + [manager.myUser]
        
        let newGroup = Conversation(
            name: groupName,
            participants: participants,
            isGroup: true
        )
        modelContext.insert(newGroup)
    }
}

#Preview {
    ContentView()
}
