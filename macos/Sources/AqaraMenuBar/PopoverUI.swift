import SwiftUI
import AppKit
import AVKit

struct EventVM: Identifiable {
    let event: AqaraCloud.CameraEvent
    var id: String { event.id }
    var name: String { event.name }
    var date: Date { Date(timeIntervalSince1970: Double(event.triggerTime) / 1000) }
    var relative: String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
    private static let exactFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy, HH:mm:ss"; return f
    }()
    var exact: String { EventVM.exactFmt.string(from: date) }
    var icon: String {
        if name.contains("Lingerer") { return "figure.walk" }
        if name.contains("Doorbell") || name.contains("Ring") { return "bell.fill" }
        if name.contains("Motion") { return "sensor.tag.radiowave.forward.fill" }
        if name.contains("Face") { return "face.smiling" }
        return "camera.fill"
    }
    var short: String {
        if name.contains("Lingerer") { return "Lingerer detected" }
        if name.contains("Doorbell") { return "Doorbell ring" }
        if name.contains("Motion") { return "Motion detected" }
        return name
    }
}

/// Observable state shared between the poller (controller) and the SwiftUI popover.
@MainActor
final class DoorbellModel: ObservableObject {
    @Published var isMuted = UserDefaults.standard.bool(forKey: "streamMuted") {
        didSet {
            UserDefaults.standard.set(isMuted, forKey: "streamMuted")
            native?.setMuted(isMuted)
            eventPlayer?.isMuted = isMuted
        }
    }
    @Published var notificationStatus = "Checking notifications…"
    @Published var notificationsNeedSettings = false   // denied/failed: offer System Settings
    var testNotification: (() -> Void)?
    var logOut: (() -> Void)?
    /// Opt-in daily update check (see UpdateChecker); toggled from the footer.
    @Published var updateChecks = false { didSet { onUpdateChecksChanged?(updateChecks) } }
    var onUpdateChecksChanged: ((Bool) -> Void)?
    @Published var availableUpdate: AppUpdate?
    @Published var cameraName = "Doorbell"
    @Published var status = "Starting…"
    @Published var events: [EventVM] = []
    @Published var historyDate = Date()
    @Published var historyLoading = false
    @Published var historyError: String?
    @Published var historyHasMore = true
    var historyLoader: ((Int64, Int64) async throws -> [AqaraCloud.CameraEvent])?
    private var historyTask: Task<Void, Never>?
    private var historyRequest = UUID()
    private var historyCursor: Int64?

    func changeHistoryDay(_ date: Date) {
        historyDate = date
        historyRequest = UUID()
        historyTask?.cancel()
        historyLoading = false
        historyCursor = nil
        historyHasMore = true
        historyError = nil
        events = []
        loadOlderEvents()
    }

    func mergeEvents(_ incoming: [AqaraCloud.CameraEvent]) {
        var byID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for event in incoming { byID[event.id] = EventVM(event: event) }
        events = byID.values.sorted { $0.event.triggerTime > $1.event.triggerTime }
    }

    func loadOlderEvents() {
        guard !historyLoading, historyHasMore, let loader = historyLoader else { return }
        let day = Calendar.current.startOfDay(for: historyDate)
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let start = Int64(day.timeIntervalSince1970 * 1000)
        let end = historyCursor ?? min(Int64(nextDay.timeIntervalSince1970 * 1000) - 1,
                                       Int64(Date().timeIntervalSince1970 * 1000))
        guard end >= start else { historyHasMore = false; return }
        let request = historyRequest
        historyLoading = true
        historyError = nil
        historyTask = Task { [weak self] in
            do {
                let page = try await loader(start, end)
                guard let self, self.historyRequest == request, !Task.isCancelled else { return }
                self.mergeEvents(page)
                if let oldest = page.map(\.triggerTime).min() {
                    self.historyCursor = oldest - 1
                    self.historyHasMore = oldest > start
                } else { self.historyHasMore = false }
                self.historyLoading = false
            } catch {
                guard let self, self.historyRequest == request, !Task.isCancelled else { return }
                self.historyError = "Could not load events. Try again."
                self.historyLoading = false
            }
        }
    }

    @Published var snapshot: NSImage?
    @Published var engineOnline = false
    @Published var live = false

