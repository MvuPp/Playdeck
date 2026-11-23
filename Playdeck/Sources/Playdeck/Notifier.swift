import AppKit
import PlaydeckCore
import UserNotifications

/// End-of-batch notice when the app is in the background: a system notification, a Dock badge (cleared when the app
/// comes back) and one Dock bounce.
/// Built as Playdeck.app (scripts/build-app.sh): real notifications (UNUserNotificationCenter). Under `swift run` the
/// executable has no bundle and `UNUserNotificationCenter.current()` raises NSInternalInconsistencyException
/// (« bundleProxyForCurrentProcess is nil »): fallback to `osascript display notification` (text as argv, never interpolated).
@MainActor enum Notifier {
    private static var observer: NSObjectProtocol?

    static func batchFinished(projectName: String, check: Bool, runs: [Run], cancelled: Bool) {
        guard AppSettings.notify, !NSApp.isActive else { return }
        let text = RunExport.batchSummary(projectName: projectName, check: check, runs: runs, cancelled: cancelled)
        let failed = cancelled || runs.contains { $0.cancelled || $0.exitCode != 0 }
        NSApp.dockTile.badgeLabel = failed ? "!" : "✓"
        NSApp.requestUserAttention(.informationalRequest)
        observer = observer ?? NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                      object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.dockTile.badgeLabel = nil }
        }
        if Bundle.main.bundleIdentifier != nil {
            Task {
                let center = UNUserNotificationCenter.current()
                // Asked once by macOS; if refused, the badge and the bounce remain.
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
                let content = UNMutableNotificationContent()
                content.title = text.title
                content.body = text.body
                try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
            return
        }
        // Best effort: if it fails (or notifications are off for Script Editor), the badge is still there.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "on run argv", "-e", "display notification (item 2 of argv) with title \"Playdeck\" subtitle (item 1 of argv)",
                       // "--": a project named « -e… » must stay an argument, never become AppleScript.
                       "-e", "end run", "--", text.title, text.body]
        try? p.run()
    }
}
