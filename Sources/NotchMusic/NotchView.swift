import AppKit
import ServiceManagement
import SwiftUI

struct NotchView: View {
    @ObservedObject var player: NowPlaying
    @ObservedObject var state: NotchState

    private var expanded: Bool { state.expanded && player.hasMedia }

    var body: some View {
        let size = expanded ? state.expandedSize : state.collapsedSize
        let shape = NotchShape(flare: state.flare, bottomRadius: expanded ? 26 : 10)

        ZStack(alignment: .top) {
            shape.fill(Color.black)

            if expanded {
                ExpandedContent(player: player, notchHeight: state.notchSize.height)
                    .padding(.horizontal, state.flare + 20)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            } else {
                CollapsedContent(player: player, sideWidth: state.sideWidth)
                    .padding(.horizontal, state.flare)
                    .frame(height: state.notchSize.height)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width + state.flare * 2, height: size.height)
        .clipShape(shape)
        .opacity(player.hasMedia ? 1 : 0)
        .contextMenu { MenuItems() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.3), value: player.hasMedia)
    }
}

// MARK: - 접힌 모습: 노치 왼쪽에 커버, 오른쪽에 파형

private struct CollapsedContent: View {
    @ObservedObject var player: NowPlaying
    let sideWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Cover(player: player, size: 20, radius: 5)
                .frame(width: sideWidth)
            Spacer(minLength: 0)
            Wave(playing: player.isPlaying, color: player.accent, height: 13)
                .frame(width: sideWidth)
        }
    }
}

// MARK: - 펼친 모습

private struct ExpandedContent: View {
    @ObservedObject var player: NowPlaying
    let notchHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Cover(player: player, size: 50, radius: 10)
                    .onTapGesture { player.openSourceApp() }
                    .help("재생 중인 앱 열기")

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(player.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.6))
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

                Wave(playing: player.isPlaying, color: player.accent, height: 18)
            }
            .padding(.top, notchHeight + 6)

            ProgressRow(player: player)
                .padding(.top, 14)

            Controls(player: player)
                .padding(.top, 8)
        }
    }
}

private struct Cover: View {
    @ObservedObject var player: NowPlaying
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let artwork = player.artwork {
                Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
            } else if let icon = player.appIcon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).padding(size * 0.08)
            } else {
                ZStack {
                    Color(white: 0.15)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(Color(white: 0.5))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// 재생 중이면 출렁이고, 멈추면 낮게 가라앉는 막대 네 개.
private struct Wave: View {
    let playing: Bool
    let color: Color
    let height: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let d = Double(i)
                    let level = playing
                        ? (sin(t * (4.1 + d * 1.3) + d * 1.7) + sin(t * (6.7 - d * 0.9) + d)) / 4 + 0.5
                        : 0
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: 3 + level * (height - 3))
                }
            }
            .frame(height: height)
            .animation(.easeOut(duration: 0.25), value: playing)
        }
    }
}

private struct ProgressRow: View {
    @ObservedObject var player: NowPlaying
    @State private var dragValue: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = max(player.duration, 0)
            let current = dragValue ?? player.position(at: context.date)
            let fraction = duration > 0 ? min(max(current / duration, 0), 1) : 0

            HStack(spacing: 10) {
                Text(format(current))
                    .frame(width: 34, alignment: .trailing)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(white: 0.2))
                        Capsule().fill(player.accent)
                            .frame(width: geometry.size.width * fraction)
                    }
                    .frame(height: dragValue == nil ? 4 : 6)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard duration > 0 else { return }
                                dragValue = min(max(value.location.x / geometry.size.width, 0), 1) * duration
                            }
                            .onEnded { _ in
                                if let dragValue { player.seek(to: dragValue) }
                                dragValue = nil
                            }
                    )
                }
                .frame(height: 14)
                Text("-" + format(max(duration - current, 0)))
                    .frame(width: 38, alignment: .leading)
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(Color(white: 0.55))
            .animation(.easeOut(duration: 0.15), value: dragValue == nil)
        }
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct Controls: View {
    @ObservedObject var player: NowPlaying

    var body: some View {
        HStack(spacing: 44) {
            ControlButton(symbol: "backward.fill", size: 17) { player.previous() }
            ControlButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", size: 24) { player.togglePlayPause() }
            ControlButton(symbol: "forward.fill", size: 17) { player.next() }
        }
    }
}

private struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white.opacity(hovered ? 1 : 0.85))
                .frame(width: 40, height: 32)
                .background(Circle().fill(Color.white.opacity(hovered ? 0.1 : 0)).frame(width: 38, height: 38))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovered = $0 }
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct MenuItems: View {
    var body: some View {
        Button(SMAppService.mainApp.status == .enabled ? "로그인 시 자동 실행 끄기" : "로그인 시 자동 실행 켜기") {
            let service = SMAppService.mainApp
            do {
                if service.status == .enabled { try service.unregister() } else { try service.register() }
            } catch {
                NSLog("NotchMusic: 자동 실행 설정 실패 \(error)")
            }
        }
        Divider()
        Button("NotchMusic 종료") { NSApp.terminate(nil) }
    }
}

// MARK: - 노치 모양

/// 위쪽 모서리는 바깥으로 휘어져 메뉴 막대에 녹아들고, 아래쪽 모서리는 둥근 실제 노치 같은 모양.
struct NotchShape: Shape {
    var flare: CGFloat
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let f = min(flare, h / 2)
        let r = min(bottomRadius, (w - f * 2) / 2, h - f)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: f, y: f), control: CGPoint(x: f, y: 0))
        path.addLine(to: CGPoint(x: f, y: h - r))
        path.addQuadCurve(to: CGPoint(x: f + r, y: h), control: CGPoint(x: f, y: h))
        path.addLine(to: CGPoint(x: w - f - r, y: h))
        path.addQuadCurve(to: CGPoint(x: w - f, y: h - r), control: CGPoint(x: w - f, y: h))
        path.addLine(to: CGPoint(x: w - f, y: f))
        path.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - f, y: 0))
        path.closeSubpath()
        return path
    }
}