    // Native P2P path (no Node/ffmpeg): set by the controller once the cloud session knows the camera.
    @Published var nativeActive = false      // native layer is the live surface
    @Published var nativeHasVideo = false    // at least one frame rendered
    @Published var nativeStatus = ""
    @Published var talking = false           // two-way talk active
    @Published var kbps: Int = 0             // live stream bitrate (KB/s)
    @Published var batteryPct: Int?          // device_battery_power (%)
    @Published var wifiRssi: Int?            // device_wifi_rssi (dBm)
    @Published var wifiLevel: Int?           // wifi_level (0–4 bars)
    var native: NativeStream?
    var preferNative = true

    var eventMedia: COSEventMedia?
    @Published var selectedEvent: EventVM?
    @Published var eventPlayer: AVPlayer?
    @Published var eventImage: NSImage?
    @Published var eventLoading = false
    @Published var eventError: String?
    private var eventTask: Task<Void, Never>?
    private var playbackObservation: NSKeyValueObservation?
    private var eventRequest = UUID()

    func showEvent(_ event: EventVM) {
        stopLive()
        stopEvent()
        selectedEvent = event
        eventLoading = true
        let request = eventRequest
        eventTask = Task { [weak self] in
            guard let self else { return }
            guard let media = self.eventMedia else {
                self.eventLoading = false
                self.eventError = "Waiting for cloud login. Try again shortly."
                return
            }
            do {
                if !event.event.videoName.isEmpty {
                    let url = try await media.video(event.event)
                    try Task.checkCancellation()
                    guard self.eventRequest == request else { return }
                    let item = AVPlayerItem(url: url)
                    self.playbackObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                        let failed = item.status == .failed
                        Task { @MainActor in
                            guard let self, self.eventRequest == request, failed else { return }
                            self.eventError = "This recording could not be played. Try again."
                            self.eventPlayer?.pause()
                        }
                    }
                    let player = AVPlayer(playerItem: item)
                    player.isMuted = self.isMuted
                    self.eventPlayer = player
                    player.play()
                } else {
                    let data = try await media.snapshot(event.event)
                    try Task.checkCancellation()
                    guard self.eventRequest == request, let image = NSImage(data: data) else { throw EventMediaError.invalidMedia }
                    self.eventImage = image
                }
                self.eventLoading = false
            } catch {
                guard self.eventRequest == request, !Task.isCancelled else { return }
                self.eventLoading = false
                self.eventError = error.localizedDescription
            }
        }
    }

    func stopEvent() {
        eventRequest = UUID()
        eventTask?.cancel(); eventTask = nil
        playbackObservation = nil
        eventPlayer?.pause(); eventPlayer?.replaceCurrentItem(with: nil); eventPlayer = nil
        selectedEvent = nil; eventImage = nil; eventError = nil; eventLoading = false
    }

    var engineBase = "http://127.0.0.1:8580"
    private var slug: String?
    private var refreshTimer: Timer?

    func startLive() {
        stopEvent()
        live = true
        if preferNative {
            nativeActive = true
            nativeHasVideo = false
            // The controller assigns `native` once cloud login resolved the camera; it
            // re-enters startLive() at that point if we are still live.
            guard let native else { nativeStatus = "Waiting for cloud login…"; return }
            native.onStatus = { [weak self] s in self?.nativeStatus = s }
            native.onVideoStarted = { [weak self] in self?.nativeHasVideo = true }
            native.onBitrate = { [weak self] k in self?.kbps = k }
            native.setMuted(isMuted)
            native.start()
            return
        }
        Task { await self.discoverSlug() }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { await self?.refreshSnapshot() }
        }
        Task { await refreshSnapshot() }
    }

    func stopLive() {
        live = false
        if talking { native?.stopTalk(); talking = false }
        if nativeActive {
            native?.stop()
            nativeActive = false
            nativeHasVideo = false
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func toggleTalk() {
        guard nativeActive, nativeHasVideo, let n = native else { return }
        if talking { n.stopTalk(); talking = false }
        else { n.startTalk(); talking = true }
    }

    private func discoverSlug() async {
        guard slug == nil, let url = URL(string: "\(engineBase)/frames/list") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [String], let first = arr.first {
                slug = first
            }
        } catch { /* engine offline */ }
    }

    private func refreshSnapshot() async {
        let s = slug ?? "doorbell"
        guard let url = URL(string: "\(engineBase)/api/cameras/\(s)/snapshot") else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 3
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200, let img = NSImage(data: data) {
                snapshot = img; engineOnline = true
            } else { engineOnline = false }
        } catch { engineOnline = false }
    }
}

