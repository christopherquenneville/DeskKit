import AppKit
import Security

/// Offers new versions from DeskKit's GitHub releases. It checks a minute after launch and then once
/// a day (or from the menu), and installs an update in place only if it's signed by the same
/// developer as the running copy and notarized by Apple.
@MainActor
final class Updater: NSObject {
    static let repository = "christopherquenneville/DeskKit"

    struct Release: Equatable {
        let version: String
        let notes: String
        let page: URL
        let download: URL
    }

    enum Failure: LocalizedError {
        case unavailable
        case noDownload
        case unpacking
        case untrusted
        case notReplaceable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "GitHub didn't answer with DeskKit's latest release."
            case .noDownload: return "The release has no DeskKit.zip to download."
            case .unpacking: return "The download couldn't be unpacked."
            case .untrusted: return "The download isn't signed by DeskKit's developer and notarized by Apple, so it wasn't installed."
            case .notReplaceable(let reason): return "DeskKit couldn't replace itself: \(reason)"
            }
        }
    }

    private var dailyTimer: Timer?
    private var isBusy = false

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        guard dailyTimer == nil else { return }
        let first = Timer(timeInterval: 60, target: self, selector: #selector(scheduledCheck(_:)), userInfo: nil, repeats: false)
        RunLoop.main.add(first, forMode: .common)
        let daily = Timer(timeInterval: 24 * 60 * 60, target: self, selector: #selector(scheduledCheck(_:)), userInfo: nil, repeats: true)
        daily.tolerance = 60 * 60
        RunLoop.main.add(daily, forMode: .common)
        dailyTimer = daily
    }

    @objc private func scheduledCheck(_ timer: Timer) {
        // Copies built from source have no developer to match an update against, so they only check when asked.
        if Settings.shared.checkForUpdatesAutomatically && Self.canUpdateItself { check(userInitiated: false) }
    }

    /// Looks for a newer release. When the person asked, it also says that DeskKit is up to date or
    /// why the check failed.
    func check(userInitiated: Bool) {
        guard !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            do {
                let release = try await Self.latestRelease()
                if Self.isNewer(release.version, than: Self.currentVersion) {
                    if userInitiated || Settings.shared.skippedUpdateVersion != release.version { await offer(release) }
                } else if userInitiated {
                    tell("DeskKit is up to date", "You have the latest version, \(Self.currentVersion).")
                }
            } catch {
                appLog.error("Couldn't check for updates: \(error.localizedDescription, privacy: .public)")
                if userInitiated { tell("Couldn't check for updates", error.localizedDescription) }
            }
            isBusy = false
        }
    }

    // MARK: Asking

    private func offer(_ release: Release) async {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "DeskKit \(release.version) is available"
        var text = "You have \(Self.currentVersion)."
        text += Self.canUpdateItself ? " DeskKit restarts to update and keeps its settings and permissions." : ""
        let notes = Self.plainText(release.notes)
        if !notes.isEmpty { text += "\n\n" + notes }
        alert.informativeText = text
        alert.addButton(withTitle: Self.canUpdateItself ? "Install and Restart" : "Open Download Page")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Check for updates automatically"
        alert.suppressionButton?.state = Settings.shared.checkForUpdatesAutomatically ? .on : .off
        let response = alert.runModal()
        Settings.shared.checkForUpdatesAutomatically = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn:
            if Self.canUpdateItself { await install(release) } else { NSWorkspace.shared.open(release.page) }
        case .alertThirdButtonReturn:
            Settings.shared.skippedUpdateVersion = release.version
        default:
            break
        }
    }

    private func tell(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: Installing

    private func install(_ release: Release) async {
        do {
            let app = try await Self.download(release.download)
            try Self.verify(app)
            try Self.replace(Bundle.main.bundleURL, with: app)
            appLog.info("Updated to \(release.version, privacy: .public); restarting")
            relaunch()
        } catch {
            appLog.error("Couldn't install \(release.version, privacy: .public): \(error.localizedDescription, privacy: .public)")
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Couldn't install DeskKit \(release.version)"
            alert.informativeText = error.localizedDescription + "\n\nYou can download it from GitHub instead."
            alert.addButton(withTitle: "Open Download Page")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
        }
    }

    /// Downloads and unpacks the release into a new temporary folder, returning the app inside it.
    static func download(_ url: URL) async throws -> URL {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("DeskKit-update-\(UUID().uuidString)")
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let (downloaded, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.noDownload }
        let zip = folder.appendingPathComponent("DeskKit.zip")
        try files.moveItem(at: downloaded, to: zip)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        let app = folder.appendingPathComponent("DeskKit.app")
        guard ditto.terminationStatus == 0, files.fileExists(atPath: app.path) else { throw Failure.unpacking }
        return app
    }

    /// Throws unless `app` is signed by the same developer as this copy (its designated requirement
    /// names the team) and notarized by Apple.
    static func verify(_ app: URL) throws {
        guard let mine = designatedRequirement else { throw Failure.untrusted }
        var requirement: SecRequirement?
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecRequirementCreateWithString("(\(mine)) and notarized" as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess else {
            throw Failure.untrusted
        }
    }

    static func replace(_ installed: URL, with new: URL) throws {
        do {
            _ = try FileManager.default.replaceItemAt(installed, withItemAt: new)
        } catch {
            throw Failure.notReplaceable(error.localizedDescription)
        }
    }

    // MARK: Identity

    /// This copy's designated requirement, as text.
    private static var designatedRequirement: String? {
        var me: SecCode?
        var staticMe: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopyDesignatedRequirement(staticMe, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }

    /// Whether this copy is signed by a developer (rather than ad hoc), so an update can be matched to it.
    static var canUpdateItself: Bool {
        var me: SecCode?
        var staticMe: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopySigningInformation(staticMe, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return false }
        return info[kSecCodeInfoTeamIdentifier as String] is String
    }

    // MARK: Releases

    private static func latestRelease() async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { throw Failure.unavailable }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DeskKit/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.unavailable }
        return try release(from: data)
    }

    /// Reads GitHub's answer for a release.
    static func release(from data: Data) throws -> Release {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }
        struct Payload: Decodable {
            let tagName: String
            let body: String?
            let htmlUrl: URL
            let assets: [Asset]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(Payload.self, from: data)
        guard let asset = payload.assets.first(where: { $0.name == "DeskKit.zip" }) else { throw Failure.noDownload }
        let version = payload.tagName.hasPrefix("v") ? String(payload.tagName.dropFirst()) : payload.tagName
        return Release(version: version, notes: payload.body ?? "", page: payload.htmlUrl, download: asset.browserDownloadUrl)
    }

    /// Compares dotted version numbers: 1.0.10 is newer than 1.0.9, and 1.1 than 1.0.5.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] { version.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Release notes without Markdown's marks, cut short for an alert.
    static func plainText(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var text = (try? AttributedString(markdown: markdown, options: options)).map { String($0.characters) } ?? markdown
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 600 ? String(text.prefix(600)) + "…" : text
    }
}
