import AppKit
import Combine
import SwiftUI

enum ExpandMode: String, CaseIterable, Hashable {
    /// 마우스를 올리면 펼치고, 치우면 접는다.
    case hover
    /// 클릭하면 펼치고, 다시 클릭할 때까지 그대로 둔다.
    case click

    var title: String {
        switch self {
        case .hover: "마우스를 올리면"
        case .click: "클릭하면 (다시 클릭할 때까지 유지)"
        }
    }
}

enum CollapsedStyle: String, CaseIterable, Hashable {
    /// 커버와 막대를 노치 왼쪽에 모은다. 메뉴 막대 아이콘이 몰리는 오른쪽을 비워 둔다.
    case left
    /// 커버는 왼쪽, 막대는 오른쪽.
    case both

    var title: String {
        switch self {
        case .left: "왼쪽에만 (메뉴 막대 아이콘 안 가림)"
        case .both: "양옆"
        }
    }
}

enum ExpandedStyle: String, CaseIterable, Hashable {
    /// 메뉴 막대 줄까지 통째로 넓게 덮는다.
    case wide
    /// 메뉴 막대 줄에서는 노치 폭만 쓰고, 그 아래에서만 넓어진다.
    case belowBar

    var title: String {
        switch self {
        case .wide: "넓게"
        case .belowBar: "메뉴 막대 아이콘 피해서"
        }
    }
}

/// 노치 모양을 정하는 값. 모두 화면 가운데 기준 x 좌표(왼쪽은 음수)와 위에서부터의 높이.
struct NotchGeometry: Equatable {
    /// 메뉴 막대 줄 안에서 차지하는 폭
    var neckLeft: CGFloat
    var neckRight: CGFloat
    /// 메뉴 막대 아래로 내려온 부분의 폭
    var bodyLeft: CGFloat
    var bodyRight: CGFloat
    var height: CGFloat
}

/// 노치 크기, 설정, 펼침 상태. 화면(컨트롤러)과 그림(뷰)이 같은 값을 쓴다.
final class NotchState: ObservableObject {
    @Published var expanded = false
    @Published var notchSize = CGSize(width: 200, height: 32)
    @Published var expandMode = NotchState.load(ExpandMode.self, "expandMode", .hover) {
        didSet { UserDefaults.standard.set(expandMode.rawValue, forKey: "expandMode") }
    }
    @Published var collapsedStyle = NotchState.load(CollapsedStyle.self, "collapsedStyle", .left) {
        didSet { UserDefaults.standard.set(collapsedStyle.rawValue, forKey: "collapsedStyle") }
    }
    @Published var expandedStyle = NotchState.load(ExpandedStyle.self, "expandedStyle", .wide) {
        didSet { UserDefaults.standard.set(expandedStyle.rawValue, forKey: "expandedStyle") }
    }

    /// 노치 위쪽 모서리가 바깥으로 살짝 휘어지는 부분의 반지름.
    let flare: CGFloat = 8
    let expandedWidth: CGFloat = 400
    /// 메뉴 막대에 맞추기: 노치 양옆 빈 틈을 재서, 음악 표시가 메뉴나 아이콘을 덮지 않게 그 틈 안에만 둔다.
    /// 손쉬운 사용 권한이 필요하다. (예전 "메뉴 막대 서랍"을 켰던 사람은 켜진 채로 시작)
    @Published var fitToMenuBar = UserDefaults.standard.object(forKey: "fitToMenuBar") as? Bool
        ?? UserDefaults.standard.bool(forKey: "trayEnabled") {
        didSet { UserDefaults.standard.set(fitToMenuBar, forKey: "fitToMenuBar") }
    }
    /// 잰 빈 틈. nil이면 모르는 상태라 설정한 위치(왼쪽에만/양옆) 그대로 둔다.
    @Published var room: MenuBarSpace.Room?

    /// 지금 재생 중인 게 있는지 (컨트롤러가 NowPlaying에서 옮겨 넣는다)
    @Published var hasMedia = false

    /// 통화·회의 중인지 (컨트롤러가 CallMonitor에서 옮겨 넣는다). 통화가 음악보다 먼저 보인다.
    @Published var hasCall = false

    /// 노치는 음악이나 통화가 있을 때만 보인다.
    var isActive: Bool { hasMedia || hasCall }
    let expandedBodyHeight: CGFloat = 132

