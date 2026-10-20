import AppKit
import SwiftUI
import UserNotifications

/// Config loaded from ~/.config/aqara-doorbell/config.json, written by the
/// first-run sign-in window:
/// { "baseURL": "https://rpc-ger.aqara.com", "user": "..." }
/// The password lives in the Keychain; a plain-text "pass" key is still honored.
struct AppConfig: Codable {
    var baseURL: String
    var user: String
    var pass: String?             // legacy plain-text password; prefer the Keychain
    var pollSeconds: Double?
    var engineBase: String?
    var engineDir: String?
    var useNativeP2P: Bool?       // default true: in-process P2P + VideoToolbox; false: Node/ffmpeg sidecar
    var qualityChannel: Int?      // 0x100E target after first keyframe (default 0); -1 disables

    static let path = ("~/.config/aqara-doorbell/config.json" as NSString).expandingTildeInPath

    var password: String? { pass ?? Keychain.password(account: user) }

    /// nil when there is no usable config yet (no file, or no password anywhere),
    /// which sends the app to the sign-in window.
    static func load() -> AppConfig? {
        guard let data = FileManager.default.contents(atPath: path),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data),
              cfg.password != nil else { return nil }
        return cfg
    }

    /// Writes the config without the password, readable only by the user.
    func save() throws {
        var c = self
        c.pass = nil
        let dir = (Self.path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(c).write(to: URL(fileURLWithPath: Self.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.path)
    }
}

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var clickMonitor: Any?
    private let model = DoorbellModel()
    private var engine: EngineManager?

    private var cloud: AqaraCloud?
    private var config: AppConfig!
    private var homeId: String?
    private var camera: AqaraCloud.Device?
    private var lastSeenMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    private let notificationStartMs = Int64(Date().timeIntervalSince1970 * 1000)
    private var notifiedEvents: [String: Int64] = [:]
    private var pollTask: Task<Void, Never>?
    private var setupWindow: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        if let cfg = AppConfig.load() { launch(cfg) } else { showSetup() }
    }

    /// First run (or no stored password): ask for the Aqara account in a window
    /// instead of requiring a hand-written config file.
    private func showSetup() {
        let host = NSHostingView(rootView: SetupView { [weak self] cfg in
            self?.setupWindow?.close()
            self?.setupWindow = nil
            self?.launch(cfg)
        })
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Aqara Doorbell"
        w.contentView = host
        w.isReleasedWhenClosed = false
        w.center()
        setupWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func launch(_ cfg: AppConfig) {
        config = cfg
        if let eb = cfg.engineBase { model.engineBase = eb }
        model.preferNative = cfg.useNativeP2P ?? true
        // The Node/ffmpeg sidecar is optional and not part of this repo: only
        // start it when the config points at one. Native P2P needs nothing.
        if let engineDir = cfg.engineDir.map({ ($0 as NSString).expandingTildeInPath }) {
            let eng = EngineManager(engineDir: engineDir)
            eng.onReady = { [weak self] port in
                self?.model.engineBase = "http://127.0.0.1:\(port)"
                self?.model.startLive()
            }
            let logURL = URL(fileURLWithPath: "/tmp/aqara-engine.log")
            try? "".write(to: logURL, atomically: true, encoding: .utf8)
            eng.onLog = { s in
                if let h = try? FileHandle(forWritingTo: logURL) {
                    h.seekToEndOfFile(); h.write(Data(s.utf8)); try? h.close()
                }
            }
            engine = eng
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            // "door.*" symbols are macOS 14+; fall back to a bell on 13.
            btn.image = NSImage(systemSymbolName: "door.left.hand.closed", accessibilityDescription: "Doorbell")
                ?? NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "Doorbell")
            btn.action = #selector(togglePopover)
            btn.target = self
        }
        // Borderless floating panel anchored just below the menu bar (NSPopover mis-positions
        // over the menu bar for tall content; a panel gives exact control).
        let host = NSHostingView(rootView:
            DoorbellView(model: model, onSnapshot: { [weak self] in self?.saveSnapshot() }, onTalk: { }))
        host.setFrameSize(host.fittingSize)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.contentView = host
        p.contentView?.wantsLayer = true
        p.contentView?.layer?.cornerRadius = 12
        p.contentView?.layer?.masksToBounds = true
        panel = p

        UNUserNotificationCenter.current().delegate = self
        model.testNotification = { [weak self] in self?.sendTestNotification() }
        model.logOut = { [weak self] in self?.logOut() }
        Task { await refreshNotificationPermission(request: true) }
        start()
    }

    @objc private func togglePopover() {
        if panel.isVisible { closePanel() } else { openPanel() }
    }

    private func openPanel() {
        Task { await refreshNotificationPermission() }
        guard let btn = statusItem.button, let btnWin = btn.window else { return }
        if let host = panel.contentView { host.setFrameSize(host.fittingSize); panel.setContentSize(host.fittingSize) }
        // Anchor the panel's top-right under the status item, below the menu bar.
        let btnScreen = btnWin.convertToScreen(btn.convert(btn.bounds, to: nil))
        let w = panel.frame.width, h = panel.frame.height
        var x = btnScreen.maxX - w
        if let vis = (btnWin.screen ?? NSScreen.main)?.visibleFrame {
            x = max(vis.minX + 4, min(x, vis.maxX - w - 4))     // keep on-screen
        }
        let y = btnScreen.minY - h - 4                           // just below the menu bar
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }

        if model.preferNative { model.startLive() }
        else if engine?.isRunning == true { model.startLive() }
        else { engine?.start() }
    }

    /// Forget the account and start over in a fresh process, so no state from
    /// the old session (events, stream, camera) leaks into the next sign-in.
    private func logOut() {
        closePanel()   // ends the live session so the doorbell can sleep
        Keychain.deletePassword(account: config.user)
        try? FileManager.default.removeItem(atPath: AppConfig.path)
        let open = NSWorkspace.OpenConfiguration()
        open.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: open) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func closePanel() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        panel.orderOut(nil)
        model.stopEvent()
        model.stopLive()      // native: sends SESSION_STOP/CLOSE so the battery doorbell can sleep
        if engine?.isRunning == true { engine?.stop() }
    }

    private func start() {
        let c = AqaraCloud(config: .init(
            baseURL: config.baseURL, appId: AqaraCloud.defaultAppId,
            appKey: AqaraCloud.defaultAppKey,
            phoneId: "aqara-menubar-\(ProcessInfo.processInfo.hostName)"))
        cloud = c
        pollTask = Task { await self.loop(c) }
    }

    private func loop(_ c: AqaraCloud) async {
        do {
            try await c.login(email: config.user, password: config.password ?? "")
            let devs = try await c.devices()
            guard let cam = devs.first(where: { $0.model.hasPrefix("lumi.camera") }) else {
                model.status = "No camera on account"; return
            }
            camera = cam
            model.cameraName = cam.name
            homeId = try await c.homeIds().first
            if let homeId {
                model.eventMedia = COSEventMedia(cloud: c, homeId: homeId)
                model.historyLoader = { start, end in
                    try await c.events(positionId: homeId, did: cam.did, sinceMs: start, size: 20, untilMs: end)
                }
                model.loadOlderEvents()
            }
            let native = NativeStream(cloud: c, did: cam.did)
            if let q = config.qualityChannel { native.qualityChannel = q < 0 ? nil : q }
            model.native = native
            if model.live && model.preferNative { model.startLive() }   // popover was opened before login finished
            model.status = "Watching \(cam.name)"
        } catch {
            model.status = "Login failed: \(error)"; return
        }
        let interval = config.pollSeconds ?? 15
        while !Task.isCancelled {
            await poll()
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    private func poll() async {
        guard let c = cloud, let cam = camera, let home = homeId else { return }
        do {
            let evs = try await c.events(positionId: home, did: cam.did, sinceMs: lastSeenMs - 7 * 86_400_000, size: 20)
            let fresh = evs.filter { $0.triggerTime > notificationStartMs && notifiedEvents[$0.id] == nil }.sorted { $0.triggerTime < $1.triggerTime }
            for e in fresh { notifiedEvents[e.id] = e.triggerTime; notify(e) }
            notifiedEvents = notifiedEvents.filter { $0.value >= lastSeenMs - 7 * 86_400_000 }
            if let newest = evs.map(\.triggerTime).max() { lastSeenMs = max(lastSeenMs, newest) }
            let calendar = Calendar.current
            model.mergeEvents(evs.filter {
                calendar.isDate(Date(timeIntervalSince1970: Double($0.triggerTime) / 1000),
                                inSameDayAs: model.historyDate)
            })
        } catch {
            model.status = "Poll error: \(error)"
        }
        // Battery / wifi signal (best-effort; doesn't fail the poll).
        if let st = try? await c.status(did: cam.did, attrs: [
            "device_battery_power", "device_wifi_rssi", "wifi_level",
        ]) {
            if let b = st["device_battery_power"], let v = Int(b) { model.batteryPct = v }
            if let r = st["device_wifi_rssi"], let v = Int(r) { model.wifiRssi = v }
            if let l = st["wifi_level"], let v = Int(l) { model.wifiLevel = v }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    private func refreshNotificationPermission(request: Bool = false) async {
        let center = UNUserNotificationCenter.current()
        if request {
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
            catch {
                // Usually means the user (or an earlier prompt) turned them off;
                // the fix lives in System Settings, so offer a button there.
                model.notificationStatus = "Notifications off: \(error.localizedDescription)"
                model.notificationsNeedSettings = true
                return
            }
        }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            let banners = settings.alertSetting == .enabled
            model.notificationStatus = banners ? "Notifications enabled" : "Notification banners disabled"
            model.notificationsNeedSettings = !banners
        case .denied:
            model.notificationStatus = "Notifications blocked in macOS Settings"
            model.notificationsNeedSettings = true
        default:
            model.notificationStatus = "Notifications not authorized"
            model.notificationsNeedSettings = false   // first Test asks for permission
        }
    }

    // Write image bytes to a temp file and wrap them as a notification
    // attachment — this shows a thumbnail on the right of the banner, which
    // renders even when the app's own (left) icon is greyed out by a system
    // tweak. Returns nil on failure so the notification still posts without it.
    private func imageAttachment(_ data: Data, ext: String, id: String) -> UNNotificationAttachment? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aqara-notif", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(id).\(ext)")
        guard (try? data.write(to: url)) != nil,
              let att = try? UNNotificationAttachment(identifier: id, url: url) else { return nil }
        return att
    }

    private func appIconPNG() -> Data? {
        guard let tiff = NSApp.applicationIconImage?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func sendTestNotification() {
        Task {
            await refreshNotificationPermission(request: true)
            let content = UNMutableNotificationContent()
            content.title = "Aqara Doorbell"
            content.body = "Test notification — motion alerts use this same channel."
            content.sound = .default
            if let d = appIconPNG(), let att = imageAttachment(d, ext: "png", id: "test-icon") {
                content.attachments = [att]
            }
            do {
                try await UNUserNotificationCenter.current().add(UNNotificationRequest(
                    identifier: "notification-test", content: content, trigger: nil))
            } catch { model.notificationStatus = "Notification failed: \(error.localizedDescription)" }
        }
    }

    private func notify(_ e: AqaraCloud.CameraEvent) {
        let media = model.eventMedia
        let title = camera?.name ?? "Doorbell G410"
        Task { @MainActor in
            let content = UNMutableNotificationContent()
            content.title = title
            let t = Date(timeIntervalSince1970: Double(e.triggerTime) / 1000)
            content.body = "\(e.name) · \(Self.fmt.string(from: t))"
            content.sound = .default
            // Prefer the event's own snapshot; fall back to the app icon.
            if let data = try? await media?.snapshot(e),
               let att = imageAttachment(data, ext: "jpg", id: "evt-\(e.id)") {
                content.attachments = [att]
            } else if let d = appIconPNG(), let att = imageAttachment(d, ext: "png", id: "evt-icon-\(e.id)") {
                content.attachments = [att]
            }
            do {
                try await UNUserNotificationCenter.current().add(UNNotificationRequest(
                    identifier: "evt-\(e.id)", content: content, trigger: nil))
            } catch {
                notifiedEvents.removeValue(forKey: e.id)
                model.notificationStatus = "Notification failed: \(error.localizedDescription)"
            }
        }
    }

    private func saveSnapshot() {
        guard let img = model.snapshot, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(using: .jpeg, properties: [:]) else { return }
        let dir = ("~/Pictures/AqaraDoorbell" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/snap-\(Int(Date().timeIntervalSince1970)).jpg"
        try? jpg.write(to: URL(fileURLWithPath: path))
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: dir)
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}

@MainActor
func runMenuBarApp() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = MenuBarController()
    app.delegate = delegate
    objc_setAssociatedObject(app, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
