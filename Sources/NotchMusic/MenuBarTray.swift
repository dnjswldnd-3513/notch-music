import AppKit
import ApplicationServices

/// 메뉴 막대 오른쪽 아이콘 하나.
struct MenuBarItem: Identifiable {
    let id: String
    let pid: pid_t
    let name: String
    let frame: CGRect
    /// 지금 메뉴 막대에 실제로 그려져 있는지. 노치 뒤에 숨었거나 치워진 아이콘은 false.
    let isDrawn: Bool
    /// macOS가 넘쳐서 숨긴 아이콘. « 버튼을 누르면 노치 왼쪽으로 펼쳐진다.
    let isOverflowed: Bool
    let icon: NSImage?
    let symbol: String?
    fileprivate let element: AXUIElement
}

/// 손쉬운 사용(Accessibility)으로 메뉴 막대 아이콘 목록을 읽고, 대신 눌러 준다.
/// macOS 27부터 메뉴 막대 아이콘은 따로 된 창이 아니어서, 손쉬운 사용으로만 읽을 수 있다.
final class MenuBarTray: ObservableObject {
    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published private(set) var items: [MenuBarItem] = []

    private let queue = DispatchQueue(label: "notchmusic.tray", qos: .userInitiated)
    private var permissionTimer: Timer?
    private var refreshing = false
    private var refreshAgain = false
    private var workspaceObservers: [NSObjectProtocol] = []