    var sideWidth: CGFloat { max(notchSize.height - 4, 26) }

    /// 접혔을 때 노치 왼쪽·오른쪽에 무엇을 둘지
    enum Piece { case cover, wave, call, timer, mic }
    struct CollapsedLayout: Equatable {
        var left: [Piece]
        var right: [Piece]
    }

    /// 조각마다 차지하는 폭과 바깥 여백
    let sidePadding: CGFloat = 8
    func width(of piece: Piece) -> CGFloat {
        switch piece {
        case .cover, .wave, .call: 28
        case .timer: 44
        case .mic: 24
        }
    }
    func width(of pieces: [Piece]) -> CGFloat {
        pieces.isEmpty ? 0 : pieces.reduce(0) { $0 + width(of: $1) } + sidePadding
    }

    /// 빈 틈에 들어가는 것 중 설정과 가장 가까운 배치를 고른다. 아무것도 안 들어가면 노치 안에 숨는다.
    var collapsedLayout: CollapsedLayout {
        let preferred: [CollapsedLayout]
        if hasCall {
            // 통화 중: 왼쪽에 전화 아이콘·시간, 오른쪽에 마이크 상태. 마이크 표시는 음소거를 잊지 않게 되도록 남긴다.
            preferred = [
                .init(left: [.call, .timer], right: [.mic]), .init(left: [.call, .timer, .mic], right: []),
                .init(left: [.call], right: [.mic]), .init(left: [.call, .mic], right: []),
                .init(left: [], right: [.call, .mic]), .init(left: [.mic], right: []), .init(left: [], right: [.mic]),
            ]
        } else {
            preferred = musicLayouts
        }
        guard fitToMenuBar, let room else { return preferred[0] }
        // 아이콘과 딱 붙지 않게 4pt 여유를 남긴다.
        return preferred.first { width(of: $0.left) <= room.left - 4 && width(of: $0.right) <= room.right - 4 }
            ?? .init(left: [], right: [])
    }

    private var musicLayouts: [CollapsedLayout] {
        collapsedStyle == .left
            ? [.init(left: [.cover, .wave], right: []), .init(left: [.cover], right: [.wave]),
               .init(left: [], right: [.cover, .wave]), .init(left: [.cover], right: []), .init(left: [], right: [.cover])]
            : [.init(left: [.cover], right: [.wave]), .init(left: [.cover, .wave], right: []),
               .init(left: [], right: [.cover, .wave]), .init(left: [.cover], right: []), .init(left: [], right: [.cover])]
    }

    var windowSize: CGSize {
        CGSize(width: expandedWidth + flare * 2 + 40, height: notchSize.height + expandedBodyHeight + 20)
    }

    func geometry(expanded: Bool) -> NotchGeometry {
        let half = notchSize.width / 2
        if expanded {
            let body = expandedWidth / 2
            // 넓게: 목과 몸이 같은 폭. 피해서: 메뉴 막대 줄에서는 노치 폭만.
            let neck = expandedStyle == .wide ? body : half
            return NotchGeometry(
                neckLeft: -neck, neckRight: neck, bodyLeft: -body, bodyRight: body,
                height: notchSize.height + expandedBodyHeight
            )
        }
        // 음악도 통화도 없으면 접힌 모습은 실제 노치와 똑같은 크기라 눈에 보이지 않는다.
        guard isActive else {
            return NotchGeometry(neckLeft: -half, neckRight: half, bodyLeft: -half, bodyRight: half, height: notchSize.height)
        }
        let layout = collapsedLayout
        let left = -(half + width(of: layout.left))
        let right = half + width(of: layout.right)
        return NotchGeometry(neckLeft: left, neckRight: right, bodyLeft: left, bodyRight: right, height: notchSize.height)
    }

    private static func load<T: RawRepresentable>(_: T.Type, _ key: String, _ fallback: T) -> T where T.RawValue == String {
        UserDefaults.standard.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }
}

