import Foundation
import MultipeerConnectivity
import Combine

@MainActor
final class ChatBrowser: NSObject, ObservableObject, MCNearbyServiceBrowserDelegate {
    private let serviceType = "bluchat-msg"
    let myPeerID: MCPeerID
    private var browser: MCNearbyServiceBrowser?
    
    @Published var discoveredPeers: [MCPeerID] = []
    
    var onPeerFound: ((MCPeerID) -> Void)?
    var onPeerLost: ((MCPeerID) -> Void)?
    
    init(displayName: String) {
        self.myPeerID = MCPeerID(displayName: displayName)
        super.init()
    }
    
    func startBrowsing() {
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
    }
    
    func stopBrowsing() {
        browser?.stopBrowsingForPeers()
        browser = nil
    }
    
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
        print("Browser Error: \(error.localizedDescription)")
    }
    
    func invite(peer: MCPeerID, to session: MCSession, with context: Data? = nil, timeout: TimeInterval = 30) {
        browser?.invitePeer(peer, to: session, withContext: context, timeout: timeout)
    }
}
