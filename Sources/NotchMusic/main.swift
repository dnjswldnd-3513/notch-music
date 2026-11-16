import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = NotchController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }
}

let app = NSApplication.shared

// 개발용: NotchMusic --snapshot <폴더> 로 접힌·펼친 모습을 PNG로 저장한다.
if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        Snapshot.run(into: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    }
}

// 개발용: open -a NotchMusic --args --dump-tray <파일>
// 노치 양옆 빈 틈과, 읽은 메뉴 막대 아이콘 목록을 파일에 쓴다. (아무것도 누르지 않는다)
if let index = CommandLine.arguments.firstIndex(of: "--dump-tray"), index + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[index + 1]
    let room = MenuBarSpace.measure()
    let tray = MenuBarTray()
    let started = Date()
    tray.refresh()
    while tray.items.isEmpty, Date().timeIntervalSince(started) < 10 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    let lines = [
        "trusted=\(AXIsProcessTrusted()) 앞 앱=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")",
        "빈 틈: 왼쪽=\(room.map { Int($0.left) }.map(String.init) ?? "-") 오른쪽=\(room.map { Int($0.right) }.map(String.init) ?? "-")",
    ] + tray.items.map {
        "\($0.isDrawn ? "보임" : "가림") \(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height)) \($0.name)"
    }
    try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
