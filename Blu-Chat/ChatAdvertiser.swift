import Foundation
import Combine
import MultipeerConnectivity

final class ChatAdvertiser: NSObject, ObservableObject, MCNearbyServiceAdvertiserDelegate {
    private let serviceType = "bluchat-msg"
    let myPeerID: MCPeerID
    private var advertiser: MCNearbyServiceAdvertiser?
    var onInvitationReceived: ((MCPeerID, Data?, @escaping (Bool, MCSession?)->Void) -> Void)?
    
    init(displayName: String) {
        self.myPeerID = MCPeerID(displayName: displayName)
        super.init()
    }
    
    func startAdvertising() {
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: serviceType)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()
    }
    
    func stopAdvertising() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
    }
    
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        onInvitationReceived?(peerID, context, invitationHandler)
    }
    
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("Advertiser Error: \(error.localizedDescription)")
    }
}
