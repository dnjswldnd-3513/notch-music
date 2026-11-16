import AppKit
import ServiceManagement
import SwiftUI

struct NotchView: View {
    @ObservedObject var player: NowPlaying
    @ObservedObject var state: NotchState
    var onTap: () -> Void = {}

    private var expanded: Bool { state.expanded && player.hasMedia }

    var body: some View {
        let g = state.geometry(expanded: expanded)
        let window = state.windowSize
        let center = window.width / 2
        let shape = NotchShape(
            geometry: g, barHeight: state.notchSize.height, flare: state.flare, bottomRadius: expanded ? 24 : 10
        )

        ZStack(alignment: .topLeading) {
            shape.fill(Color.black)

            if expanded {
                ExpandedContent(player: player, barHeight: state.notchSize.height)
                    .padding(.horizontal, 22)
                    .frame(width: g.bodyRight - g.bodyLeft)
                    .offset(x: center + g.bodyLeft)
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
            } else {
                CollapsedContent(player: player, style: state.collapsedStyle, sideWidth: state.sideWidth)
                    .frame(width: g.neckRight - g.neckLeft, height: state.notchSize.height)
                    .offset(x: center + g.neckLeft)
                    .transition(.opacity)
            }
        }
        .frame(width: window.width, height: window.height, alignment: .topLeading)
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture { onTap() }
        .opacity(player.hasMedia ? 1 : 0)
        .contextMenu { MenuItems(state: state) }
        .animation(.easeInOut(duration: 0.3), value: player.hasMedia)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.collapsedStyle)
    }
}

// MARK: - 접힌 모습

private struct CollapsedContent: View {
    @ObservedObject var player: NowPlaying
    let style: CollapsedStyle
    let sideWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            switch style {
            case .left:
                HStack(spacing: 8) {
                    Cover(player: player, size: 20, radius: 5)
                    Wave(playing: player.isPlaying, color: player.accent, height: 13)
                }
                .frame(width: sideWidth * 2)
                Spacer(minLength: 0)
            case .both:
                Cover(player: player, size: 20, radius: 5)
                    .frame(width: sideWidth)
                Spacer(minLength: 0)
                Wave(playing: player.isPlaying, color: player.accent, height: 13)
                    .frame(width: sideWidth)
            }
        }
    }
}

// MARK: - 펼친 모습

private struct ExpandedContent: View {
    @ObservedObject var player: NowPlaying
    let barHeight: CGFloat

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
            .padding(.top, barHeight + 10)

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
/// Core Animation이 그래픽 쪽에서 직접 움직이므로, 앱은 재생/멈춤이 바뀔 때만 일한다.
private struct Wave: NSViewRepresentable {
    let playing: Bool
    let color: Color
    let height: CGFloat

    func makeNSView(context: Context) -> WaveView { WaveView(barHeight: height) }

    func updateNSView(_ view: WaveView, context: Context) {
        view.update(playing: playing, color: NSColor(color).cgColor)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WaveView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

final class WaveView: NSView {
    private let barHeight: CGFloat
    private let barWidth: CGFloat = 3
    private let gap: CGFloat = 2
    private let minHeight: CGFloat = 3
    private var bars: [CALayer] = []
    private var playing: Bool?
    private var color: CGColor?

    init(barHeight: CGFloat) {
        self.barHeight = barHeight
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<4 {
            let bar = CALayer()
            bar.cornerRadius = barWidth / 2
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: barWidth * 4 + gap * 3, height: barHeight)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: barWidth, height: playing == true ? barHeight : minHeight)
            bar.position = CGPoint(x: CGFloat(i) * (barWidth + gap) + barWidth / 2, y: bounds.midY)
        }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        bars.forEach { $0.contentsScale = scale }
    }

    func update(playing: Bool, color: CGColor) {
        if self.color != color {
            self.color = color
            bars.forEach { $0.backgroundColor = color }
        }
        guard self.playing != playing else { return }
        self.playing = playing

        let durations: [CFTimeInterval] = [0.46, 0.62, 0.38, 0.54]
        for (i, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            if playing {
                let animation = CABasicAnimation(keyPath: "bounds.size.height")
                animation.fromValue = minHeight + 1
                animation.toValue = barHeight
                animation.duration = durations[i]
                animation.autoreverses = true
                animation.repeatCount = .infinity
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animation.timeOffset = Double(i) * 0.17
                bar.add(animation, forKey: "wave")
            } else {
                // 멈추면 부드럽게 가라앉는다.
                let settle = CABasicAnimation(keyPath: "bounds.size.height")
                settle.fromValue = bar.presentation()?.bounds.height ?? barHeight
                settle.toValue = minHeight
                settle.duration = 0.25
                bar.add(settle, forKey: "settle")
            }
        }
        needsLayout = true
    }
}

private struct ProgressRow: View {
    @ObservedObject var player: NowPlaying
    @State private var dragValue: Double?

