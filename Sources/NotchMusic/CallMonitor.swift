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
                let meet = app.flatMap { meetTitle(pid: $0.processIdentifier) }
                if let meet { return ("Google Meet", appBundle, .meet, meet.isEmpty ? appName : "\(meet) · \(appName)") }
                return (appName, appBundle, .other, "브라우저 통화")
            }
            return (appName, appBundle, .other, nil)
        }
        return nil
    }

    /// 브라우저 창 제목에서 Meet 회의 이름을 찾는다. 손쉬운 사용 권한이 없거나 Meet 창이 아니면 nil.
    /// 찾았는데 이름이 없으면 빈 문자열.
    private static func meetTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        for window in windows {
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            guard let text = title as? String, text.hasPrefix("Meet") || text.contains("Google Meet") else { continue }
            // "Meet - 주간 회의 - Google Chrome - 사람" → "주간 회의"
            let parts = text.components(separatedBy: CharacterSet(charactersIn: "-–—")).map { $0.trimmingCharacters(in: .whitespaces) }
            let name = parts.dropFirst().first { !$0.isEmpty && !$0.contains("Google") && !$0.contains("Chrome") } ?? ""
            return name
        }
        return nil
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
        // Meet이면 회의 창을 맨 앞으로 올린다 (손쉬운 사용 권한이 있을 때)
        if call.kind == .meet, AXIsProcessTrusted() {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
               let windows = value as? [AXUIElement] {
                for window in windows {
                    var title: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                    if let text = title as? String, text.hasPrefix("Meet") || text.contains("Google Meet") {
                        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                        break
                    }
                }
            }
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
