import AppKit
import CoreAudio
import Darwin

/// 오디오를 쓰는 앱. 크롬·슬랙은 도우미 프로세스가 마이크·스피커를 잡으므로 그걸 감싼 앱으로 묶는다.
struct MeetingApp: Identifiable, Hashable {
    /// 바깥 .app 경로, 앱이 아니면 실행 파일 경로
    let id: String
    let appBundleID: String
    let appName: String
    /// 입력·출력 가리지 않고 이 앱에 속한 Core Audio 프로세스 객체 전부
    let objectIDs: [AudioObjectID]
    /// 묶음 중 하나라도 입력을 쓰는 중인지
    let isRunningInput: Bool

    static let meetingApps: Set<String> = [
        "us.zoom.xos",
        "com.tinyspeck.slackmacgap",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "Cisco-Systems.Spark",
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
    ]

    /// 실측용. 번들 ID 또는 실행 파일 이름 하나를 회의 앱으로 친다.
    static let testApp: String? = ProcessInfo.processInfo.environment["EARSHOT_TEST_APP"].flatMap { $0.isEmpty ? nil : $0 }

    var isMeeting: Bool {
        if Self.meetingApps.contains(appBundleID) { return true }
        guard let testApp = Self.testApp else { return false }
        return testApp == appBundleID || testApp == (id as NSString).lastPathComponent
    }
}

/// Core Audio 프로세스 목록(macOS 14+)을 1초마다 읽어 앱 단위로 묶는다.
@MainActor
final class MicMonitor: ObservableObject {
    @Published private(set) var apps: [MeetingApp] = []

    var inputApps: [MeetingApp] { apps.filter(\.isRunningInput) }

    nonisolated static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/EarShot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "detect.log")
    }()

    nonisolated private static let logLock = NSLock()
    private var timer: Timer?

    init() {
        Self.log("시작" + (MeetingApp.testApp.map { " (실측 앱=\($0))" } ?? ""))
        refresh()
        // .common 모드에 붙여야 메뉴가 펼쳐져 있는 동안에도 돈다.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        let now = Self.audioApps()
        let before = Set(inputApps.map(\.id))
        let after = Set(now.filter(\.isRunningInput).map(\.id))
        for app in now where app.isRunningInput && !before.contains(app.id) {
            Self.log("켜짐 \(app.appName) [\(app.appBundleID)] 객체=\(app.objectIDs.count)")
        }
        for app in inputApps where !after.contains(app.id) {
            Self.log("꺼짐 \(app.appName) [\(app.appBundleID)]")
        }
        if now != apps { apps = now }
    }

    /// detect.log 에 한 줄 덧붙인다. 녹음 쪽도 같은 파일을 쓴다.
    nonisolated static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        logLock.lock()
        defer { logLock.unlock() }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    // MARK: - Core Audio

    private static func audioApps() -> [MeetingApp] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let objects: [AudioObjectID] = CoreAudioProperty.readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        var groups: [String: (bundleID: String, name: String, objects: [AudioObjectID], input: Bool)] = [:]
        for object in objects {
            let pid: pid_t = CoreAudioProperty.read(object, kAudioProcessPropertyPID) ?? -1
            guard pid != ownPID else { continue }
            let running: UInt32 = CoreAudioProperty.read(object, kAudioProcessPropertyIsRunningInput) ?? 0
            let bundleID = CoreAudioProperty.readString(object, kAudioProcessPropertyBundleID) ?? ""
            let owner = owningApp(pid: pid, fallbackID: bundleID)
            var group = groups[owner.id] ?? (owner.bundleID, owner.name, [], false)
            group.objects.append(object)
            group.input = group.input || running != 0
            groups[owner.id] = group
        }
        return groups
            .map { MeetingApp(id: $0.key, appBundleID: $0.value.bundleID, appName: $0.value.name, objectIDs: $0.value.objects, isRunningInput: $0.value.input) }
            .sorted { ($0.appName, $0.id) < ($1.appName, $1.id) }
    }

    /// 도우미(…/Chrome.app/Contents/Frameworks/…/Helper.app)면 바깥 .app 을 찾는다.
    private static func owningApp(pid: pid_t, fallbackID: String) -> (id: String, bundleID: String, name: String) {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return ("pid \(pid)", fallbackID, "pid \(pid)") }
        let path = String(cString: buffer)
        guard let range = path.range(of: ".app/") else {
            let name = (path as NSString).lastPathComponent
            return (path, fallbackID.isEmpty ? name : fallbackID, name)
        }
        let outer = String(path[..<range.lowerBound]) + ".app"
        let bundle = Bundle(path: outer)
        let name = FileManager.default.displayName(atPath: outer).replacingOccurrences(of: ".app", with: "")
        return (outer, bundle?.bundleIdentifier ?? fallbackID, name)
    }
}

/// Core Audio 속성 읽기 도우미. 녹음 쪽(AppAudioTap)도 쓴다.
enum CoreAudioProperty {
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer) == noErr,
              size == UInt32(MemoryLayout<T>.size) else { return nil }
        return pointer.pointee
    }

    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func readArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: Int(size) / MemoryLayout<T>.stride))
    }
}