/// 노치 위에 겹쳐 뜨는 창을 관리한다.
final class NotchController {
    private let player = NowPlaying()
    private let calls = CallMonitor()
    private let state = NotchState()
    private var panel: NotchPanel!
    private var screen: NSScreen?
    private var hovering = false
    private var collapseWork: DispatchWorkItem?
    /// 클릭 모드에서 사용자가 펼쳐 둔 상태.
    private var pinned = false
    private var observers: [AnyCancellable] = []
    private var mouseMonitors: [Any] = []
    /// 마우스가 노치 안에 있는 동안만 도는 타이머. 밖에서는 이벤트가 올 때만 확인한다.
    private var insideTimer: Timer?
    /// 메뉴 막대에 맞추기: 다시 잴 때를 알려 주는 알림과 감시들
    private var fitObservers: [NSObjectProtocol] = []
    private var menuBarClickMonitor: Any?
    private var permissionTimer: Timer?

    func start() {
        panel = NotchPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .mainMenu + 3
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true

        let view = NotchView(player: player, calls: calls, state: state, onTap: { [weak self] in self?.handleTap() })
        let host = FirstMouseHostingView(rootView: view)
        host.sizingOptions = []
        panel.contentView = host

        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.layout()
            self?.remeasure(after: 0.5)
        }

