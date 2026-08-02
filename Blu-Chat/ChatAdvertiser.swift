import Foundation
import Combine
import MultipeerConnectivity

/// Handles advertising the device's presence to nearby peers using MultipeerConnectivity.
final class ChatAdvertiser: NSObject, ObservableObject, MCNearbyServiceAdvertiserDelegate {
    private let serviceType = "bluchat-msg"
    let myPeerID: MCPeerID
    private var advertiser: MCNearbyServiceAdvertiser?
    var onInvitationReceived: ((MCPeerID, Data?, @escaping (Bool, MCSession?)->Void) -> Void)?
    
    init(displayName: String) {
        self.myPeerID = MCPeerID(displayName: displayName)
        super.init()
    }
    
    /// Starts advertising the device
    func startAdvertising() {
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: serviceType)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
    }
    
    /// Stops advertising the device
    func stopAdvertising() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
    }
    
    // MARK: - MCNearbyServiceAdvertiserDelegate
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        onInvitationReceived?(peerID, context, invitationHandler)
    }
    
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("Failed to start advertising: \(error)")
    }
}
