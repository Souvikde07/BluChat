import Foundation
import MultipeerConnectivity
import Combine

@MainActor
final class ChatBrowser: NSObject, ObservableObject, MCNearbyServiceBrowserDelegate {
    private let serviceType = "bluchat-msg"
    let myPeerID: MCPeerID
    private var browser: MCNearbyServiceBrowser?
    
    @Published var discoveredPeers: [MCPeerID] = []
    
    /// Callback when a peer is found
    var onPeerFound: ((MCPeerID) -> Void)?
    /// Callback when a peer is lost
    var onPeerLost: ((MCPeerID) -> Void)?
    /// Callback when a peer invites (initiates connection)
    var onInvitePeer: ((MCPeerID, @escaping (Bool, MCSession?) -> Void) -> Void)?
    
    init(displayName: String) {
        self.myPeerID = MCPeerID(displayName: displayName)
        super.init()
    }
    
    /// Starts browsing for nearby peers
    func startBrowsing() {
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
    }
    
    /// Stops browsing for nearby peers
    func stopBrowsing() {
        browser?.stopBrowsingForPeers()
        browser = nil
    }
    
    // MARK: - MCNearbyServiceBrowserDelegate
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        if !discoveredPeers.contains(peerID) {
            discoveredPeers.append(peerID)
        }
        onPeerFound?(peerID)
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        if let index = discoveredPeers.firstIndex(of: peerID) {
            discoveredPeers.remove(at: index)
        }
        onPeerLost?(peerID)
    }
    
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("Failed to start browsing: \(error)")
    }
    
    /// Initiate invitation to a discovered peer
    func invite(peer: MCPeerID, to session: MCSession, with context: Data? = nil, timeout: TimeInterval = 30) {
        browser?.invitePeer(peer, to: session, withContext: context, timeout: timeout)
    }
}
