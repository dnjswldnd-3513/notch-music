import AppKit
import ApplicationServices
import CoreAudio
import CoreMediaIO

/// 통화·회의 감지. 어떤 앱이 마이크를 쓰기 시작하면 통화로 보고, 그 앱 이름·통화 시간·카메라·음소거 상태를 알려 준다.
///
/// - 권한이 필요 없다. macOS 14.4부터 CoreAudio가 "마이크를 쓰는 프로세스" 목록을 공개로 알려 준다.
/// - 계속 확인하지 않는다. 마이크·카메라가 켜지고 꺼질 때 macOS가 보내는 알림에만 반응한다.
/// - Google Meet 회의 이름은 손쉬운 사용 권한이 있을 때만 브라우저 창 제목에서 읽는다.
final class CallMonitor: ObservableObject {
    enum Kind { case phone, meet, other }

    struct Call: Equatable {
        var appName: String
        var bundleId: String
        var kind: Kind
        var detail: String?
        var startedAt: Date
    }

    @Published private(set) var call: Call?
    @Published private(set) var cameraOn = false
    @Published private(set) var micMuted = false

    var onCallStart: (() -> Void)?

    /// 개발용 스냅샷에서 통화 화면을 그려 보려고 가짜 통화를 넣는다.
    func simulate(_ call: Call?, muted: Bool = false, camera: Bool = false) {
        self.call = call
        micMuted = muted
        cameraOn = camera
    }

    private let audioQueue = DispatchQueue(label: "notchmusic.call")
    private var inputDevice = AudioDeviceID(0)
    private var pendingEnd: DispatchWorkItem?
    private var pendingStart: DispatchWorkItem?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var muteListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var cameraListeners: [(CMIOObjectID, CMIOObjectPropertyListenerBlock)] = []

