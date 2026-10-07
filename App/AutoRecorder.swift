import Combine
import Foundation
import UserNotifications

/// 자동 녹음에서 고를 수 있는 앱. id 는 설정에 저장하는 키라 바꾸지 않는다.
struct AutoRecordApp: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let bundleIDs: Set<String>

    static let all: [AutoRecordApp] = [
        AutoRecordApp(id: "zoom", name: "Zoom", bundleIDs: ["us.zoom.xos"]),
        AutoRecordApp(id: "slack", name: "Slack", bundleIDs: ["com.tinyspeck.slackmacgap"]),
        AutoRecordApp(id: "teams", name: "Microsoft Teams", bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"]),
        AutoRecordApp(id: "webex", name: "Webex", bundleIDs: ["Cisco-Systems.Spark"]),
        AutoRecordApp(id: "chrome", name: "Google Chrome", bundleIDs: ["com.google.Chrome"]),
        AutoRecordApp(id: "safari", name: "Safari", bundleIDs: ["com.apple.Safari"]),
        AutoRecordApp(id: "arc", name: "Arc", bundleIDs: ["company.thebrowser.Browser"]),
        AutoRecordApp(id: "edge", name: "Microsoft Edge", bundleIDs: ["com.microsoft.edgemac"]),
    ]

    /// 브라우저는 웹사이트 음성 검색 같은 것에도 마이크를 잡아서 기본에서 뺀다.
    static let defaultIDs: Set<String> = ["zoom", "slack", "teams", "webex"]
}

/// 자동 녹음 설정. 새로 설치하면 꺼짐 — 녹음 동의를 받기 전에 저절로 녹음되지 않게.
@MainActor
final class AutoRecordSettings: ObservableObject {
    static let shared = AutoRecordSettings()

    private static let enabledKey = "autoRecordEnabled"
    private static let appsKey = "autoRecordApps"

    @Published private(set) var isEnabled: Bool
    /// AutoRecordApp.id
    @Published private(set) var appIDs: Set<String>

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        appIDs = (UserDefaults.standard.array(forKey: Self.appsKey) as? [String]).map(Set.init) ?? AutoRecordApp.defaultIDs
    }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        isEnabled = on
        MicMonitor.log("자동 녹음 → \(on)")
    }

    func setApp(_ id: String, on: Bool) {
        var ids = appIDs
        if on { ids.insert(id) } else { ids.remove(id) }
        guard ids != appIDs else { return }
        UserDefaults.standard.set(ids.sorted(), forKey: Self.appsKey)
        appIDs = ids
        MicMonitor.log("자동 녹음 대상 → \(ids.sorted().joined(separator: ","))")
    }

    func isTarget(_ app: MeetingApp) -> Bool {
        if AutoRecordApp.all.contains(where: { appIDs.contains($0.id) && $0.bundleIDs.contains(app.appBundleID) }) { return true }
        // 실측용 EARSHOT_TEST_APP 도 대상으로 친다.
        guard let testApp = MeetingApp.testApp else { return false }
        return testApp == app.appBundleID || testApp == (app.id as NSString).lastPathComponent
    }
}

/// 대상 앱이 마이크를 startDelay 넘게 계속 쓰면 녹음을 시작하고, 그 앱이 마이크를 stopDelay 넘게 놓으면 멈춘다.
/// 손으로 시작한 녹음은 건드리지 않는다. 자동 녹음을 손으로 멈추면 그 앱이 마이크를 놓을 때까지 다시 시작하지 않는다.
@MainActor
final class AutoRecorder: ObservableObject {
    enum Status: Equatable {
        case off
        case waiting
        /// 감지됨, 곧 시작
        case detected(String)
        case recording(String)
        /// 손으로 멈춰 이번 회의는 쉼
        case skipped(String)
        /// 손으로 녹음 중이라 쉼
        case manual
    }

    /// 슬랙 허들은 시작할 때 1~2초 켜졌다 꺼졌다를 한 번 한다(detect.log 10-06·10-07).
    static let startDelay: TimeInterval = 5
    static let stopDelay: TimeInterval = 10
    @Published private(set) var status: Status = .off

    private let monitor: MicMonitor
    private let recorder: RecordingController
    private let settings = AutoRecordSettings.shared
    /// 대상 앱 id → 마이크를 계속 쓰기 시작한 시각
    private var onSince: [String: Date] = [:]
    /// 자동으로 시작한 녹음(시작 시각으로 내 녹음인지 가린다)
    private var active: (app: MeetingApp, startedAt: Date)?
    /// 시작을 부탁하고 결과를 기다리는 중(권한 창이 떠 있을 수 있다)
    private var starting: MeetingApp?
    private var offSince: Date?
    /// 손으로 멈춘 때 마이크를 쓰던 대상 앱 id → 마이크를 놓은 시각(nil 이면 아직 씀). stopDelay 넘게 놓으면 지운다.
    private var skipped: [String: Date?] = [:]
    /// 직전 틱에 직접(손으로 시작한) 녹음 중이었는지
    private var sawManual = false
    private var timer: Timer?

