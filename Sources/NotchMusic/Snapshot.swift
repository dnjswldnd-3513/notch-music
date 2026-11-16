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

        for expanded in [false, true] {
            state.expanded = expanded
            let view = NotchView(player: player, state: state, tray: MenuBarTray())
                .frame(width: state.windowSize.width, height: state.windowSize.height)
                .background(Color(white: 0.93))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage,
               let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent(expanded ? "expanded.png" : "collapsed.png"))
            }
        }
        print("title=\(player.title) artist=\(player.artist) artwork=\(player.artwork != nil)")
        exit(0)
    }
}
