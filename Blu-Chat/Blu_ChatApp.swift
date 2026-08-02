//
//  BluChatApp.swift
//  BluChat
//
//  Created by Souvik De on 28/07/26.
//

import SwiftUI
import SwiftData

@main
struct BluChatApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [User.self, Conversation.self, Message.self])
    }
}