    init(monitor: MicMonitor, recorder: RecordingController) {
        self.monitor = monitor
        self.recorder = recorder
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func evaluate() {
        let now = Date()
        let inputApps = monitor.inputApps
        let onIDs = Set(inputApps.map(\.id))
        updateSkipped(onIDs: onIDs, now: now)

        if let starting {
            setStatus(.detected(starting.appName))
            return
        }
        if let active {
            evaluateActive(active, onIDs: onIDs, now: now)
            return
        }
        if recorder.isRecording {
            onSince = [:]
            sawManual = true
            setStatus(settings.isEnabled ? .manual : .off)
            return
        }
        // 직접 녹음을 회의 중에 손으로 멈췄으면 그 회의도 다시 자동 녹음하지 않는다.
        if sawManual {
            sawManual = false
            skipTargets(in: inputApps)
        }
        guard settings.isEnabled else {
            onSince = [:]
            setStatus(.off)
            return
        }

        let candidates = inputApps.filter { settings.isTarget($0) && skipped[$0.id] == nil }
        onSince = onSince.filter { id, _ in candidates.contains { $0.id == id } }
        for app in candidates where onSince[app.id] == nil { onSince[app.id] = now }

        if let app = candidates.first(where: { now.timeIntervalSince(onSince[$0.id] ?? now) >= Self.startDelay }) {
            begin(app)
        } else if let app = candidates.first {
            setStatus(.detected(app.appName))
        } else if let app = inputApps.first(where: { skipped[$0.id] != nil }) {
            setStatus(.skipped(app.appName))
        } else {
            setStatus(.waiting)
        }
    }

    /// 시작을 부탁하고 결과를 받는다. 권한 창을 기다리는 동안에도 다른 시작은 막힌다(recorder.isStarting).
    private func begin(_ app: MeetingApp) {
        starting = app
        onSince = [:]
        setStatus(.detected(app.appName))
        Task {
            let startedAt = await recorder.startAutomatically(for: app)
            starting = nil
            guard let startedAt else {
                MicMonitor.log("자동 녹음 시작 실패 \(app.appName) → 이번 회의는 쉼")
                skipped[app.id] = .some(nil)
                return
            }
            active = (app, startedAt)
            offSince = nil
            MicMonitor.log("자동 녹음 시작 \(app.appName)")
            Self.notify(String(localized: "자동 녹음 시작 — \(app.appName) · ⌃⌥R 로 멈춤"))
            setStatus(.recording(app.appName))
        }
    }

    private func evaluateActive(_ active: (app: MeetingApp, startedAt: Date), onIDs: Set<String>, now: Date) {
        let app = active.app
        // 손으로 멈췄거나(다시 손으로 시작했어도) 이제 내 녹음이 아니다.
        guard recorder.current?.startedAt == active.startedAt else {
            MicMonitor.log("자동 녹음 손으로 멈춤 \(app.appName) → 마이크를 놓을 때까지 쉼")
            skipTargets(in: monitor.inputApps)
            self.active = nil
            evaluate()
            return
        }
        if onIDs.contains(app.id) {
            offSince = nil
            setStatus(.recording(app.appName))
            return
        }
        let since = offSince ?? now
        offSince = since
        guard now.timeIntervalSince(since) >= Self.stopDelay else { return }
        MicMonitor.log("자동 녹음 멈춤 \(app.appName) — 마이크 놓은 지 \(Int(Self.stopDelay))초")
        self.active = nil
        offSince = nil
        recorder.stop()
        setStatus(settings.isEnabled ? .waiting : .off)
    }

    /// 지금 마이크를 쓰는 대상 앱 전부를 이번 회의 동안 쉰다.
    private func skipTargets(in apps: [MeetingApp]) {
        for app in apps where settings.isTarget(app) { skipped[app.id] = .some(nil) }
    }

    /// 쉬는 앱이 마이크를 stopDelay 넘게 놓으면 다음 회의로 보고 지운다(장치 전환 같은 짧은 끊김은 넘긴다).
    private func updateSkipped(onIDs: Set<String>, now: Date) {
        for (id, offAt) in skipped {
            if onIDs.contains(id) {
                skipped[id] = .some(nil)
            } else if let offAt {
                if now.timeIntervalSince(offAt) >= Self.stopDelay { skipped[id] = nil }
            } else {
                skipped[id] = .some(now)
            }
        }
    }

    private func setStatus(_ status: Status) {
        if status != self.status { self.status = status }
    }

    /// 메뉴 맨 위 한 줄. 꺼져 있으면 nil
    var statusText: String? {
        switch status {
        case .off: nil
        case .waiting: String(localized: "자동 녹음 대기 — 감지된 회의 앱 없음")
        case .detected(let name): String(localized: "\(name) 감지 — 곧 자동 녹음")
        case .recording(let name): String(localized: "자동 녹음 중: \(name)")
        case .skipped(let name): String(localized: "\(name) — 이번 회의는 자동 녹음 안 함")
        case .manual: String(localized: "직접 녹음 중 — 자동 녹음 쉼")
        }
    }

    private static func notify(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "EarShot"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { MicMonitor.log("오류 알림 보내기: \(error.localizedDescription)") }
        }
    }
}
