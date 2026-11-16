import AppKit
import Combine
import SwiftUI

/// 노치 크기와 펼침 상태. 화면(컨트롤러)과 그림(뷰)이 같은 값을 쓴다.
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

final class NotchState: ObservableObject {
    @Published var expanded = false
    @Published var expandMode: ExpandMode =
        ExpandMode(rawValue: UserDefaults.standard.string(forKey: "expandMode") ?? "") ?? .hover {
        didSet { UserDefaults.standard.set(expandMode.rawValue, forKey: "expandMode") }
    }
    @Published var notchSize = CGSize(width: 200, height: 32)

    /// 노치 위쪽 모서리가 바깥으로 살짝 휘어지는 부분의 반지름.
    let flare: CGFloat = 10
    let expandedWidth: CGFloat = 400

    var sideWidth: CGFloat { notchSize.height + 6 }
    var collapsedSize: CGSize { CGSize(width: notchSize.width + sideWidth * 2, height: notchSize.height) }
    var expandedSize: CGSize { CGSize(width: expandedWidth, height: notchSize.height + 132) }
    var windowSize: CGSize { CGSize(width: expandedWidth + flare * 2 + 40, height: expandedSize.height + 20) }
}

/// 노치 위에 겹쳐 뜨는 창을 관리한다.
final class NotchController {
    private let player = NowPlaying()
    private let state = NotchState()
    private var panel: NotchPanel!
    private var screen: NSScreen?
    private var mouseTimer: Timer?
    private var hovering = false
    private var collapseWork: DispatchWorkItem?
    /// 클릭 모드에서 사용자가 펼쳐 둔 상태.
    private var pinned = false
    private var modeObserver: AnyCancellable?

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

        let view = NotchView(player: player, state: state) { [weak self] in self?.handleTap() }
        let host = FirstMouseHostingView(rootView: view)
        host.sizingOptions = []
        panel.contentView = host

        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.layout() }

        // 앱이 활성화되지 않아도 동작하도록 마우스 위치를 직접 확인한다. 한 번에 좌표 하나만 읽어서 가볍다.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.trackMouse()
        }
        timer.tolerance = 0.004
        // 메뉴가 열려 있거나 스크롤 중에도 멈추지 않게 common 모드에 건다.
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer

        // 설정을 바꾸면 펼쳐 둔 상태를 풀고 접은 모습에서 다시 시작한다.
        modeObserver = state.$expandMode.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            self.pinned = false
            self.collapseWork?.cancel()
            self.setExpanded(false)
        }

        player.onTrackChange = { [weak self] in self?.peek() }
        player.start()
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

    /// 지금 보이는 모양의 화면 좌표 영역.
    private func visibleRect() -> NSRect? {
        guard let screen, player.hasMedia else { return nil }
        let size = state.expanded ? state.expandedSize : state.collapsedSize
        let margin: CGFloat = state.expanded ? 8 : 4
        return NSRect(
            x: screen.frame.midX - size.width / 2 - margin,
            y: screen.frame.maxY - size.height - margin,
            width: size.width + margin * 2,
            height: size.height + margin
        )
    }

    private func trackMouse() {
        let inside = visibleRect()?.contains(NSEvent.mouseLocation) ?? false
        // 모양 밖에서는 클릭이 뒤의 앱으로 그대로 통과한다.
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
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
        withAnimation(value ? .spring(response: 0.3, dampingFraction: 0.78) : .spring(response: 0.26, dampingFraction: 0.92)) {
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
