import SwiftUI
import UserNotifications

@main
struct EarShotApp: App {
    @StateObject private var monitor: MicMonitor
    @StateObject private var recorder: RecordingController
    @StateObject private var loginItem = LoginItem()
    @StateObject private var delivery: Delivery
    @StateObject private var saveQueue: SaveQueue
    @StateObject private var audioSettings = AudioSettings.shared
    @StateObject private var conversion = ConversionStatus.shared

    init() {
        // 로그인 실행(launchd)과 직접 실행이 겹치면 잠금을 못 잡은 쪽이 조용히 물러난다(exit 0 이라 KeepAlive 도 다시 안 띄운다).
        // launchd 로 뜬 인스턴스는 NSRunningApplication 목록에 안 보일 수 있어 파일 잠금으로 가린다.
        if !Self.acquireInstanceLock() { exit(0) }
        // 직접 실행했는데 로그인 항목이 올라가 있으면 launchd 쪽으로 넘긴다 — 그래야 죽었을 때 다시 켜진다.
        if LoginItem.handOffToLaunchdIfNeeded() { exit(0) }
        // 분류 기본값을 로그인 항목 설정(loginItemConfigured)보다 먼저 정한다 — 그 키로 예전 사용자를 가린다.
        _ = StorageSettings.loadCategories()
        // 꺼져 있을 때 누른 알림도 받으려면 실행이 끝나기 전에 붙여야 한다.
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        let monitor = MicMonitor()
        _monitor = StateObject(wrappedValue: monitor)
        _recorder = StateObject(wrappedValue: RecordingController(monitor: monitor))
        let delivery = Delivery()
        _delivery = StateObject(wrappedValue: delivery)
        _saveQueue = StateObject(wrappedValue: SaveQueue(delivery: delivery))
    }

    /// 프로세스가 살아 있는 동안 잠금을 쥔다(fd 는 일부러 닫지 않는다). 죽으면 커널이 풀어 준다.
    private static func acquireInstanceLock() -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/EarShot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appending(path: "instance.lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    /// 녹음 중 아이콘. SF Symbols 에 없으면 record.circle
    private static let recordingSymbol = NSImage(systemSymbolName: "ear.badge.waveform", accessibilityDescription: nil) != nil ? "ear.badge.waveform" : "record.circle"

    var body: some Scene {
        MenuBarExtra {
            // 메뉴 스타일이라 막대를 글자로 그린다.
            if recorder.isRecording {
                if recorder.capturesAppSound { Text("맥 소리 \(Self.levelBar(recorder.appLevel))") }
                Text("마이크 \(Self.levelBar(recorder.micLevel))")
            }
            if let current = recorder.current {
                Text("녹음 중: \(current.appName) \(recorder.elapsedText)")
            }
            // 멈춘 뒤 m4a 로 바꾸는 중. 2시간 회의면 40초쯤 걸린다.
            ForEach(conversion.items) { item in
                Text("변환 중: \(item.appName) \(Int((item.fraction * 100).rounded(.down)))%")
            }
            // 전역 단축키는 GlobalHotKey 가 잡는다. 여기 지정은 메뉴에 표시하려는 것.
            Button(recorder.isRecording ? String(localized: "녹음 멈추기") : String(localized: "녹음 시작")) { recorder.toggle() }
                .keyboardShortcut("r", modifiers: [.control, .option])
            Divider()
            if monitor.inputApps.isEmpty {
                Text("마이크 쓰는 앱 없음")
            } else {
                ForEach(monitor.inputApps) { app in
                    Text("\(app.isMeeting ? "● " : "")\(app.appName)  (\(app.appBundleID))")
                }
            }
            Divider()
            // 창을 "나중에"로 닫았거나 시작 때 남아 있던 녹음. 고르면 저장 창을 다시 띄운다.
            if !saveQueue.pending.isEmpty {
                Menu("분류 안 됨 \(saveQueue.pending.count)개") {
                    ForEach(saveQueue.pending, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { saveQueue.open(url) }
                    }
                }
            }
            // 고르면 그 폴더를 Finder 로 연다(손으로 옮기거나 지울 수 있게).
            if delivery.waitingCount > 0 {
                Button("보낼 대기 \(delivery.waitingCount)개") { NSWorkspace.shared.open(Delivery.outboxURL) }
            }
            if delivery.failedCount > 0 {
                Button("보내지 못한 파일 \(delivery.failedCount)개") { NSWorkspace.shared.open(Delivery.failedURL) }
            }
            Button("저장 위치…") { SettingsWindow.show() }
            Menu("녹음할 소리") {
                ForEach(CaptureSource.allCases, id: \.self) { source in
                    Toggle(source.title, isOn: Binding(get: { audioSettings.source == source }, set: { _ in audioSettings.setSource(source) }))
                }
                Divider()
                // 받아쓰기에서 누가 말했는지 가를 수 있게. 마이크만 녹음은 나눌 게 없다.
                Toggle("내 목소리·상대 좌우로 나누기", isOn: Binding(get: { audioSettings.splitChannels }, set: { audioSettings.setSplitChannels($0) }))
            }
            Menu("마이크") {
                Toggle("시스템 기본", isOn: Binding(get: { audioSettings.micUID == nil }, set: { _ in audioSettings.setMic(nil) }))
                Divider()
                ForEach(audioSettings.inputDevices) { device in
                    Toggle(device.name, isOn: Binding(get: { audioSettings.micUID == device.uid }, set: { _ in audioSettings.setMic(device.uid) }))
                }
                // 고른 장치가 빠져 있으면 시스템 기본으로 녹음한다.
                if audioSettings.isMicMissing {
                    Toggle("고른 마이크(연결 안 됨)", isOn: .constant(true))
                }
            }
            Divider()
            Toggle("로그인 시 실행", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
            Button("감지 로그 열기") { NSWorkspace.shared.open(MicMonitor.logURL) }
            // 정상 종료(0)라 LaunchAgent 가 다시 켜지 않는다.
            Button("종료") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: labelSymbol)
            // 변환 중이면 진행률, 아니면 분류 안 됨 개수(0이면 숫자 없음)
            if !recorder.isRecording, let percent = conversion.percent {
                Text("\(percent)%")
            } else if !saveQueue.pending.isEmpty {
                Text("\(saveQueue.pending.count)")
            }
        }
    }

    /// 0~1 → 10칸 막대
    private static func levelBar(_ level: Double) -> String {
        let filled = min(max(Int((level * Double(levelBarCount)).rounded()), 0), levelBarCount)
        return String(repeating: "▮", count: filled) + String(repeating: "▯", count: levelBarCount - filled)
    }

    private static let levelBarCount = 10

    private var labelSymbol: String {
        if recorder.isRecording { return Self.recordingSymbol }
        if !conversion.items.isEmpty { return "hourglass" }
        return monitor.inputApps.contains(where: \.isMeeting) ? "ear.fill" : "ear"
    }
}
