import AppKit
import ApplicationServices

/// 노치 양옆에 메뉴 막대가 비워 둔 빈 틈의 폭을 잰다. (손쉬운 사용으로 위치만 읽고, 아무것도 누르지 않는다)
///
/// - 왼쪽 틈: 앱 메뉴(파일, 편집 …)나 « 로 펼쳐진 아이콘의 오른쪽 끝 ~ 노치 왼쪽 끝
/// - 오른쪽 틈: 노치 오른쪽 끝 ~ « 버튼(없으면 가장 왼쪽 메뉴 막대 아이콘)
enum MenuBarSpace {
    struct Room: Equatable {
        var left: CGFloat
        var right: CGFloat
    }

    /// 손쉬운 사용 권한이 없거나 노치가 없으면 nil
    static func measure() -> Room? {
        guard AXIsProcessTrusted(),
              let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let leftArea = screen.auxiliaryTopLeftArea, let rightArea = screen.auxiliaryTopRightArea
        else { return nil }
        let notchLeft = screen.frame.minX + leftArea.width
        let notchRight = screen.frame.maxX - rightArea.width
        let barHeight = screen.safeAreaInsets.top

        var leftEdge = screen.frame.minX
        var rightEdge = screen.frame.maxX

        // 1. 지금 앞에 있는 앱의 메뉴(파일, 편집 …)가 어디까지 오는지
        if let front = NSWorkspace.shared.frontmostApplication {
            let app = AXUIElementCreateApplication(front.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.2)
            if let bar: AXUIElement = attribute(app, kAXMenuBarAttribute),
               let menus: [AXUIElement] = attribute(bar, kAXChildrenAttribute) {
                for menu in menus {
                    guard let f = frame(of: menu), f.width > 0, f.minY < barHeight, f.minX < notchLeft else { continue }
                    leftEdge = max(leftEdge, f.maxX)
                }
            }
        }

        // 2. 메뉴 막대 아이콘들. macOS 27은 MenuBarAgent가 모든 아이콘 자리를 창으로 들고 있다.
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first
        else { return Room(left: notchLeft - leftEdge, right: rightEdge - notchRight) }
        let element = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)

        var overflowButton: CGRect?
        var itemFrames: [CGRect] = []
        if let extras: AXUIElement = attribute(element, kAXExtrasMenuBarAttribute),
           let kids: [AXUIElement] = attribute(extras, kAXChildrenAttribute) {
            for kid in kids where (attribute(kid, kAXRoleAttribute) as String?) == (kAXButtonRole as String) {
                overflowButton = frame(of: kid)
            }
        }
        if let windows: [AXUIElement] = attribute(element, kAXChildrenAttribute) {
            for window in windows {
                for host in (attribute(window, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                    if let f = frame(of: host), f.width > 0, f.minY < barHeight { itemFrames.append(f) }
                }
            }
        }

        // 오른쪽: « 버튼이 있으면 그게 경계다. (« 왼쪽에 겹쳐 쌓인 숨은 아이콘은 그려지지 않으니 무시)
        if let overflowButton {
            rightEdge = overflowButton.minX
        } else if let nearest = itemFrames.filter({ $0.minX >= notchRight - 1 }).map(\.minX).min() {
            rightEdge = nearest
        }
        // 왼쪽: « 로 펼쳐진 아이콘은 노치 왼쪽에 놓인다.
        for f in itemFrames where f.maxX <= notchLeft + 1 {
            leftEdge = max(leftEdge, f.maxX)
        }

        return Room(left: max(0, notchLeft - leftEdge), right: max(0, rightEdge - notchRight))
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
}