struct DoorbellView: View {
    @ObservedObject var model: DoorbellModel
    var onSnapshot: () -> Void = {}
    var onTalk: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                // Live area
                Group {
                    if model.selectedEvent != nil {
                        eventPlayback
                    } else if model.nativeActive {
                        ZStack {
                            Rectangle().fill(Color.black)
                            if let native = model.native { VideoLayerView(layer: native.displayLayer) }
                            if !model.nativeHasVideo {
                                Text(model.nativeStatus.isEmpty ? "Connecting…" : model.nativeStatus)
                                    .font(.caption).foregroundColor(.gray).multilineTextAlignment(.center)
                            }
                        }
                    } else if let img = model.snapshot {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color.black)
                            .overlay(Text(model.engineOnline ? "Connecting…" : "Stream offline")
                                .font(.caption).foregroundColor(.gray).multilineTextAlignment(.center))
                    }
                }
                .frame(height: 188).frame(maxWidth: .infinity).clipped()

                if model.selectedEvent == nil {
                // One top row: title capsule on the left (truncates), stats on
                // the right, a Spacer between so they never overlap.
                HStack(alignment: .top, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(isLive ? Color.blue : Color.gray).frame(width: 8, height: 8)
                        Text(isLive ? "LIVE" : "OFF").font(.caption2.bold()).foregroundColor(.white)
                        Text(model.cameraName).font(.caption.bold()).foregroundColor(.white)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.5)))

                    Spacer(minLength: 8)

                    statsBar
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .top)
                }
            }

            // Controls
            if let event = model.selectedEvent {
                HStack {
                    VStack(alignment: .leading) {
                        Text(event.short).font(.caption.bold()).lineLimit(1)
                        Text(event.exact).font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button { model.isMuted.toggle() } label: {
                        Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }.help(model.isMuted ? "Unmute" : "Mute")
                    Button("Back to live") { model.startLive() }
                }.padding(.horizontal, 12).frame(height: 72)
            } else {
            HStack(spacing: 18) {
                ctrl(model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", color: model.isMuted ? .orange : .gray) { model.isMuted.toggle() }
                ctrl("camera.fill", color: .gray) { onSnapshot() }
                ctrl(model.talking ? "mic.fill" : "mic.slash.fill",
                     color: model.talking ? .blue : .gray, big: true) { model.toggleTalk() }
                ctrl(model.live ? "stop.fill" : "play.fill", color: .gray) {
                    model.live ? model.stopLive() : model.startLive()
                }
            }
            .padding(.vertical, 9)
            }

            Divider()

            // Events (vertical list, newest first)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Events").font(.subheadline.bold())
                    Spacer()
                    Text("\(model.events.count)").font(.caption).foregroundColor(.secondary)
                }.padding(.horizontal, 12).padding(.bottom, 6)

                HStack {
                    Button { model.changeHistoryDay(Calendar.current.date(byAdding: .day, value: -1, to: model.historyDate)!) } label: {
                        Image(systemName: "chevron.left")
                    }
                    DatePicker("Day", selection: Binding(get: { model.historyDate },
                        set: { model.changeHistoryDay($0) }), in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                    Button { model.changeHistoryDay(Calendar.current.date(byAdding: .day, value: 1, to: model.historyDate)!) } label: {
                        Image(systemName: "chevron.right")
                    }.disabled(Calendar.current.isDateInToday(model.historyDate))
                    Spacer()
                    Button("Today") { model.changeHistoryDay(Date()) }
                }.padding(.horizontal, 12).padding(.bottom, 6)

                if model.events.isEmpty && !model.historyLoading {
                    Text("No events for this day").font(.caption).foregroundColor(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }
                    ScrollView(showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(model.events) { e in
                                EventRow(event: e, media: model.eventMedia,
                                         selected: model.selectedEvent?.id == e.id) { model.showEvent(e) }
                                Divider().padding(.leading, 76)
                            }
                        }
                    }
                    .frame(height: 176)
                HStack {
                    if model.historyLoading {
                        ProgressView().controlSize(.small)
                        Text("Loading…").font(.caption)
                    } else if model.historyHasMore || model.historyError != nil {
                        Button(model.historyError == nil ? "Load older events" : "Try again") { model.loadOlderEvents() }
                    } else {
                        Text("End of this day’s history").font(.caption).foregroundColor(.secondary)
                    }
                    if let error = model.historyError { Text(error).font(.caption).foregroundColor(.secondary) }
                }.padding(.horizontal, 12).padding(.top, 6)
            }
            .padding(.vertical, 10)

            Divider()
            HStack {
                Text(model.notificationStatus).font(.caption2)
                    .foregroundColor(model.notificationsNeedSettings ? .orange : .secondary)
                    .lineLimit(2)
                Spacer()
                if model.notificationsNeedSettings {
                    Button("Open Settings") { openNotificationSettings() }.font(.caption)
                } else {
                    Button("Test notification") { model.testNotification?() }.font(.caption)
                }
            }.padding(.horizontal, 12).padding(.top, 6)
            HStack {
                Toggle("Check for updates", isOn: $model.updateChecks)
                    .toggleStyle(.checkbox).font(.caption2)
                Spacer()
                if let update = model.availableUpdate {
                    Button("Update to \(update.version)") { NSWorkspace.shared.open(update.url) }
                        .font(.caption)
                }
            }.padding(.horizontal, 12).padding(.top, 4)
            HStack {
                Text(model.status).font(.caption).foregroundColor(.secondary).lineLimit(1)
                Spacer()
                Button("Log out") { model.logOut?() }.font(.caption)
                Button("Quit") { NSApp.terminate(nil) }.font(.caption)
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var eventPlayback: some View {
        ZStack {
            Color.black
            if let error = model.eventError {
                VStack(spacing: 8) {
                    Text(error).font(.caption).multilineTextAlignment(.center).foregroundColor(.white)
                    Button("Try again") { if let event = model.selectedEvent { model.showEvent(event) } }
                }.padding()
            } else if model.eventLoading {
                ProgressView("Loading recording…").foregroundColor(.white)
            } else if let player = model.eventPlayer {
                EventPlayerView(player: player)
            } else if let image = model.eventImage {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            }
        }
    }

    private var isLive: Bool {
        model.live && (model.nativeActive ? model.nativeHasVideo : model.engineOnline)
    }

    private var statsBar: some View {
        HStack(spacing: 10) {
            if let r = model.wifiRssi {
                stat("wifi", "\(r) dBm")
            } else if let l = model.wifiLevel {
                stat("wifi", "\(l)/4")
            }
            if let b = model.batteryPct {
                stat(b <= 20 ? "battery.25" : "battery.100", "\(b)%", warn: b <= 20)
            }
            if isLive {
                stat("waveform", "\(model.kbps) KB/s")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.5)))
    }

    private func stat(_ symbol: String, _ text: String, warn: Bool = false) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.caption2)
            Text(text).font(.caption2.monospacedDigit())
        }.foregroundColor(warn ? .red : .white)
    }

    @ViewBuilder
    private func ctrl(_ symbol: String, color: Color, big: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: big ? 20 : 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: big ? 54 : 40, height: big ? 54 : 40)
                .background(Circle().fill(color))
        }.buttonStyle(.plain)
    }
}


