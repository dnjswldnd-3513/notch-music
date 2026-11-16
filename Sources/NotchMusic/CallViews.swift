import SwiftUI

private let callGreen = Color(red: 0.20, green: 0.78, blue: 0.35)
private let muteRed = Color(red: 1.0, green: 0.27, blue: 0.23)

/// 통화 종류를 나타내는 둥근 사각 아이콘 (전화: 초록, Meet: 흰 바탕 파란 카메라, 그 밖: 초록 말풍선)
struct CallBadge: View {
    let kind: CallMonitor.Kind
    let size: CGFloat

    var body: some View {
        let (symbol, background, foreground): (String, Color, Color) = switch kind {
        case .phone: ("phone.fill", callGreen, .white)
        case .meet: ("video.fill", .white, Color(red: 0.10, green: 0.45, blue: 0.91))
        case .other: ("waveform", callGreen, .white)
        }
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(background))
    }
}

/// 통화 시간. 1초에 한 번만 다시 그린다.
struct CallTimer: View {
    let start: Date
    let size: CGFloat
    var color: Color = callGreen

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(start)))
                .font(.system(size: size, weight: .medium).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// 마이크 상태. 음소거 중이면 빨간 마이크로 계속 보여서 끈 걸 잊지 않게 한다.
struct MicIndicator: View {
    let muted: Bool
    let size: CGFloat

    var body: some View {
        Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(muted ? muteRed : callGreen)
            .contentTransition(.symbolEffect(.replace))
    }
}

/// 펼쳤을 때 통화 화면: 앱·회의 이름, 통화 시간, 카메라 상태, 마이크 끄기·앱으로 가기 버튼
struct CallExpandedContent: View {
    @ObservedObject var calls: CallMonitor
    let call: CallMonitor.Call
    let barHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                CallBadge(kind: call.kind, size: 46)

                VStack(alignment: .leading, spacing: 2) {
                    Text(call.appName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(call.detail ?? (call.kind == .phone ? "통화 중" : "마이크 사용 중"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.6))
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 3) {
                    CallTimer(start: call.startedAt, size: 20, color: .white)
                    HStack(spacing: 4) {
                        Image(systemName: calls.cameraOn ? "video.fill" : "video.slash.fill")
                            .foregroundStyle(calls.cameraOn ? callGreen : Color(white: 0.45))
                        Text(calls.cameraOn ? "카메라 켜짐" : "카메라 꺼짐")
                            .foregroundStyle(Color(white: 0.6))
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(.top, barHeight + 10)

            HStack(spacing: 10) {
                CallButton(
                    symbol: calls.micMuted ? "mic.fill" : "mic.slash.fill",
                    title: calls.micMuted ? "마이크 켜기" : "마이크 끄기",
                    tint: calls.micMuted ? callGreen : muteRed
                ) { calls.toggleMute() }
                CallButton(
                    symbol: "arrow.up.forward.app",
                    title: call.kind == .meet ? "회의로 가기" : "앱으로 가기",
                    tint: .white
                ) { calls.openCallApp() }
            }
            .padding(.top, 18)

            if calls.micMuted {
                Text("맥 마이크가 꺼져 있어요. 상대에게 내 소리가 들리지 않아요.")
                    .font(.system(size: 10))
                    .foregroundStyle(muteRed.opacity(0.9))
                    .padding(.top, 6)
            }
        }
    }
}

private struct CallButton: View {
    let symbol: String
    let title: String
    let tint: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).foregroundStyle(.white)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(hovered ? 0.16 : 0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { hovered = $0 }
    }
}
