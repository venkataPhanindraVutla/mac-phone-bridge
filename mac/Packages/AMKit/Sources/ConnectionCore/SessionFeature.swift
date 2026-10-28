import AMProtocol

/// A Mac feature model that lives for the phone session: told when the phone connects and
/// disconnects, handed every phone message whose type starts with one of
/// `messagePrefixes`, and told when a phone is forgotten. Called in arrival order through
/// the app's single ordered work queue.
@MainActor
public protocol SessionFeature: AnyObject {
    /// Message type prefixes this feature handles, e.g. `["files."]`.
    var messagePrefixes: [String] { get }
    func connected(phoneID: String, phoneName: String, shared: Set<String>) async
    func disconnected()
    func message(_ envelope: AMEnvelope) async
    func forget(phoneID: String) async
}
