import Foundation
import MultipeerConnectivity

/// Manages the MCSession, handles connections, sending, and receiving data.
final class SessionManager: NSObject, MCSessionDelegate {
    let myPeerID: MCPeerID
    let session: MCSession
    
    /// Callback when data is received from a peer
    var onDataReceived: ((Data, MCPeerID) -> Void)?
    /// Callback when peer connection state changes
    var onPeerStateChanged: ((MCPeerID, MCSessionState) -> Void)?
    /// Callback when a resource is received
    var onResourceReceived: ((URL, MCPeerID) -> Void)?
    
    init(myPeerID: MCPeerID) {
        self.myPeerID = myPeerID
        self.session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        self.session.delegate = self
    }
    
    // MARK: - Sending Data
    func send(data: Data, to peers: [MCPeerID], reliably: Bool = true) throws {
        let mode: MCSessionSendDataMode = reliably ? .reliable : .unreliable
        try session.send(data, toPeers: peers, with: mode)
    }
    
    // MARK: - MCSessionDelegate
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        onPeerStateChanged?(peerID, state)
    }
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        onDataReceived?(data, peerID)
    }
    
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // Not used for now
    }
    
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        // Not used for now
    }
    
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        if let url = localURL {
            onResourceReceived?(url, peerID)
        }
    }
    
    func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true)
    }
}
