/// Message type strings carried in `Envelope.type`. See protocol/SPEC.md section 3.
public enum MessageType: String, CaseIterable, Sendable {
    case hello = "system.hello"
    case ping = "system.ping"
    case pong = "system.pong"
    case error = "system.error"
    case goodbye = "system.goodbye"
    case pairRequest = "pairing.request"
    case pairVerified = "pairing.verified"
    case pairConfirm = "pairing.confirm"
    case pairComplete = "pairing.complete"
    case statusUpdate = "status.update"
    case findRing = "find.ring"
    case findStop = "find.stop"
    case findState = "find.state"
}
