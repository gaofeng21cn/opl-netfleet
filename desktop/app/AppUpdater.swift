import AppKit
import Foundation
import Sparkle

enum AppUpdateConfiguration {
    static let feedURLKey = "SUFeedURL"
    static let publicEDKey = "SUPublicEDKey"
    static let automaticChecksKey = "SUEnableAutomaticChecks"
    static let scheduledCheckIntervalKey = "SUScheduledCheckInterval"
    static let canonicalFeedURL =
        "https://github.com/gaofeng21cn/opl-netfleet/releases/latest/download/appcast.xml"
    static let scheduledCheckIntervalSeconds = 6 * 60 * 60

    static func canStartSparkle(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard environment["XCTestConfigurationFilePath"] == nil else {
            return false
        }

        guard bundle.bundleURL.pathExtension == "app" else {
            return false
        }

        guard
            let feedURLString = bundle.object(forInfoDictionaryKey: feedURLKey) as? String,
            let feedURL = URL(string: feedURLString),
            feedURL.scheme == "https",
            let host = feedURL.host,
            !host.isEmpty
        else {
            return false
        }

        guard
            let publicKey = bundle.object(forInfoDictionaryKey: publicEDKey) as? String,
            !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }

        return true
    }
}

final class AppUpdater: NSObject, SPUStandardUserDriverDelegate {
    private(set) var canCheckForUpdates = false
    private(set) var isConfigured = false
    private var updaterController: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?

    init(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        startImmediately: Bool = true
    ) {
        super.init()

        let configured = AppUpdateConfiguration.canStartSparkle(
            bundle: bundle,
            environment: environment
        )
        self.isConfigured = configured
        guard configured else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: startImmediately,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        self.updaterController = controller
        self.canCheckForUpdates = controller.updater.canCheckForUpdates
        self.canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard let canCheck = change.newValue else { return }
            DispatchQueue.main.async {
                self?.canCheckForUpdates = canCheck
            }
        }
    }

    func checkForUpdates() {
        guard let updaterController else { return }
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
    }

    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if handleShowingUpdate || state.userInitiated {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
