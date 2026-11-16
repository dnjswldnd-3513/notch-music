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

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
