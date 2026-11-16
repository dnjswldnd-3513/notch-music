import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = NotchController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()

        // 개발용: open -a NotchMusic --args --selftest <아이콘 이름 일부> <결과 파일>
        // 사용자처럼 노치에 마우스를 올리고 서랍 아이콘을 눌러, 메뉴가 열렸는지 결과 파일에 쓴다.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 2 < args.count {
            controller.hiddenIcons.runSelfTest(pressing: args[i + 1]) { lines in
                try? lines.joined(separator: "\n").write(toFile: args[i + 2], atomically: true, encoding: .utf8)
                exit(0)
            }
        }
    }
}

let app = NSApplication.shared

// 개발용: NotchMusic --snapshot <폴더> 로 접힌·펼친 모습을 PNG로 저장한다.
if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        Snapshot.run(into: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    }
}

// 개발용: open -a NotchMusic --args --dump-tray <파일> 로 읽은 메뉴 막대 아이콘 목록을 파일에 쓴다.
if let index = CommandLine.arguments.firstIndex(of: "--dump-tray"), index + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[index + 1]
    let tray = MenuBarTray()
    let started = Date()
    tray.refresh()
    while tray.items.isEmpty, Date().timeIntervalSince(started) < 10 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    let elapsed = Int(Date().timeIntervalSince(started) * 1000)
    let lines = ["trusted=\(AXIsProcessTrusted()) count=\(tray.items.count) 걸린 시간=\(elapsed)ms"] + tray.items.map {
        "\($0.isDrawn ? "보임" : "가림") \(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height)) pid=\($0.pid) \($0.name)"
    }
    // --press <이름 일부> 를 주면 그 아이콘을 눌러 보고 결과를 적는다.
    var pressLines: [String] = []
    if let p = CommandLine.arguments.firstIndex(of: "--press"), p + 1 < CommandLine.arguments.count,
       let item = tray.items.first(where: { $0.name.contains(CommandLine.arguments[p + 1]) }) {
        pressLines.append("press \(item.name): \(tray.press(item))")
    }
    try? (lines + pressLines + MenuBarTray.diagnostics()).joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