    /// 노치를 펼쳤을 때 목록이 이미 준비돼 있도록, 다른 앱이 켜지거나 꺼질 때마다 뒤에서 다시 읽어 둔다.
    func startWatching() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // 막 켜진 앱이 메뉴 막대 아이콘을 만들 시간을 준다.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.refresh() }
            })
        }
        refresh()
    }

    /// 시스템 설정의 손쉬운 사용 허락 창을 띄우고, 허락될 때까지 1초마다 확인한다.
    func requestPermission() {
        guard !AXIsProcessTrusted() else {
            trusted = true
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        permissionTimer?.invalidate()
        var remaining = 180
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            remaining -= 1
            if AXIsProcessTrusted() {
                self?.trusted = true
                self?.refresh()
                timer.invalidate()
            } else if remaining <= 0 {
                timer.invalidate()
            }
        }
    }

    func refresh() {
        trusted = AXIsProcessTrusted()
        guard trusted else { return }
        // 읽는 중에 또 요청이 오면, 끝난 뒤 한 번 더 읽는다.
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        let barHeight = screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 24
        let notch = Self.notchRange(on: screen)
        let apps = NSWorkspace.shared.runningApplications

        queue.async { [weak self] in
            let found = Self.enumerate(apps: apps, barHeight: barHeight, notch: notch)
            DispatchQueue.main.async {
                guard let self else { return }
                self.items = found
                self.refreshing = false
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.refresh()
                }
            }
        }
    }

    /// 아이콘을 누른다. 그려지지 않은 아이콘은 누르면 macOS 27.0.1에서 메뉴 막대가 멈출 수 있어 막는다.
    /// 숨은 아이콘이면 « 버튼으로 먼저 펼치고, 펼쳐진 자리를 찾아 클릭한다.
    /// 화면에 그려지기 전에 누르면 macOS 27.0.1에서 메뉴 막대가 멈출 수 있어서, 그려진 걸 확인한 뒤에만 누른다.
    /// 마지막 누르기 과정 기록 (자체 시험용)
    private(set) var pressLog: [String] = []

    func pressRevealing(_ item: MenuBarItem) {
        pressLog = ["대상: \(item.name) 보임=\(item.isDrawn) 숨음=\(item.isOverflowed) @\(Int(item.frame.minX))"]
        guard item.isOverflowed, let button = items.first(where: { $0.id == "overflow" }) else {
            pressLog.append("바로 클릭")
            press(item)
            return
        }
        pressLog.append("« 눌러서 펼치기")
        press(button)
        let started = Date()
        func findAndPress() {
            queue.async { [weak self] in
                guard let self else { return }
                let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
                let barHeight = screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 24
                let list = Self.enumerate(
                    apps: NSWorkspace.shared.runningApplications, barHeight: barHeight, notch: Self.notchRange(on: screen)
                )
                DispatchQueue.main.async {
                    self.items = list
                    let same = list.filter { $0.pid == item.pid }
                    self.pressLog.append("다시 읽음: " + same.map { "\($0.name) 보임=\($0.isDrawn) @\(Int($0.frame.minX))" }.joined(separator: ", "))
                    if let revealed = same.first(where: { $0.name == item.name && $0.isDrawn }) {
                        // 펼침 애니메이션이 끝나도록 아주 잠깐 더 기다린다.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            self.pressLog.append("펼쳐진 자리 클릭 @\(Int(revealed.frame.midX)),\(Int(revealed.frame.midY))")
                            self.press(revealed)
                        }
                    } else if Date().timeIntervalSince(started) < 2 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { findAndPress() }
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { findAndPress() }
    }

    /// 보이는 아이콘은 그 자리를 실제로 클릭한다. 손쉬운 사용의 "누르기"는 성공이라고 답해도
    /// 메뉴가 안 열리는 앱이 많아서, 클릭을 먼저 쓰고 클릭할 자리가 없을 때만 "누르기"를 쓴다.
    @discardableResult
    func press(_ item: MenuBarItem) -> Bool {
        guard item.isDrawn else { return false }
        guard item.frame.width > 0 else {
            return AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success
        }

        // AX 좌표와 CGEvent 좌표는 둘 다 화면 왼쪽 위가 원점이라 그대로 쓴다.
        let point = CGPoint(x: item.frame.midX, y: item.frame.midY)
        let source = CGEventSource(stateID: .hidSystemState)
        CGWarpMouseCursorPosition(point)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            event?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
        return true
    }

    // MARK: - 진단 (개발용)

    /// Apple 메뉴 막대 프로세스들이 손쉬운 사용 정보를 어떤 모양으로 내놓는지 적는다.
    static func diagnostics() -> [String] {
        var out = ["--- diagnostics"]
        let targets = ["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver"]
        for app in NSWorkspace.shared.runningApplications where targets.contains(app.bundleIdentifier ?? "") {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 1.0)
            var names: CFArray?
            let result = AXUIElementCopyAttributeNames(element, &names)
            out.append("[\(app.bundleIdentifier ?? "")] names(\(result.rawValue)): \((names as? [String])?.joined(separator: ",") ?? "-")")
            for key in [kAXExtrasMenuBarAttribute, kAXMenuBarAttribute, kAXChildrenAttribute, kAXWindowsAttribute] {
                guard let value: AnyObject = attribute(element, key) else { out.append("  \(key): 없음"); continue }
                let list: [AXUIElement] = (value as? [AXUIElement]) ?? [value as! AXUIElement]
                out.append("  \(key): \(list.count)")
                for node in list.prefix(4) { out.append(contentsOf: describe(node, depth: 2)) }
            }
        }
        return out
    }

    private static func describe(_ node: AXUIElement, depth: Int) -> [String] {
        let role: String = attribute(node, kAXRoleAttribute) ?? "?"
        let subrole: String = attribute(node, kAXSubroleAttribute) ?? ""
        let label: String = (attribute(node, kAXDescriptionAttribute) as String?) ?? (attribute(node, kAXTitleAttribute) as String?) ?? ""
        let rect = frame(of: node).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-"
        var lines = [String(repeating: "  ", count: depth) + "\(role)/\(subrole) \(rect) \(label.prefix(30))"]
        if depth < 4, let kids: [AXUIElement] = attribute(node, kAXChildrenAttribute) {
            for kid in kids.prefix(30) { lines.append(contentsOf: describe(kid, depth: depth + 1)) }
        }
        return lines
    }

    // MARK: - 목록 읽기

    private static func enumerate(apps: [NSRunningApplication], barHeight: CGFloat, notch: ClosedRange<CGFloat>?) -> [MenuBarItem] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [MenuBarItem] = []
        var found: [(app: NSRunningApplication, element: AXUIElement, frame: CGRect, index: Int)] = []
        // macOS 27의 "가려진 메뉴 막대 항목 보기" 버튼(«). 이 버튼 왼쪽에 겹쳐 있는 아이콘은 넘쳐서 숨은 것이다.
        var overflow: (element: AXUIElement, frame: CGRect, pid: pid_t)?

        // 백그라운드 전용 프로그램(.prohibited)은 메뉴 막대 아이콘을 가질 수 없어서 묻지 않는다.
        let candidates = apps.filter { $0.processIdentifier != ownPID && $0.activationPolicy != .prohibited }
        // 앱마다 차례로 물으면 2초쯤 걸려서, 여러 앱에 동시에 묻는다.
        var perApp = [[(element: AXUIElement, frame: CGRect, isOverflow: Bool)]](repeating: [], count: candidates.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
            let app = candidates[i]
            let application = AXUIElementCreateApplication(app.processIdentifier)
            // 멈춘 앱 하나 때문에 전체가 기다리지 않게 짧게 끊는다.
            AXUIElementSetMessagingTimeout(application, 0.2)
            guard let bar: AXUIElement = attribute(application, kAXExtrasMenuBarAttribute) else { return }

            var local: [(element: AXUIElement, frame: CGRect, isOverflow: Bool)] = []
            // Apple 아이콘은 MenuBarAgent 아래 그룹 안에 한 겹 더 들어 있어서, 두 단계까지 내려가 찾는다.
            var queue: [(AXUIElement, Int)] = [(bar, 0)]
            while !queue.isEmpty {
                let (node, depth) = queue.removeFirst()
                guard let children: [AXUIElement] = attribute(node, kAXChildrenAttribute) else { continue }
                for child in children {
                    let role: String = attribute(child, kAXRoleAttribute) ?? ""
                    if role == kAXMenuBarItemRole as String, let frame = frame(of: child) {
                        local.append((child, frame, false))
                    } else if role == kAXButtonRole as String, depth == 0,
                              app.bundleIdentifier == "com.apple.MenuBarAgent", let frame = frame(of: child) {
                        local.append((child, frame, true))
                    } else if role == kAXGroupRole as String, depth < 2 {
                        queue.append((child, depth + 1))
                    }
                }
            }
            lock.lock()
            perApp[i] = local
            lock.unlock()
        }

        for (i, entries) in perApp.enumerated() {
            var index = 0
            for entry in entries {
                if entry.isOverflow {
                    overflow = (entry.element, entry.frame, candidates[i].processIdentifier)
                } else {
                    found.append((candidates[i], entry.element, entry.frame, index))
                    index += 1
                }
            }
        }

        if let overflow {
            result.append(MenuBarItem(
                id: "overflow", pid: overflow.pid, name: "가려진 메뉴 막대 항목 보기", frame: overflow.frame,
                isDrawn: true, isOverflowed: false, icon: nil, symbol: "chevron.left.2", element: overflow.element
            ))
        }

        do {
            for (app, element, frame, index) in found {
                guard frame.height <= barHeight + 1, frame.width > 0 else { continue }

                let title: String = attribute(element, kAXTitleAttribute) ?? ""
                let description: String = attribute(element, kAXDescriptionAttribute) ?? ""
                let help: String = attribute(element, kAXHelpAttribute) ?? ""
                let label = [description, title, help].first { !$0.isEmpty } ?? (app.localizedName ?? "알 수 없음")

                // 화면 맨 위 줄에 있고, 노치 뒤가 아니어야 실제로 보이는 아이콘이다.
                let onBar = frame.minY < barHeight
                let underNotch = notch.map { $0.contains(frame.midX) } ?? false
                // 숨은 아이콘은 « 버튼 바로 왼쪽(노치 오른쪽 끝)에 겹쳐 쌓인다.
                // « 를 눌러 펼치면 노치 왼쪽으로 옮겨 가므로 그때는 보이는 아이콘이다.
                let overflowed = overflow.map { button in
                    let stackStart = notch?.lowerBound ?? (button.frame.minX - 60)
                    return frame.midX >= stackStart && frame.midX < button.frame.maxX
                } ?? false
                let isApple = app.bundleIdentifier?.hasPrefix("com.apple.") ?? false
                // 여러 줄 이름(예: "50°C\n2746rpm")은 한 줄로
                let name = label.split(whereSeparator: \.isNewline).joined(separator: " ")

                result.append(MenuBarItem(
                    id: "\(app.processIdentifier)-\(index)-\(name)",
                    pid: app.processIdentifier,
                    name: name,
                    frame: frame,
                    isDrawn: onBar && !underNotch && !overflowed,
                    isOverflowed: overflowed,
                    icon: isApple ? nil : app.icon,
                    symbol: isApple ? symbol(for: label) : nil,
                    element: element
                ))
            }
        }
        // 메뉴 막대에 놓인 순서(왼쪽 → 오른쪽)대로
        return result.sorted { $0.frame.minX < $1.frame.minX }
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position = CGPoint.zero, size = CGSize.zero
        guard let p: AXValue = attribute(element, kAXPositionAttribute),
              let s: AXValue = attribute(element, kAXSizeAttribute),
              AXValueGetValue(p, .cgPoint, &position),
              AXValueGetValue(s, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// 노치가 차지하는 x 범위 (AX 좌표 기준)
    private static func notchRange(on screen: NSScreen?) -> ClosedRange<CGFloat>? {
        guard let screen, screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
        else { return nil }
        return (screen.frame.minX + left.width)...(screen.frame.maxX - right.width)
    }

    /// Apple 기본 아이콘은 앱 아이콘이 의미 없어서, 이름을 보고 비슷한 SF Symbol을 고른다.
    private static func symbol(for label: String) -> String {
        let text = label.lowercased()
        let table: [([String], String)] = [
            (["wi-fi", "wifi", "와이파이"], "wifi"),
            (["battery", "배터리"], "battery.75percent"),
            (["bluetooth", "블루투스"], "dot.radiowaves.left.and.right"),
            (["sound", "volume", "사운드", "음량"], "speaker.wave.2.fill"),
            (["control center", "제어 센터"], "switch.2"),
            (["clock", "시계"], "clock"),
            (["spotlight"], "magnifyingglass"),
            (["siri"], "waveform.circle"),
            (["focus", "집중 모드"], "moon.fill"),
            (["now playing", "지금 재생 중"], "play.circle"),
            (["display", "디스플레이"], "display"),
            (["keyboard", "input", "입력", "키보드"], "keyboard"),
            (["airdrop"], "airplayaudio"),
            (["screen mirroring", "화면 미러링"], "rectangle.on.rectangle"),
            (["time machine"], "clock.arrow.circlepath"),
            (["user", "사용자"], "person.crop.circle"),
            (["weather", "날씨"], "cloud.sun"),
        ]
        return table.first { keys, _ in keys.contains { text.contains($0) } }?.1 ?? "circle.grid.2x2"
    }
}
