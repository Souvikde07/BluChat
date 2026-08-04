//
//  ContentView.swift
//  BluChat
//
//  Created by Souvik De on 28/07/26.
//

import SwiftUI
import SwiftData
import MultipeerConnectivity
import PhotosUI
import UIKit
import Contacts
import Combine
import UniformTypeIdentifiers

// MARK: - Sendable Contact Model
struct ContactItem: Sendable, Identifiable {
    let id: String
    let givenName: String
    let familyName: String
    let phoneNumber: String
    
    var fullName: String {
        let name = "\(givenName) \(familyName)".trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Unknown" : name
    }
}

// MARK: - Contacts Manager
@MainActor
final class ContactsManager: ObservableObject {
    @Published var contacts: [ContactItem] = []
    @Published var authorizationStatus: CNAuthorizationStatus = .notDetermined
    
    private lazy var contactStore = CNContactStore()
    
    init() {}
    
    func checkAuthorization() {
        guard Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil else { return }
        authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
        if authorizationStatus == .authorized {
            fetchContacts()
        }
    }
    
    func requestAccess() async -> Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil else { return false }
        
        do {
            let granted = try await contactStore.requestAccess(for: .contacts)
            authorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
            if granted {
                fetchContacts()
            }
            return granted
        } catch {
            return false
        }
    }
    
    func fetchContacts() {
        guard Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil else { return }
        
        let store = self.contactStore
        Task.detached(priority: .userInitiated) {
            let keysToFetch: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor
            ]
            
            let fetchRequest = CNContactFetchRequest(keysToFetch: keysToFetch)
            var fetchedItems: [ContactItem] = []
            
            do {
                try store.enumerateContacts(with: fetchRequest) { contact, _ in
                    let phone = contact.phoneNumbers.first?.value.stringValue ?? ""
                    let item = ContactItem(
                        id: contact.identifier,
                        givenName: contact.givenName,
                        familyName: contact.familyName,
                        phoneNumber: phone
                    )
                    fetchedItems.append(item)
                }
                let results = fetchedItems
                await MainActor.run { [weak self] in
                    self?.contacts = results
                }
            } catch {
                print("Error fetching contacts: \(error)")
            }
        }
    }
    
    func matchedContactName(for peerDisplayName: String) -> String {
        let cleanedPeerName = peerDisplayName.lowercased().trimmingCharacters(in: .whitespaces)
        
        for contact in contacts {
            let name = contact.fullName.lowercased()
            if name.contains(cleanedPeerName) || cleanedPeerName.contains(name) {
                return contact.fullName
            }
        }
        return peerDisplayName
    }
    
    func addContact(firstName: String, lastName: String, phoneNumber: String) async -> Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil else { return false }
        
        let newContact = CNMutableContact()
        newContact.givenName = firstName
        newContact.familyName = lastName
        newContact.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: phoneNumber))
        ]
        
        let saveRequest = CNSaveRequest()
        saveRequest.add(newContact, toContainerWithIdentifier: nil)
        
        do {
            try contactStore.execute(saveRequest)
            fetchContacts()
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.id) private var conversations: [Conversation]
    
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @AppStorage("myCustomUserName") private var customUserName: String = UIDevice.current.name
    
    @StateObject private var multipeerManager: MultipeerManager
    @StateObject private var contactsManager = ContactsManager()
    
    @State private var selectedTab: Int = 0
    @State private var showingNewGroupSheet = false
    @State private var showingAddContactSheet = false
    @State private var selectedPeerForContact: MCPeerID?
    
    init() {
        let name = UserDefaults.standard.string(forKey: "myCustomUserName") ?? UIDevice.current.name
        _multipeerManager = StateObject(wrappedValue: MultipeerManager(myUser: User(name: name)))
    }
    
    var body: some View {
        Group {
            if !hasCompletedOnboarding {
                ProfileSetupView(
                    customUserName: $customUserName,
                    hasCompletedOnboarding: $hasCompletedOnboarding,
                    selectedTab: $selectedTab,
                    multipeerManager: multipeerManager,
                    contactsManager: contactsManager
                )
            } else {
                TabView(selection: $selectedTab) {
                    // MARK: - Tab 0: Chats
                    NavigationStack {
                        List {
                            if conversations.isEmpty {
                                ContentUnavailableView(
                                    "No Chats Yet",
                                    systemImage: "message.badge.circle",
                                    description: Text("Discovered nearby users will appear in the Nearby tab.")
                                )
                            } else {
                                Section("Recent Chats") {
                                    ForEach(conversations) { conversation in
                                        NavigationLink(destination: ChatDetailView(conversation: conversation, manager: multipeerManager)) {
                                            ConversationRow(conversation: conversation, myUserName: multipeerManager.myUser.name)
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
                    .tag(0)
                    
                    // MARK: - Tab 1: Nearby Peers
                    NavigationStack {
                        List {
                            Section("Discovered Nearby Users") {
                                if multipeerManager.availablePeers.isEmpty {
                                    HStack(spacing: 12) {
                                        ProgressView()
                                        Text("Searching for nearby devices...")
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.vertical, 8)
                                } else {
                                    ForEach(multipeerManager.availablePeers, id: \.displayName) { peer in
                                        PeerRow(
                                            peer: peer,
                                            multipeerManager: multipeerManager,
                                            contactsManager: contactsManager,
                                            onAddContact: {
                                                selectedPeerForContact = peer
                                                showingAddContactSheet = true
                                            },
                                            onStartChat: { contactName in
                                                multipeerManager.invitePeer(peer)
                                                startChatWithPeer(peer, displayName: contactName)
                                            }
                                        )
                                    }
                                }
                            }
                        }
                        .navigationTitle("Nearby")
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    multipeerManager.stop()
                                    multipeerManager.start()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                        }
                        .onAppear {
                            multipeerManager.start()
                        }
                        .sheet(isPresented: $showingAddContactSheet) {
                            if let peer = selectedPeerForContact {
                                AddContactSheet(peerName: peer.displayName, contactsManager: contactsManager)
                            }
                        }
                    }
                    .tabItem {
                        Label("Nearby", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .tag(1)
                    
                    // MARK: - Tab 2: Settings & Profile
                    NavigationStack {
                        SettingsView(multipeerManager: multipeerManager)
                    }
                    .tabItem {
                        Label("Settings", systemImage: "gearshape.fill")
                    }
                    .tag(2)
                }
            }
        }
        .onAppear {
            multipeerManager.setModelContext(modelContext)
            if hasCompletedOnboarding {
                multipeerManager.start()
                contactsManager.checkAuthorization()
            }
        }
        .onDisappear {
            multipeerManager.stop()
        }
    }
    
    private func startChatWithPeer(_ peer: MCPeerID, displayName: String) {
        let descriptor = FetchDescriptor<User>()
        let existingUsers = (try? modelContext.fetch(descriptor)) ?? []
        
        let peerUser: User
        if let found = existingUsers.first(where: { $0.name == displayName }) {
            peerUser = found
        } else {
            peerUser = User(name: displayName)
            modelContext.insert(peerUser)
        }
        
        let convDescriptor = FetchDescriptor<Conversation>()
        let existingConvs = (try? modelContext.fetch(convDescriptor)) ?? []
        
        let conversation: Conversation
        if let foundConv = existingConvs.first(where: { !$0.isGroup && $0.participants.contains(where: { $0.name == displayName }) }) {
            conversation = foundConv
        } else {
            conversation = Conversation(participants: [multipeerManager.myUser, peerUser])
            modelContext.insert(conversation)
        }
        
        selectedTab = 0
    }
}

// MARK: - Onboarding Profile Setup View
struct ProfileSetupView: View {
    @Binding var customUserName: String
    @Binding var hasCompletedOnboarding: Bool
    @Binding var selectedTab: Int
    @ObservedObject var multipeerManager: MultipeerManager
    @ObservedObject var contactsManager: ContactsManager
    
    @State private var inputName: String = ""
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .foregroundColor(.accentColor)
            
            VStack(spacing: 8) {
                Text("Welcome to BluChat")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Offline messaging over Bluetooth and Wi-Fi Direct. No internet required.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 24)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter Your Display Name")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                
                TextField("Your Name", text: $inputName)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
            }
            .padding(.horizontal, 32)
            .padding(.top, 16)
            
            Spacer()
            
            Button {
                let trimmed = inputName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    customUserName = trimmed
                    multipeerManager.myUser.name = trimmed
                }
                
                selectedTab = 1
                hasCompletedOnboarding = true
                multipeerManager.start()
                
                Task {
                    _ = await contactsManager.requestAccess()
                }
            } label: {
                Text("Get Started")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(inputName.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray : Color.accentColor)
                    .cornerRadius(14)
            }
            .disabled(inputName.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .onAppear {
            inputName = customUserName
        }
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("myCustomUserName") private var customUserName: String = UIDevice.current.name
    @ObservedObject var multipeerManager: MultipeerManager
    
    @State private var tempName: String = ""
    @State private var showingClearAlert = false
    
    var body: some View {
        Form {
            Section("Profile") {
                HStack(spacing: 16) {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .frame(width: 60, height: 60)
                        .foregroundColor(.accentColor)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(customUserName)
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Visible to nearby Bluetooth devices")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
                
                HStack {
                    Text("Display Name")
                    Spacer()
                    TextField("Your Name", text: $tempName, onCommit: {
                        if !tempName.trimmingCharacters(in: .whitespaces).isEmpty {
                            customUserName = tempName
                            multipeerManager.myUser.name = tempName
                        }
                    })
                    .multilineTextAlignment(.trailing)
                    .foregroundColor(.secondary)
                }
            }
            
            Section("Connectivity") {
                HStack {
                    Label("Bluetooth Status", systemImage: "bluetooth")
                    Spacer()
                    Text("Active")
                        .foregroundColor(.green)
                }
                HStack {
                    Label("Connected Peers", systemImage: "link")
                    Spacer()
                    Text("\(multipeerManager.connectedPeers.count)")
                        .foregroundColor(.secondary)
                }
            }
            
            Section("Storage & Privacy") {
                Button(role: .destructive) {
                    showingClearAlert = true
                } label: {
                    Label("Clear All Chat History", systemImage: "trash")
                }
            }
            
            Section("About") {
                HStack {
                    Text("App Version")
                    Spacer()
                    Text("1.0.0 (Offline)")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            tempName = customUserName
        }
        .alert("Clear Chat History?", isPresented: $showingClearAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                clearAllConversations()
            }
        } message: {
            Text("This will permanently delete all messages and conversations stored on this device.")
        }
    }
    
    private func clearAllConversations() {
        try? modelContext.delete(model: Conversation.self)
        try? modelContext.delete(model: Message.self)
    }
}

// MARK: - Peer Row Component
struct PeerRow: View {
    let peer: MCPeerID
    @ObservedObject var multipeerManager: MultipeerManager
    @ObservedObject var contactsManager: ContactsManager
    let onAddContact: () -> Void
    let onStartChat: (String) -> Void
    
    var body: some View {
        let contactName = contactsManager.matchedContactName(for: peer.displayName)
        let isContact = contactName != peer.displayName
        
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(contactName)
                    .font(.headline)
                if isContact {
                    Text("Contact found")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
                Text(multipeerManager.connectedPeers.contains(peer) ? "Connected" : "Available")
                    .font(.caption)
                    .foregroundColor(multipeerManager.connectedPeers.contains(peer) ? .green : .secondary)
            }
            Spacer()
            
            if !isContact {
                Button {
                    onAddContact()
                } label: {
                    Image(systemName: "person.badge.plus")
                }
                .buttonStyle(.bordered)
            }
            
            Button("Chat") {
                onStartChat(contactName)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Add Contact Sheet
struct AddContactSheet: View {
    let peerName: String
    @ObservedObject var contactsManager: ContactsManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var firstName: String = ""
    @State private var lastName: String = ""
    @State private var phoneNumber: String = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Contact Info") {
                    TextField("First Name", text: $firstName)
                    TextField("Last Name", text: $lastName)
                    TextField("Phone Number", text: $phoneNumber)
                        .keyboardType(.phonePad)
                }
            }
            .navigationTitle("Add Contact")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                let parts = peerName.components(separatedBy: " ")
                firstName = parts.first ?? peerName
                if parts.count > 1 {
                    lastName = parts.suffix(from: 1).joined(separator: " ")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            _ = await contactsManager.addContact(
                                firstName: firstName,
                                lastName: lastName,
                                phoneNumber: phoneNumber
                            )
                            dismiss()
                        }
                    }
                    .disabled(firstName.isEmpty)
                }
            }
        }
    }
}

// MARK: - Conversation Row Component
struct ConversationRow: View {
    let conversation: Conversation
    let myUserName: String
    
    var otherParticipantsTitle: String {
        if conversation.isGroup {
            return conversation.name ?? "Group Chat"
        }
        let otherNames = conversation.participants
            .map { $0.name }
            .filter { $0 != myUserName }
        
        return otherNames.isEmpty ? (conversation.name ?? "Chat") : otherNames.joined(separator: ", ")
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: conversation.isGroup ? "person.3.circle.fill" : "person.circle.fill")
                .resizable()
                .frame(width: 45, height: 45)
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(otherParticipantsTitle)
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
    @State private var showingFileImporter = false
    @State private var showingErrorAlert = false
    @State private var errorMessage: String = ""
    
    var recipientTitle: String {
        if conversation.isGroup {
            return conversation.name ?? "Group Chat"
        }
        let otherNames = conversation.participants
            .map { $0.name }
            .filter { $0 != manager.myUser.name }
        
        return otherNames.isEmpty ? (conversation.name ?? "Chat") : otherNames.joined(separator: ", ")
    }
    
    var body: some View {
        VStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(conversation.messages.sorted(by: { $0.timestamp < $1.timestamp })) { message in
                            MessageBubble(message: message, isFromCurrentUser: message.sender.name == manager.myUser.name)
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
                Menu {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .any(of: [.images, .videos])) {
                        Label("Photo or Video", systemImage: "photo")
                    }
                    
                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("Document or File", systemImage: "doc")
                    }
                } label: {
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
        .navigationTitle(recipientTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            manager.markConversationAsRead(conversation)
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let selectedURL = urls.first {
                    handleSelectedFile(selectedURL)
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
                showingErrorAlert = true
            }
        }
        .alert("Attachment Error", isPresented: $showingErrorAlert) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
    }
    
    private func handleSelectedPhoto(_ item: PhotosPickerItem?) async {
        guard let item = item else { return }
        if let data = try? await item.loadTransferable(type: Data.self) {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
            try? data.write(to: tempURL)
            
            do {
                try manager.sendMediaFile(fileURL: tempURL, type: .image, to: conversation)
            } catch {
                errorMessage = error.localizedDescription
                showingErrorAlert = true
            }
        }
    }
    
    private func handleSelectedFile(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Unable to access selected file permissions."
            showingErrorAlert = true
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: tempURL)
        
        do {
            try FileManager.default.copyItem(at: url, to: tempURL)
            try manager.sendMediaFile(fileURL: tempURL, type: .file, to: conversation)
        } catch {
            errorMessage = error.localizedDescription
            showingErrorAlert = true
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
                else if message.type == .file, let path = message.mediaPath {
                    let fileName = URL(fileURLWithPath: path).lastPathComponent
                    let fileSizeFormatted = ByteCountFormatter.string(fromByteCount: message.fileSize, countStyle: .file)
                    
                    HStack(spacing: 10) {
                        Image(systemName: "doc.fill")
                            .font(.title2)
                            .foregroundColor(isFromCurrentUser ? .white : .accentColor)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fileName)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(fileSizeFormatted)
                                .font(.caption2)
                                .opacity(0.8)
                        }
                    }
                    .padding(10)
                    .background(isFromCurrentUser ? Color.accentColor : Color(.systemGray5))
                    .foregroundColor(isFromCurrentUser ? .white : .primary)
                    .cornerRadius(12)
                }
                
                if !message.content.isEmpty {
                    Text(message.content)
                        .padding(10)
                        .background(isFromCurrentUser ? Color.accentColor : Color(.systemGray5))
                        .foregroundColor(isFromCurrentUser ? .white : .primary)
                        .cornerRadius(16)
                }
                
                HStack(spacing: 4) {
                    Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    if isFromCurrentUser {
                        switch message.status {
                        case .sending:
                            Image(systemName: "clock")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        case .sent:
                            Image(systemName: "checkmark")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        case .read:
                            HStack(spacing: -6) {
                                Image(systemName: "checkmark")
                                Image(systemName: "checkmark")
                            }
                            .font(.caption2)
                            .foregroundColor(.blue)
                        case .failed:
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                    }
                }
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