private struct EventRow: View {
    let event: EventVM
    let media: COSEventMedia?
    let selected: Bool
    let open: () -> Void
    @State private var thumbnail: NSImage?
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.18))
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    } else if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: failed ? "photo.badge.exclamationmark" : event.icon)
                            .foregroundColor(.accentColor)
                    }
                }.frame(width: 64, height: 48).clipped().cornerRadius(8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.short).font(.callout.weight(.medium))
                    Text(event.exact).font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                VStack(spacing: 4) {
                    Text(event.relative).font(.caption2).foregroundColor(.secondary)
                    if !event.event.videoName.isEmpty {
                        Image(systemName: "play.circle.fill").foregroundColor(.accentColor)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(failed ? "Thumbnail unavailable. Click to open the event." : "Open event")
        .task(id: event.event.mediaCacheKey) {
            guard let media, !event.event.snapshotName.isEmpty else { return }
            loading = true; failed = false
            do {
                let data = try await media.snapshot(event.event)
                try Task.checkCancellation()
                guard let image = NSImage(data: data) else { throw EventMediaError.invalidMedia }
                thumbnail = image
            } catch {
                if !Task.isCancelled { failed = true }
            }
            loading = false
        }
    }
}

/// Opens System Settings → Notifications, deep-linked to this app when the
/// pane supports it (macOS 13+), else the general Notifications pane.
func openNotificationSettings() {
    let id = Bundle.main.bundleIdentifier ?? ""
    let candidates = [
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)",
        "x-apple.systempreferences:com.apple.preference.notifications",
    ]
    for s in candidates {
        if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
    }
}
