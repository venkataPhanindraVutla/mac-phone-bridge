#if FULL_BUILD
import Foundation
import Security

/// The App Group the Full build shares with its extensions. Its ID comes from the app's own
/// signed entitlement (`$(APP_GROUP_ID)`, team-prefixed), so an unsigned build has none and the
/// Finder sidebar and the Share menu stay off.
enum AppGroup {
    static let id: String? = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil),
              let groups = value as? [String],
              let group = groups.first, !group.isEmpty, !group.hasPrefix(".")
        else { return nil }
        return group
    }()

    /// `~/Library/Group Containers/<id>`; nil without a group.
    static var container: URL? {
        id.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }
}
#endif