        // 마우스가 움직일 때만 깨어난다. (예전에는 1초에 60번씩 계속 확인했다)
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in self?.trackMouse() }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.trackMouse()
            return event
        }) {
            mouseMonitors.append(local)
        }

        // 설정을 바꾸면 펼쳐 둔 상태를 풀고 접은 모습에서 다시 시작한다.
        observers.append(state.$expandMode.dropFirst().sink { [weak self] _ in self?.resetExpansion() })
        observers.append(state.$collapsedStyle.dropFirst().sink { [weak self] _ in self?.resetExpansion() })

        player.onTrackChange = { [weak self] in self?.peek() }
        // 메뉴 막대에 맞추기를 켜면 권한부터 받고 빈 틈을 잰다.
        observers.append(state.$fitToMenuBar.removeDuplicates().sink { [weak self] enabled in
            self?.setFitting(enabled)
        })
        observers.append(player.$title.map { !$0.isEmpty }.removeDuplicates().sink { [weak self] has in
            self?.state.hasMedia = has
        })

        // 통화가 시작되면 노치에 통화를 먼저 보여 주고, 잠깐 펼쳐서 알린다.
        observers.append(calls.$call.map { $0 != nil }.removeDuplicates().sink { [weak self] has in
            guard let self else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { self.state.hasCall = has }
        })
        calls.onCallStart = { [weak self] in self?.peek() }

        player.start()
        calls.start()
    }

    /// 노치가 있는 화면 맨 위 가운데에 창을 붙인다.
    private func layout() {
        let target = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        guard let target else { return }
        screen = target

        if target.safeAreaInsets.top > 0,
           let left = target.auxiliaryTopLeftArea, let right = target.auxiliaryTopRightArea {
            state.notchSize = CGSize(
                width: target.frame.width - left.width - right.width, height: target.safeAreaInsets.top
            )
        } else {
            // 노치 없는 화면: 메뉴 막대 높이에 맞춘 가상 노치
            state.notchSize = CGSize(width: 190, height: NSStatusBar.system.thickness)
        }

        let size = state.windowSize
        let frame = target.frame
        panel.setFrame(
            NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height),
            display: true
        )
    }

    /// 마우스가 지금 보이는 노치 모양 안에 있는지. 메뉴 막대 줄과 그 아래를 따로 본다.
    private func isInside(_ point: NSPoint) -> Bool {
        guard let screen, state.isActive else { return false }
        let g = state.geometry(expanded: state.expanded)
        let mid = screen.frame.midX, top = screen.frame.maxY
        let barHeight = state.notchSize.height
        let margin: CGFloat = 4

        let neck = NSRect(x: mid + g.neckLeft, y: top - barHeight - margin, width: g.neckRight - g.neckLeft, height: barHeight + margin)
        if neck.insetBy(dx: -margin, dy: 0).contains(point) { return true }
        guard g.height > barHeight else { return false }
        let body = NSRect(x: mid + g.bodyLeft, y: top - g.height, width: g.bodyRight - g.bodyLeft, height: g.height - barHeight)
        return body.insetBy(dx: -margin * 2, dy: -margin * 2).contains(point)
    }

    // MARK: - 메뉴 막대에 맞추기

    private func setFitting(_ enabled: Bool) {
        fitObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        fitObservers = []
        if let menuBarClickMonitor { NSEvent.removeMonitor(menuBarClickMonitor) }
        menuBarClickMonitor = nil
        permissionTimer?.invalidate()
        guard enabled else {
            setRoom(nil)
            return
        }

        if !AXIsProcessTrusted() {
            // 시스템 설정의 손쉬운 사용 허락 창을 띄우고, 허락되면 바로 잰다.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            var remaining = 180
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                remaining -= 1
                if AXIsProcessTrusted() { self?.remeasure(after: 0) }
                if AXIsProcessTrusted() || remaining <= 0 { timer.invalidate() }
            }
        }

        // 틈이 바뀌는 때에만 다시 잰다. (계속 확인하지 않아서 CPU를 쓰지 않는다)
        //  - 앞에 있는 앱이 바뀌면 앱 메뉴 길이가 달라진다
        //  - 앱이 켜지거나 꺼지면 메뉴 막대 아이콘이 생기거나 사라진다
        let center = NSWorkspace.shared.notificationCenter
        let triggers: [(Notification.Name, TimeInterval)] = [
            (NSWorkspace.didActivateApplicationNotification, 0.15),
            (NSWorkspace.didLaunchApplicationNotification, 1.5),
            (NSWorkspace.didTerminateApplicationNotification, 0.5),
        ]
        for (name, delay) in triggers {
            fitObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.remeasure(after: delay)
            })
        }
        //  - 메뉴 막대를 누르면(« 펼치기·접기 포함) 아이콘 자리가 바뀔 수 있다
        menuBarClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            guard let self, let screen = self.screen else { return }
            if NSEvent.mouseLocation.y >= screen.frame.maxY - self.state.notchSize.height - 2 {
                self.remeasure(after: 0.4)
            }
        }
        remeasure(after: 0)
    }

    private func remeasure(after delay: TimeInterval) {
        guard state.fitToMenuBar else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                let room = MenuBarSpace.measure()
                DispatchQueue.main.async { self?.setRoom(room) }
            }
        }
    }

    private func setRoom(_ room: MenuBarSpace.Room?) {
        // 1pt 안쪽 차이는 무시해서 쓸데없이 다시 그리지 않는다.
        if let old = state.room, let room, abs(old.left - room.left) < 1, abs(old.right - room.right) < 1 { return }
        guard state.room != room else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { state.room = room }
    }

    private func trackMouse() {
        let inside = isInside(NSEvent.mouseLocation)
        // 모양 밖에서는 클릭이 뒤의 앱으로 그대로 통과한다.
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }

        // 창이 마우스를 받는 동안에는 바깥 이벤트가 안 오므로, 그동안만 짧게 확인한다.
        if inside, insideTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.trackMouse() }
            timer.tolerance = 0.01
            RunLoop.main.add(timer, forMode: .common)
            insideTimer = timer
        } else if !inside {
            insideTimer?.invalidate()
            insideTimer = nil
        }

        guard inside != hovering else { return }
        hovering = inside
        // 클릭 모드에서는 마우스를 올려도 모양이 그대로다.
        guard state.expandMode == .hover else { return }

        if inside {
            collapseWork?.cancel()
            setExpanded(true)
        } else {
            scheduleCollapse(after: 0.15)
        }
    }

    /// 곡이 바뀌면 잠깐 펼쳤다가 접는다.
    private func peek() {
        guard !keepOpen else { return }
        setExpanded(true)
        scheduleCollapse(after: 2.5)
    }

    /// 클릭 모드에서 노치(버튼 말고 빈 곳)를 누르면 펼치고, 다시 누르면 접는다.
    private func handleTap() {
        guard state.expandMode == .click else { return }
        collapseWork?.cancel()
        pinned = !state.expanded
        setExpanded(pinned)
    }

    private func resetExpansion() {
        pinned = false
        collapseWork?.cancel()
        setExpanded(false)
    }

    /// 지금 접으면 안 되는 상태인지: 마우스 모드에서 올려 둔 중이거나, 클릭 모드에서 펼쳐 둔 중.
    private var keepOpen: Bool {
        switch state.expandMode {
        case .hover: hovering
        case .click: pinned
        }
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.keepOpen else { return }
            self.setExpanded(false)
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func setExpanded(_ value: Bool) {
        guard state.expanded != value else { return }
        withAnimation(value ? .spring(response: 0.3, dampingFraction: 0.8) : .spring(response: 0.26, dampingFraction: 0.92)) {
            state.expanded = value
        }
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 앱이 비활성 상태여도 첫 클릭이 바로 버튼에 먹히게 한다.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
