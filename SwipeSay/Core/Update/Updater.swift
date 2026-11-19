import AppKit
import SwipeSayKit
import Combine
import Sparkle

/// Sparkle-based auto-updater. The feed URL and EdDSA public key live in Info.plist (`SUFeedURL`, `SUPublicEDKey`).
///
/// SwipeSay is a menu-bar app, so scheduled update checks use Sparkle's "gentle reminders": the update window only
/// appears on its own when the app is already in focus. Otherwise the menu gets a 「安装更新」 item, so a background
/// check never steals focus.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    /// Debug builds don't run the updater, so a development build never offers to replace itself with a release.
    static var isEnabled: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    @Published private(set) var canCheckForUpdates = false
    /// Version found by a background check that the user hasn't looked at yet (drives the menu item).
    @Published private(set) var pendingUpdateVersion: String?

    @Published var automaticallyChecks: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    @Published var automaticallyDownloads: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = automaticallyDownloads }
    }

    var lastCheckDate: Date? { controller.updater.lastUpdateCheckDate }

    private var controller: SPUStandardUpdaterController!
    private var cancellables: Set<AnyCancellable> = []

    private override init() {
        automaticallyChecks = false
        automaticallyDownloads = false
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: Self.isEnabled, updaterDelegate: nil,
                                                  userDriverDelegate: self)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloads = controller.updater.automaticallyDownloadsUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 && Self.isEnabled }
            .store(in: &cancellables)
    }

    /// Call once at launch so the updater starts and schedules its checks.
    func start() {}

    func checkForUpdates() {
        guard Self.isEnabled else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                        andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Let Sparkle show it only if it would appear in focus anyway (for example right after launch).
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let version = update.displayVersionString
        let userInitiated = state.userInitiated
        MainActor.assumeIsolated {
            // A background check that Sparkle won't show: remember it, so the menu can offer to install.
            if !handleShowingUpdate && !userInitiated { pendingUpdateVersion = version }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { pendingUpdateVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { pendingUpdateVersion = nil }
    }
}
