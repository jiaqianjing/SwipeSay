import Foundation

/// Where settings, stores and secrets live.
///
/// On macOS everything stays where it always was (standard defaults, `~/Library/Application Support/SwipeSay`,
/// the login keychain). On iOS the app and its action extension must see the same data, so they share an App Group
/// container, an App Group defaults suite and an App Group keychain access group.
public enum SharedStorage {
    public static let appGroup = "group.com.kenjia.swipesay"

    public static let defaults: UserDefaults = {
        #if os(iOS)
        return UserDefaults(suiteName: appGroup) ?? .standard
        #else
        return .standard
        #endif
    }()

    /// Folder for the SwiftData stores (vocabulary, translation cache, usage).
    public static var directory: URL {
        #if os(iOS)
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return group.appending(path: "Library/Application Support/SwipeSay", directoryHint: .isDirectory)
        }
        #endif
        return URL.applicationSupportDirectory.appending(path: "SwipeSay", directoryHint: .isDirectory)
    }

    /// Keychain access group shared by the iOS app and its extension; nil means the default (macOS login keychain).
    public static var keychainAccessGroup: String? {
        #if os(iOS)
        return appGroup
        #else
        return nil
        #endif
    }
}
