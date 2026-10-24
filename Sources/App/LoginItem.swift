import AppKit
import ServiceManagement

/// Open at Login: SMAppService on macOS 13 and later, a LaunchAgent on macOS 12.
@MainActor
enum LoginItem {
    private static let label = "tech.quenneville.DeskKit"
    private static var agentURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        if #available(macOS 13, *) {
            do {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                appLog.error("Open at Login: \(error.localizedDescription, privacy: .public)")
            }
            if enabled && SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
            appLog.info("Open at Login is now \(isEnabled ? "on" : "off", privacy: .public)")
            return
        }
        if enabled {
            let agent: NSDictionary = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
            ]
            try? FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            agent.write(to: agentURL, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: agentURL)
        }
    }
}
