import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// 메뉴 막대에 우리 아이콘(⠿)을 하나 두고, 누르면 그 아래에 "숨은 아이콘 판"을 띄운다.
/// 판에는 노치 때문에 macOS가 « 안에 숨긴 메뉴 막대 아이콘만 모아 보여 주고, 누르면 그 메뉴를 열어 준다.
/// 노치(음악)와는 따로 동작한다.
final class HiddenIconsController: NSObject {
    let tray = MenuBarTray()

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var outsideMonitor: Any?
    private var observers: [AnyCancellable] = []
    private static let autosaveName = "NotchMusicHiddenIcons"

    func setEnabled(_ enabled: Bool) {
        if enabled {
            installStatusItem()
            tray.requestPermission()
            observers = [
                tray.$trusted.removeDuplicates().sink { [weak self] trusted in
                    if trusted { self?.tray.startWatching() }
                },
            ]
        } else {
            closePanel()
            observers = []
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
        }
    }

    // MARK: - 메뉴 막대 아이콘

    private func installStatusItem() {
        guard statusItem == nil else { return }
        // 새 아이콘은 macOS가 맨 왼쪽(노치 쪽)에 놓아서 바로 숨겨지기 쉽다.
        // 처음 한 번은 시계 쪽(오른쪽 끝)에 놓아 달라고 위치를 적어 둔다. 사용자가 옮기면 그 자리가 기억된다.
        let key = "NSStatusItem Preferred Position \(Self.autosaveName)"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(40, forKey: key)
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = Self.autosaveName
        if let button = item.button {
            let image = NSImage(systemSymbolName: "circle.grid.3x3.fill", accessibilityDescription: "숨은 메뉴 막대 아이콘")
            image?.isTemplate = true
            button.image = image?.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            button.target = self
            button.action = #selector(togglePanel)
            button.toolTip = "숨은 메뉴 막대 아이콘 보기"
        }
        statusItem = item
    }

    @objc private func togglePanel() {
        if panel != nil {
            closePanel()
        } else {
            openPanel(underX: NSEvent.mouseLocation.x)
        }
    }

    // MARK: - 판

