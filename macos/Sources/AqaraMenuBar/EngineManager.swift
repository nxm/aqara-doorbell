import Foundation

/// Spawns the resonaura P2P streaming engine (vendor/aqara-g5pro-mqtt) as a managed
/// sidecar: `nix shell nixpkgs#ffmpeg --command pnpm run rtsp`. Starts on live request,
/// stops (kills the process tree) when live ends — so the battery doorbell only wakes
/// while you are actually watching.
@MainActor
final class EngineManager {
    private var proc: Process?
    private var ready = false
    let engineDir: String
    var onReady: (Int) -> Void = { _ in }     // actual http port
    var onLog: (String) -> Void = { _ in }

    init(engineDir: String) { self.engineDir = engineDir }

    var isRunning: Bool { proc?.isRunning ?? false }

    func start() {
        guard proc == nil else { return }
        ready = false
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.currentDirectoryURL = URL(fileURLWithPath: engineDir)   // avoid `cd` (user's zsh chpwd hook errors)
        // -lc so the user's nix/node/pnpm are on PATH; exec so signals reach the engine.
        p.arguments = ["-lc", "exec nix shell nixpkgs#ffmpeg --command pnpm run rtsp"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let s = String(data: fh.availableData, encoding: .utf8) ?? ""
            guard !s.isEmpty else { return }
            Task { @MainActor in self?.handleLog(s) }
        }
        p.terminationHandler = { [weak self] _ in Task { @MainActor in self?.proc = nil; self?.ready = false } }
        do { try p.run(); proc = p } catch { onLog("engine spawn failed: \(error)") }
    }

    private func handleLog(_ s: String) {
        onLog(s)
        if !ready {
            // e.g. "[RTSP-Native] Server listening on port 8654" and the HTTP server line.
            if let port = firstMatch(s, #"[Hh]ttp.*?(\d{4,5})"#) ?? (s.contains("listening") ? 8580 : nil) {
                if s.lowercased().contains("listening") || s.contains("8580") {
                    ready = true
                    onReady(port)
                }
            }
        }
    }

    func stop() {
        proc?.terminate()
        proc = nil
        ready = false
        // kill the descendant tree (node/tsx server, native aqara-streamer, ffmpeg).
        for pat in ["scripts/rtsp/server", "aqara-streamer", "rtsp:8654", "run rtsp"] {
            let k = Process()
            k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            k.arguments = ["-f", pat]
            try? k.run()
        }
    }

    private func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func firstMatch(_ s: String, _ pattern: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }
}