    var body: some View {
        // 펼쳐져 있을 때만 존재하는 뷰라서, 접혀 있을 때는 이 타이머도 돌지 않는다.
        TimelineView(.periodic(from: .now, by: 1)) { context in
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
    @ObservedObject var state: NotchState

    var body: some View {
        Picker("펼치는 방법", selection: $state.expandMode) {
            ForEach(ExpandMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Picker("접혔을 때 위치", selection: $state.collapsedStyle) {
            ForEach(CollapsedStyle.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Picker("펼친 모양", selection: $state.expandedStyle) {
            ForEach(ExpandedStyle.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Divider()
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

/// 메뉴 막대 줄에서는 좁은 "목"이고, 그 아래로 넓은 "몸"이 퍼지는 모양.
/// 접혀 있을 때는 목과 몸의 폭이 같아서 그냥 노치를 옆으로 늘린 모양이 된다.
/// 위쪽 모서리는 바깥으로 휘어져 메뉴 막대에 녹아든다.
struct NotchShape: Shape {
    var geometry: NotchGeometry
    var barHeight: CGFloat
    var flare: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<
        AnimatablePair<CGFloat, CGFloat>,
        AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>
    > {
        get {
            AnimatablePair(
                AnimatablePair(geometry.neckLeft, geometry.neckRight),
                AnimatablePair(
                    AnimatablePair(geometry.bodyLeft, geometry.bodyRight),
                    AnimatablePair(geometry.height, bottomRadius)
                )
            )
        }
        set {
            geometry.neckLeft = newValue.first.first
            geometry.neckRight = newValue.first.second
            geometry.bodyLeft = newValue.second.first.first
            geometry.bodyRight = newValue.second.first.second
            geometry.height = newValue.second.second.first
            bottomRadius = newValue.second.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let top = barHeight
        let total = max(geometry.height, top)
        let nl = cx + geometry.neckLeft, nr = cx + geometry.neckRight
        let bl = cx + min(geometry.bodyLeft, geometry.neckLeft)
        let br = cx + max(geometry.bodyRight, geometry.neckRight)
        let f = min(flare, top / 2)

        // 목과 몸이 만나는 곳의 둥근 반지름. 차이가 없으면 0이 되어 곧은 옆면이 된다.
        let drop = total - top
        let jl = max(0, min(10, (nl - bl) / 2, drop / 2))
        let jr = max(0, min(10, (br - nr) / 2, drop / 2))
        let start = max(jl > 0.5 ? top + jl : f, jr > 0.5 ? top + jr : f)
        let r = max(0, min(bottomRadius, (br - bl) / 2, total - start))

        var p = Path()
        p.move(to: CGPoint(x: nl - f, y: 0))
        p.addQuadCurve(to: CGPoint(x: nl, y: f), control: CGPoint(x: nl, y: 0))
        if jl > 0.5 {
            p.addLine(to: CGPoint(x: nl, y: top - jl))
            p.addQuadCurve(to: CGPoint(x: nl - jl, y: top), control: CGPoint(x: nl, y: top))
            p.addLine(to: CGPoint(x: bl + jl, y: top))
            p.addQuadCurve(to: CGPoint(x: bl, y: top + jl), control: CGPoint(x: bl, y: top))
        }
        p.addLine(to: CGPoint(x: bl, y: total - r))
        p.addQuadCurve(to: CGPoint(x: bl + r, y: total), control: CGPoint(x: bl, y: total))
        p.addLine(to: CGPoint(x: br - r, y: total))
        p.addQuadCurve(to: CGPoint(x: br, y: total - r), control: CGPoint(x: br, y: total))
        if jr > 0.5 {
            p.addLine(to: CGPoint(x: br, y: top + jr))
            p.addQuadCurve(to: CGPoint(x: br - jr, y: top), control: CGPoint(x: br, y: top))
            p.addLine(to: CGPoint(x: nr + jr, y: top))
            p.addQuadCurve(to: CGPoint(x: nr, y: top - jr), control: CGPoint(x: nr, y: top))
        }
        p.addLine(to: CGPoint(x: nr, y: f))
        p.addQuadCurve(to: CGPoint(x: nr + f, y: 0), control: CGPoint(x: nr, y: 0))
        p.closeSubpath()
        return p
    }
}
