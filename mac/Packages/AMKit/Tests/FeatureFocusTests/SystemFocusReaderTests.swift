import Foundation
import Intents
import Testing
@testable import FeatureFocus

@Test func authorizationStatusesMap() {
    #expect(SystemFocusReader.map(.authorized) == .authorized)
    #expect(SystemFocusReader.map(.denied) == .denied)
    #expect(SystemFocusReader.map(.notDetermined) == .notDetermined)
    // A build without the entitlement reports restricted.
    #expect(SystemFocusReader.map(.restricted) == .unavailable)
}

/// Intents calls the authorization completion on a queue of its own: it must not be main-actor
/// isolated (Swift 6 traps at entry).
@MainActor @Test func authorizationCompletionRunsOffTheMainThread() async {
    let status = await withCheckedContinuation { continuation in
        let completion = SystemFocusReader.completion(continuation)
        DispatchQueue.global().async { completion(.denied) }
    }
    #expect(status == .denied)
}
