import AppKit
import SwiftUI

/// 어댑터(perl + adapter.dylib)를 띄워 재생 정보를 받고, 명령을 보낸다.
final class NowPlaying: ObservableObject {
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var duration: Double = 0
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var timestamp = Date()
    @Published private(set) var rate: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var bundleId: String?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent: Color = ArtworkColor.fallback

    var hasMedia: Bool { !title.isEmpty }
    var onTrackChange: (() -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var receivedFirst = false
    /// 버튼을 누른 직후 잠깐은, 늦게 도착한 옛 상태가 화면을 되돌리지 않게 막는다.
    private var optimisticPlayingUntil = Date.distantPast
    private var optimisticSeekUntil = Date.distantPast

    /// 지금 시점의 재생 위치(초).
    func position(at date: Date) -> Double {
        guard isPlaying else { return elapsed }
        let value = elapsed + date.timeIntervalSince(timestamp) * max(rate, 0)
        return duration > 0 ? min(value, duration) : value
    }

    /// 앨범 커버가 없을 때 대신 보여 줄 재생 앱 아이콘.
    var appIcon: NSImage? {
        guard let bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func start() {
        guard
            let script = Bundle.main.path(forResource: "run", ofType: "pl"),
            let library = Bundle.main.path(forResource: "adapter", ofType: "dylib")
        else {
            NSLog("NotchMusic: 어댑터 파일을 찾을 수 없습니다. build.sh로 만든 .app에서 실행하세요.")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script, library]
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { self?.consume(data) }
        }
        // 어댑터가 죽으면 2초 뒤 다시 띄운다.
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.start() }
        }

        do {
            try process.run()
            self.process = process
            self.input = input.fileHandleForWriting
        } catch {
            NSLog("NotchMusic: 어댑터 실행 실패 \(error)")
        }
    }

    // MARK: - 명령

    func togglePlayPause() {
        send("toggle")
        // 반응이 바로 보이도록 먼저 바꿔 둔다. 실제 값은 곧 어댑터가 다시 알려 준다.
        elapsed = position(at: Date())
        timestamp = Date()
        isPlaying.toggle()
        optimisticPlayingUntil = Date().addingTimeInterval(1.0)
    }

    func next() { send("next") }
    func previous() { send("prev") }

    func seek(to seconds: Double) {
        send("seek \(seconds)")
        elapsed = seconds
        timestamp = Date()
        optimisticSeekUntil = Date().addingTimeInterval(1.0)
    }

    func openSourceApp() {
        guard let bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func send(_ command: String) {
        guard let data = (command + "\n").data(using: .utf8) else { return }
        try? input?.write(contentsOf: data)
    }

    // MARK: - 수신

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer = buffer.subdata(in: (newline + 1)..<buffer.endIndex)
            apply(line)
        }
    }

    private func apply(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }

        let newTitle = object["title"] as? String ?? ""
        let newArtist = object["artist"] as? String ?? ""
        let trackChanged = receivedFirst && !newTitle.isEmpty && (newTitle != title || newArtist != artist)

        let now = Date()
        // 곡이 바뀌었으면 막아 둔 값과 상관없이 새 정보를 그대로 쓴다.
        let keepPlaying = !trackChanged && now < optimisticPlayingUntil
        let keepPosition = !trackChanged && (now < optimisticSeekUntil || keepPlaying)

        // 값이 같으면 다시 넣지 않아서 SwiftUI가 쓸데없이 다시 그리지 않게 한다.
        if title != newTitle { title = newTitle }
        if artist != newArtist { artist = newArtist }
        let newDuration = object["duration"] as? Double ?? 0
        if duration != newDuration { duration = newDuration }
        let newBundle = object["bundleId"] as? String
        if bundleId != newBundle { bundleId = newBundle }
        let newRate = object["rate"] as? Double ?? 0
        if rate != newRate { rate = newRate }
        if !keepPlaying {
            let newPlaying = object["playing"] as? Bool ?? false
            if isPlaying != newPlaying { isPlaying = newPlaying }
        }
        if !keepPosition {
            elapsed = object["elapsed"] as? Double ?? 0
            if let seconds = object["timestamp"] as? Double {
                timestamp = Date(timeIntervalSince1970: seconds)
            }
        }

        if let encoded = object["artwork"] as? String {
            let image = Data(base64Encoded: encoded).flatMap(NSImage.init(data:))
            artwork = image
            accent = image.map { ArtworkColor.accent(from: $0) } ?? ArtworkColor.fallback
        } else if object["artwork"] is NSNull {
            artwork = nil
            accent = ArtworkColor.fallback
        }

        receivedFirst = true
        if trackChanged { onTrackChange?() }
    }
}
