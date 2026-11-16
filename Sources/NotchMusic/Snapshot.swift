import AppKit
import SwiftUI

/// 화면 녹화 권한 없이 디자인을 확인하려고, 실제 재생 정보로 노치를 그려 PNG로 저장한다.
@MainActor
enum Snapshot {
    static func run(into folder: URL) -> Never {
        let player = NowPlaying()
        player.start()
        // 어댑터가 곡 정보와 커버를 보낼 때까지 잠깐 기다린다.
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))

        let state = NotchState()
        state.notchSize = CGSize(width: 185, height: 32)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // 음악 화면 2장 + 가짜 Meet 통화 화면 2장 (음소거·카메라 켜짐)
        let calls = CallMonitor()
        for (name, expanded, inCall) in [("collapsed", false, false), ("expanded", true, false),
                                        ("call-collapsed", false, true), ("call-expanded", true, true)] {
            state.expanded = expanded
            state.hasCall = inCall
            calls.simulate(inCall ? .init(appName: "Google Meet", bundleId: "com.google.Chrome", kind: .meet,
                                          detail: "주간 회의 · Chrome", startedAt: Date().addingTimeInterval(-1448)) : nil,
                           muted: inCall, camera: inCall)
            let view = NotchView(player: player, calls: calls, state: state)
                .frame(width: state.windowSize.width, height: state.windowSize.height)
                .background(Color(white: 0.93))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage,
               let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent("\(name).png"))
            }
        }
        print("title=\(player.title) artist=\(player.artist) artwork=\(player.artwork != nil)")
        exit(0)
    }
}