    /// 마이크를 써도 통화가 아닌 시스템 기능 (Siri 대기, 받아쓰기 등). Apple 앱 중 통화로 치는 것만 따로 둔다.
    private static let appleCallApps: [String: (String, Kind)] = [
        "com.apple.FaceTime": ("FaceTime", .phone),
        "com.apple.telephonyutilities.callservicesd": ("전화", .phone),
        "com.apple.TelephonyUtilities": ("전화", .phone),
        "com.apple.InCallService": ("전화", .phone),
    ]
    private static let browsers = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "org.mozilla.firefox", "com.brave.Browser", "com.naver.Whale", "com.operasoftware.Opera",
    ]

    func start() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var defaultAddress = address(kAudioHardwarePropertyDefaultInputDevice)
        let onDefaultChange: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.attachInputDevice() }
        defaultDeviceListener = onDefaultChange
        AudioObjectAddPropertyListenerBlock(system, &defaultAddress, audioQueue, onDefaultChange)
        attachInputDevice()
        attachCameras()
    }

    // MARK: - 마이크

    /// 기본 입력 장치(보통 맥 내장 마이크)에 "어디선가 쓰기 시작함/멈춤", "음소거 바뀜" 알림을 건다.
    private func attachInputDevice() {
        audioQueue.async { [self] in
            if inputDevice != 0 {
                var running = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
                if let deviceListener { AudioObjectRemovePropertyListenerBlock(inputDevice, &running, audioQueue, deviceListener) }
                var mute = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
                if let muteListener { AudioObjectRemovePropertyListenerBlock(inputDevice, &mute, audioQueue, muteListener) }
            }
            inputDevice = Self.read(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultInputDevice), AudioDeviceID(0))
            guard inputDevice != 0 else { return }

            var running = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            let onRunning: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.micUsageChanged() }
            deviceListener = onRunning
            AudioObjectAddPropertyListenerBlock(inputDevice, &running, audioQueue, onRunning)

            var mute = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
            let onMute: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refreshMute() }
            muteListener = onMute
            AudioObjectAddPropertyListenerBlock(inputDevice, &mute, audioQueue, onMute)

            refreshMute()
            micUsageChanged()
        }
    }

    private func micUsageChanged() {
        let found = Self.callingApp()
        DispatchQueue.main.async { [self] in
            if let found {
                pendingEnd?.cancel()
                pendingEnd = nil
                if var current = call, current.bundleId == found.bundleId {
                    current.detail = found.detail ?? current.detail
                    call = current
                    return
                }
                // 받아쓰기처럼 잠깐 켜졌다 꺼지는 건 통화로 치지 않게 1.5초 기다려 본다.
                pendingStart?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, let still = Self.callingApp(), still.bundleId == found.bundleId else { return }
                    self.call = Call(appName: still.appName, bundleId: still.bundleId, kind: still.kind,
                                     detail: still.detail, startedAt: Date().addingTimeInterval(-1.5))
                    self.onCallStart?()
                }
                pendingStart = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
            } else {
                pendingStart?.cancel()
                pendingStart = nil
                guard call != nil, pendingEnd == nil else { return }
                // 잠깐 끊겼다 다시 이어지는 경우가 있어 3초 지켜본 뒤 끝낸다.
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    if Self.callingApp() == nil { self.call = nil }
                    self.pendingEnd = nil
                }
                pendingEnd = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
            }
        }
    }

    /// 개발용: 지금 마이크·스피커를 쓰는 프로세스 목록과, 통화로 본 앱
    static func debugLines() -> [String] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddress = plainAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size)
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &processes)
        var lines: [String] = []
        for process in processes {
            let input: UInt32 = read(process, plainAddress(kAudioProcessPropertyIsRunningInput), 0)
            let output: UInt32 = read(process, plainAddress(kAudioProcessPropertyIsRunningOutput), 0)
            guard input != 0 || output != 0 else { continue }
            lines.append("마이크=\(input) 스피커=\(output) \(string(process, kAudioProcessPropertyBundleID) ?? "?")")
        }
        let found = callingApp()
        lines.append("통화로 본 앱: \(found.map { "\($0.appName) / \($0.detail ?? "-")" } ?? "없음")")
        return lines
    }

    /// 지금 마이크를 쓰는 앱 중 통화로 볼 앱 하나
    private static func callingApp() -> (appName: String, bundleId: String, kind: Kind, detail: String?)? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size) == noErr, size > 0 else { return nil }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &processes) == noErr else { return nil }

        for process in processes {
            let input: UInt32 = read(process, plainAddress(kAudioProcessPropertyIsRunningInput), 0)
            guard input != 0, let bundle = string(process, kAudioProcessPropertyBundleID), !bundle.isEmpty else { continue }

            if let (name, kind) = appleCallApps.first(where: { bundle.hasPrefix($0.key) })?.value {
                return (name, bundle, kind, nil)
            }
            if bundle.hasPrefix("com.apple.") { continue } // Siri 대기, 받아쓰기 등

            // 크롬 "도우미" 프로세스처럼 이름이 길면, 실행 중인 앱 중 앞부분이 같은 앱으로 묶는다.
            let app = NSWorkspace.shared.runningApplications.first {
                guard let id = $0.bundleIdentifier else { return false }
                return bundle == id || bundle.hasPrefix(id + ".")
            }
            let appBundle = app?.bundleIdentifier ?? bundle
            let appName = app?.localizedName ?? bundle

            if browsers.contains(appBundle) {
                let meet = meetTitle(bundleId: appBundle)
                if let meet { return ("Google Meet", appBundle, .meet, meet.isEmpty ? appName : "\(meet) · \(appName)") }
                return (appName, appBundle, .other, "브라우저 통화")
            }
            return (appName, appBundle, .other, nil)
        }
        return nil
    }

    /// 브라우저에 "meet.google.com 탭이 열려 있는지" 물어서 회의 이름을 찾는다. (탭 주소로 찾아서 어느 창·탭에 있든 찾는다)
    /// Meet 탭이 없으면 nil, 있는데 이름을 모르면 빈 문자열. 처음 한 번 "브라우저 제어" 허락 창이 뜬다.
    private static func meetTitle(bundleId: String) -> String? {
        guard let output = runBrowserScript(bundleId: bundleId, action: "title"), !output.isEmpty else { return nil }
        // 탭 제목 예: "Meet - abc-defg-hij", "Meet – 주간 회의", "주간 회의 - Google Meet"
        var title = output.components(separatedBy: "\n").first ?? ""
        for junk in ["Google Meet", "Meet - ", "Meet – ", "Meet — ", " - ", " – "] {
            title = title.replacingOccurrences(of: junk, with: junk.hasPrefix("Meet") || junk == "Google Meet" ? "" : " ")
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    /// Chrome 계열·Safari에 AppleScript로 Meet 탭을 묻거나(title) 그 탭을 앞으로 가져온다(focus).
    /// osascript를 따로 띄워서 앱이 멈추지 않게 하고, 2초 안에 답이 없으면 포기한다.
    @discardableResult
    private static func runBrowserScript(bundleId: String, action: String) -> String? {
        let isSafari = bundleId == "com.apple.Safari"
        let urlProp = "URL", titleProp = isSafari ? "name" : "title"
        let found: String
        if action == "focus" {
            found = isSafari
                ? "set current tab of w to t\nset index of w to 1\nactivate\nreturn \"ok\""
                : "set active tab index of w to i\nset index of w to 1\nactivate\nreturn \"ok\""
        } else {
            found = "return \(titleProp) of t"
        }
        let script = """
        tell application id "\(bundleId)"
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    if \(urlProp) of t contains "meet.google.com/" and \(urlProp) of t does not end with "meet.google.com/" then
                        \(found)
                    end if
                end repeat
            end repeat
            return ""
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 통화 중이면 앱·회의 이름을 다시 확인한다. (노치를 펼칠 때 부른다. 예: 브라우저 제어를 나중에 허락한 경우)
    func refreshDetails() {
        guard call != nil else { return }
        audioQueue.async { [weak self] in
            guard let found = Self.callingApp() else { return }
            DispatchQueue.main.async {
                guard let self, var current = self.call else { return }
                current.appName = found.appName
                current.bundleId = found.bundleId
                current.kind = found.kind
                current.detail = found.detail
                if self.call != current { self.call = current }
            }
        }
    }

    // MARK: - 음소거

    private func refreshMute() {
        let muted: UInt32 = Self.read(inputDevice, address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput), 0)
        DispatchQueue.main.async { self.micMuted = muted != 0 }
    }

    /// 맥 마이크 자체를 끄고 켠다. 어떤 앱이든 상대에게 내 소리가 안 간다.
    func toggleMute() {
        let target: UInt32 = micMuted ? 0 : 1
        micMuted = target != 0
        audioQueue.async { [self] in
            var mute = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput)
            var value = target
            AudioObjectSetPropertyData(inputDevice, &mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
            refreshMute()
        }
    }

    // MARK: - 카메라

    private func attachCameras() {
        var devicesAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &devicesAddress, 0, nil, &size) == 0 else { return }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &devicesAddress, 0, nil, size, &used, &devices)

        for device in devices {
            var running = Self.cameraRunningAddress
            let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.refreshCamera() }
            if CMIOObjectAddPropertyListenerBlock(device, &running, audioQueue, listener) == 0 {
                cameraListeners.append((device, listener))
            }
        }
        refreshCamera()
    }

    private static var cameraRunningAddress: CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
        )
    }

    private func refreshCamera() {
        let on = cameraListeners.contains { device, _ in
            var running = Self.cameraRunningAddress
            var value: UInt32 = 0
            var used: UInt32 = 0
            CMIOObjectGetPropertyData(device, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value)
            return value != 0
        }
        DispatchQueue.main.async { self.cameraOn = on }
    }

    // MARK: - 통화 중인 앱으로 가기

    func openCallApp() {
        guard let call, let app = NSRunningApplication.runningApplications(withBundleIdentifier: call.bundleId).first else {
            if let call, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: call.bundleId) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
            return
        }
        // Meet이면 브라우저에게 회의 탭을 골라 맨 앞으로 가져오게 한다.
        if call.kind == .meet {
            let bundle = call.bundleId
            DispatchQueue.global(qos: .userInitiated).async { Self.runBrowserScript(bundleId: bundle, action: "focus") }
            return
        }
        app.activate()
    }

    // MARK: - CoreAudio 도우미

    private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func plainAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ fallback: T) -> T {
        var address = address
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : fallback
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = plainAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
