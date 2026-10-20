import AppKit
import Foundation

struct AppUpdate: Equatable {
    let version: String
    let url: URL
}

/// Opt-in daily update check against the project's Cloudflare Worker
/// (`server/` in the repo). Each check sends a random install id, the app
/// version and the macOS version, which is also how active installs are
/// counted. Nothing about the Aqara account or camera is sent, and nothing at
/// all goes out unless the user allows it.
@MainActor
final class UpdateChecker {
    static let endpoint = URL(string: "https://aqara-doorbell.egzeyospin.workers.dev/v1/check")!
    private static let consentKey = "updateCheck"   // Bool; absent until the user has been asked
    private static let installIDKey = "installID"

    private let model: DoorbellModel
    private var task: Task<Void, Never>?

    init(model: DoorbellModel) { self.model = model }

    func start() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.consentKey) == nil {
            defaults.set(askConsent(), forKey: Self.consentKey)
        }
        model.updateChecks = defaults.bool(forKey: Self.consentKey)
        model.onUpdateChecksChanged = { [weak self] on in
            UserDefaults.standard.set(on, forKey: Self.consentKey)
            on ? self?.run() : self?.stop()
        }
        if model.updateChecks { run() }
    }

    private func run() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkNow()
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        model.availableUpdate = nil
    }

    private func askConsent() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Check for updates?"
        alert.informativeText = """
            Aqara Doorbell can check once a day whether a new version is out. \
            Each check sends a random install ID, the app version and your macOS \
            version, which also tells the developer roughly how many people use \
            the app. Nothing about your Aqara account or camera is sent.

            You can change this any time in the menu.
            """
        alert.addButton(withTitle: "Check for Updates")
        alert.addButton(withTitle: "Don't Check")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private struct Reply: Decodable {
        let latest: String?
        let url: String?
    }

    private func checkNow() async {
        var parts = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)
        parts?.queryItems = [
            URLQueryItem(name: "id", value: Self.installID),
            URLQueryItem(name: "v", value: Self.appVersion),
            URLQueryItem(name: "os", value: Self.osVersion),
        ]
        guard let url = parts?.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return }
        if let latest = reply.latest, let link = reply.url.flatMap(URL.init(string:)),
           Self.isNewer(latest, than: Self.appVersion) {
            model.availableUpdate = AppUpdate(version: latest, url: link)
        } else {
            model.availableUpdate = nil
        }
    }

    private static var installID: String {
        if let id = UserDefaults.standard.string(forKey: installIDKey) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: installIDKey)
        return id
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Numeric dotted comparison; a pre-release suffix ("-dev") is ignored.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func numbers(_ s: String) -> [Int] {
            (s.split(separator: "-").first ?? "").split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = numbers(a), y = numbers(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