    private func openPanel(underX x: CGFloat) {
        tray.refresh()
        let view = HiddenIconsView(tray: tray) { [weak self] item in self?.press(item) }
        let host = FirstMouseHostingView(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: host.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = host
        self.panel = panel
        place(panel, underX: x)
        panel.orderFrontRegardless()

        // 목록을 읽어 오면 판 크기가 바뀌므로 다시 맞춘다.
        observers.append(tray.$items.dropFirst().receive(on: DispatchQueue.main).sink { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            DispatchQueue.main.async { self.place(panel, underX: x) }
        })

        // 판 밖을 누르면 닫는다.
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    /// 메뉴 막대 바로 아래, 우리 아이콘 밑에 판을 붙인다. 화면 밖으로 나가지 않게 맞춘다.
    private func place(_ panel: NSPanel, underX x: CGFloat) {
        guard let host = panel.contentView else { return }
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.minX <= x && x <= $0.frame.maxX } ?? NSScreen.main
        guard let screen else { return }
        let top = screen.visibleFrame.maxY - 6
        var originX = x - size.width / 2
        originX = min(max(originX, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
        panel.setFrame(NSRect(x: originX, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    private func closePanel() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        // 판을 열 때 붙인 크기 맞춤 구독도 같이 정리한다 (권한 구독 하나만 남긴다).
        if observers.count > 1 { observers.removeLast(observers.count - 1) }
    }

    private func press(_ item: MenuBarItem) {
        closePanel()
        // 판이 사라진 뒤에 눌러야 대신 보내는 클릭이 판에 먹히지 않는다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [tray] in tray.pressRevealing(item) }
    }

    // MARK: - 자체 시험 (개발용)

    /// 우리 아이콘을 눌러 판을 열고, 판에서 그 아이콘 자리를 실제 마우스로 클릭해 메뉴가 열렸는지 확인한다.
    func runSelfTest(pressing name: String, report: @escaping ([String]) -> Void) {
        var log: [String] = []
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [self] in
            log.append("권한=\(AXIsProcessTrusted()) 우리 아이콘 위치(AX)=\(ownItemFrame().map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "못 찾음")")
            statusItem?.button?.performClick(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                let hidden = tray.items.filter(\.isOverflowed)
                log.append("판 열림=\(panel != nil) 숨은 아이콘=\(hidden.map(\.name).joined(separator: ", "))")
                guard let panel, let index = hidden.firstIndex(where: { $0.name.contains(name) }),
                      let screen = NSScreen.screens.first else {
                    report(log + ["'\(name)'을 판에서 못 찾음"])
                    return
                }
                // 판 안 버튼 자리: 왼쪽 여백 10 + (버튼 32 + 간격 4) × 순서, 세로 가운데. AppKit → CG 좌표로 바꾼다.
                let frame = panel.frame
                let point = CGPoint(
                    x: frame.minX + 10 + CGFloat(index) * 36 + 16,
                    y: screen.frame.maxY - frame.midY
                )
                log.append("판에서 클릭: \(hidden[index].name) @ \(Int(point.x)),\(Int(point.y))")
                let before = Self.popupWindows()
                CGWarpMouseCursorPosition(point)
                for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                        .post(tap: .cghidEventTap)
                    usleep(60_000)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [self] in
                    let opened = Self.popupWindows().subtracting(before)
                    log.append(contentsOf: tray.pressLog)
                    log.append("결과: 판 닫힘=\(self.panel == nil) 새로 열린 창=\(opened.count)개 \(opened.sorted().joined(separator: ", "))")
                    for down in [true, false] {
                        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
                    }
                    report(log)
                }
            }
        }
    }

    /// 우리 메뉴 막대 아이콘의 실제 위치 (손쉬운 사용으로 읽음)
    func ownItemFrame() -> CGRect? {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var bar: CFTypeRef?, kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString, &bar) == .success,
              AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success,
              let item = (kids as? [AXUIElement])?.first
        else { return nil }
        var p: CFTypeRef?, s: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &p)
        AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &s)
        var point = CGPoint.zero, size = CGSize.zero
        if let p { AXValueGetValue(p as! AXValue, .cgPoint, &point) }
        if let s { AXValueGetValue(s as! AXValue, .cgSize, &size) }
        return CGRect(origin: point, size: size)
    }

    private static func popupWindows() -> Set<String> {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 20, layer != 24, layer != 25,
                  let number = info[kCGWindowNumber as String] as? Int,
                  (info[kCGWindowOwnerPID as String] as? Int32) != ProcessInfo.processInfo.processIdentifier
            else { return nil }
            return "\(info[kCGWindowOwnerName as String] as? String ?? "?")#\(number)@\(layer)"
        })
    }
}

// MARK: - 판 화면

private struct HiddenIconsView: View {
    @ObservedObject var tray: MenuBarTray
    let onPress: (MenuBarItem) -> Void

    var body: some View {
        let hidden = tray.items.filter(\.isOverflowed)
        Group {
            if !tray.trusted {
                message("손쉬운 사용 권한이 필요해요. 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 NotchMusic을 켜 주세요.")
            } else if hidden.isEmpty {
                message("숨은 아이콘이 없어요")
            } else {
                HStack(spacing: 4) {
                    ForEach(hidden) { item in
                        IconButton(item: item) { onPress(item) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .fixedSize()
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Color(white: 0.7))
            .frame(maxWidth: 260)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
    }
}

private struct IconButton: View {
    let item: MenuBarItem
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
                } else {
                    Image(systemName: item.symbol ?? "circle.grid.2x2")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: 32, height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(hovered ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovered = $0 }
        .help(item.name)
    }
}
