import SwiftUI
import UIKit

final class RawBridgeAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        RawBackgroundUploadManager.shared
            .setBackgroundCompletionHandler(completionHandler)
    }
}

@main
struct RawBridgeApp: App {
    @UIApplicationDelegateAdaptor(RawBridgeAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
