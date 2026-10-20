import XCTest
import AppKit
import AVKit
import SwiftUI
@testable import AqaraMenuBar

final class EventPlayerTests: XCTestCase {
    @MainActor
    func testHostedPlayerRendersAndPlaysLocalClip() async throws {
        guard let path = ProcessInfo.processInfo.environment["AQARA_TEST_CLIP"] else {
            throw XCTSkip("Set AQARA_TEST_CLIP to exercise AppKit playback with a local clip")
        }
        _ = NSApplication.shared
        let player = AVPlayer(url: URL(fileURLWithPath: path))
        player.isMuted = true
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 188),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: EventPlayerView(player: player))
        defer {
            player.pause()
            panel.contentView = nil
            panel.close()
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        player.play()
        for _ in 0..<100 {
            if player.currentTime().seconds > 0.1 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(player.currentItem?.status, .readyToPlay)
        XCTAssertGreaterThan(player.currentTime().seconds, 0.1)
    }
}
