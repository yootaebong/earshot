import AVFoundation
import Combine
import CoreAudio
import UserNotifications

/// 메뉴·⌃⌥R 로 수동 녹음한다. 녹음할 소리 설정이 기본이면 입력 쓰는 회의 앱이 있을 때 "그 앱 소리 + 내 마이크",
/// 없으면 "시스템 전체 소리 + 내 마이크". "맥 전체"는 늘 전체, "마이크만"은 탭을 안 만든다. 멈추면 M4A 하나로 섞어 Pending 에 둔다.
/// 녹음 중 입출력 장치가 바뀌면 조각을 나눠 이어 녹음하고, 멈출 때 순서대로 이어 붙인다.
@MainActor
final class RecordingController: ObservableObject {
    /// 녹음 대상 이름과 시작 시각
    @Published private(set) var current: (appName: String, startedAt: Date)?
    /// 메뉴에 보일 "mm:ss". 1초마다 갱신
    @Published private(set) var elapsedText = ""
    /// 녹음 중 맥 소리·마이크 크기(0~1, -60dB 가 0). 0.25초마다 갱신
    @Published private(set) var appLevel: Double = 0
    @Published private(set) var micLevel: Double = 0
    /// 이번 녹음이 맥 소리를 받는지(마이크만이면 false)
    @Published private(set) var capturesAppSound = false

    /// 이보다 짧은 녹음은 버린다.
    nonisolated static let minimumDuration: TimeInterval = 30
    /// 시스템 전체를 녹음할 때 파일 이름의 앱 자리
    nonisolated static let globalName = String(localized: "전체", comment: "시스템 전체를 녹음할 때 파일 이름의 앱 자리")
    /// 마이크만 녹음할 때 파일 이름의 앱 자리
    nonisolated static let micOnlyName = String(localized: "마이크")
    /// 레벨 막대 갱신 간격과 0 으로 보는 크기
    private static let levelInterval: TimeInterval = 0.25
    private static let levelFloor: Float = -60
    /// 녹음 시작 뒤 이만큼 지나도 최대 크기가 이보다 작으면 무음 경고
    private static let silenceCheckDelay: TimeInterval = 15
    private static let silenceThreshold: Float = -80
    /// 장치 바뀜 알림이 입력·출력으로 겹쳐 오므로 이만큼 모아서 한 번만 조각을 나눈다.
    private static let deviceChangeDelay: TimeInterval = 0.5
    /// 새 조각 시작이 실패하면 이 간격으로 이만큼 다시 해 본다.
    private static let segmentRetryDelay: TimeInterval = 1
    private static let segmentRetryCount = 3
    /// 레코더가 쓰기에 실패해 조각을 나눠 달라고 할 때 오는 이유
    private static let writeFailureReason = "쓰기 실패"
    /// 이 시간 안에 쓰기 실패로 이만큼 나누게 되면(디스크 가득 등) 더 나누지 않고 녹음을 끝낸다.
    private static let writeFailureWindow: TimeInterval = 60
    private static let writeFailureLimit = 3

    nonisolated static let pendingURL: URL = supportDirectory("Pending")
    /// 녹음 중 조각(.caf)을 두는 곳. 녹음마다 하위 폴더 하나, 앱이 죽으면 다음 실행 때 복구한다.
    nonisolated static let recordingURL: URL = supportDirectory("Recording")

    nonisolated private static func supportDirectory(_ name: String) -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/EarShot/\(name)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 녹음 폴더의 session.json. 복구 때 파일 이름을 되살리는 데 쓴다.
    private struct SessionInfo: Codable {
        let name: String
        let startedAt: Date
    }

    /// 장치가 바뀔 때까지 이어지는 한 조각
    private struct Segment {
        let tap: AppAudioTap?
        let mic: MicRecorder?
        /// 이 조각에 쓰라고 한 마이크 장치. nil 이면 시스템 기본
        var micDeviceID: AudioDeviceID?

        var sources: [MixSource] {
            [tap.map { MixSource(url: $0.fileURL, hostTime: $0.firstHostTime.hostTime) },
             mic.map { MixSource(url: $0.fileURL, hostTime: $0.firstHostTime.hostTime) }].compactMap { $0 }
        }

        func stop() {
            tap?.stop()
            mic?.stop()
        }
    }

    private struct Session {
        /// nil 이면 시스템 전체 소리
        let app: MeetingApp?
        let source: CaptureSource
        let name: String
        let startedAt: Date
        let directory: URL
        let micGranted: Bool
        var finished: [Segment]
        var segment: Segment
        /// 지금까지 본 대상 앱 객체 전부(늘어남 판단용)
        var knownObjectIDs: Set<AudioObjectID>
        /// 무음 경고를 봤는지
        var silenceChecked = false
    }

    private let monitor: MicMonitor
    private var session: Session?
    private var isStarting = false
    private var rotateScheduled = false
    /// 나눌 이유. 0.5초 안에 여러 번 오면 첫 이유만 남긴다.
    private var rotateReason = ""
    /// 새 조각 시작 재시도 중이면 그 녹음 폴더. 그동안은 조각을 또 나누지 않는다.
    private var retryingDirectory: URL?
    /// 이번 녹음에서 쓰기 실패로 조각을 나눈 시각들(writeFailureWindow 안의 것만)
    private var writeFailureTimes: [Date] = []
    private var cancellable: AnyCancellable?
    private var micCancellable: AnyCancellable?
    private var timer: Timer?
    private var levelTimer: Timer?
    /// 조각이 바뀌어도 이어 쓰는 크기 측정값
    private let appMeter = LevelMeter()
    private let micMeter = LevelMeter()
    private var hotKey: GlobalHotKey?

    init(monitor: MicMonitor) {
        self.monitor = monitor
        Self.recoverLeftovers()
        cancellable = monitor.$apps.sink { [weak self] apps in
            Task { @MainActor in self?.checkTargetChange(apps) }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        hotKey = GlobalHotKey { [weak self] in self?.toggle() }
        // 시험용: `notifyutil` 대신 분산 알림 io.taebong.EarShot.toggle 로도 녹음을 켜고 끈다.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("io.taebong.EarShot.toggle"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle() }
        }
        if hotKey == nil { MicMonitor.log("오류 단축키 ⌃⌥R 등록 실패") }
        listenDeviceChanges()
        // 고른 마이크가 바뀌거나 꽂히고 빠지면 조각을 나눠 그 장치로 잇는다. @Published 는 바뀌기 전에 알리므로 Task 로 미룬다.
        let settings = AudioSettings.shared
        micCancellable = settings.$micUID.map { _ in () }.merge(with: settings.$inputDevices.map { _ in () }).sink { [weak self] in
            Task { @MainActor in self?.checkMicChange() }
        }
    }

    var isRecording: Bool { current != nil }

    /// 메뉴·단축키 토글
    func toggle() {
        if session != nil {
            finish()
            return
        }
        guard !isStarting else { return }
        isStarting = true
        let source = AudioSettings.shared.source
        let app = source == .meetingApp ? monitor.apps.first { $0.isMeeting && $0.isRunningInput } : nil
        Task { await start(app, source: source) }
    }

    /// 자동 녹음이 부른다. 시작한 녹음의 시작 시각, 이미 녹음 중·시작 중이거나 실패하면 nil.
    /// "회의 앱 소리"면 그 앱을, 아니면 설정대로 녹음한다. 시작하는 동안은 isStarting 이 ⌃⌥R 을 막는다.
    func startAutomatically(for app: MeetingApp) async -> Date? {
        guard session == nil, !isStarting else { return nil }
        isStarting = true
        let source = AudioSettings.shared.source
        await start(source == .meetingApp ? app : nil, source: source)
        return current?.startedAt
    }

    /// 녹음 중이면 멈춘다(자동 녹음 종료용 — toggle 과 달리 시작하지 않는다).
    func stop() {
        if session != nil { finish() }
    }

    private func tick() {
        if let current {
            let seconds = Int(Date().timeIntervalSince(current.startedAt))
            elapsedText = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
    }

    /// 탭은 조각 시작 때 객체로만 만든다. 녹음 중 대상 앱 객체가 늘면 새 객체까지 넣어 조각을 나눈다.
    private func checkTargetChange(_ apps: [MeetingApp]) {
        guard var session, let target = session.app,
              let app = apps.first(where: { $0.id == target.id }),
              !session.knownObjectIDs.isSuperset(of: app.objectIDs) else { return }
        let before = session.knownObjectIDs.count
        session.knownObjectIDs.formUnion(app.objectIDs)
        self.session = session
        MicMonitor.log("탭 대상 바뀜 \(app.appName) 객체 \(before)→\(session.knownObjectIDs.count)")
        scheduleRotate("탭 대상 바뀜")
    }

    /// 대상 앱의 지금 객체 목록. 앱이 목록에서 사라졌으면 시작 때 값. 전역 탭이면 nil.
    private func currentObjectIDs(of app: MeetingApp?) -> [AudioObjectID]? {
        guard let app else { return nil }
        return monitor.apps.first { $0.id == app.id }?.objectIDs ?? app.objectIDs
    }

    /// 레코더가 조각을 나눠 달라고 할 때 부르는 콜백. 레코더는 메인에서 부른다.
    private func restartHandler() -> (String) -> Void {
        { [weak self] reason in
            MainActor.assumeIsolated { self?.scheduleRotate(reason) }
        }
    }

    // MARK: - 레벨·무음 경고

    private func startLevelTimer() {
        levelTimer?.invalidate()
        let timer = Timer(timeInterval: Self.levelInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateLevels() }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        appLevel = 0
        micLevel = 0
    }

    private func updateLevels() {
        guard var session else { return }
        appLevel = Self.normalized(appMeter.takeRecent())
        micLevel = Self.normalized(micMeter.takeRecent())
        guard !session.silenceChecked, Date().timeIntervalSince(session.startedAt) >= Self.silenceCheckDelay else { return }
        session.silenceChecked = true
        self.session = session
        var silent: [String] = []
        if session.source != .micOnly, appMeter.peak < Self.silenceThreshold { silent.append("맥 소리") }
        if micMeter.peak < Self.silenceThreshold { silent.append("마이크") }
        guard !silent.isEmpty else { return }
        for side in silent { MicMonitor.log("경고 \(side) 무음 \(Int(Self.silenceCheckDelay))초") }
        let body: String
        if !silent.contains("마이크") { body = String(localized: "맥 소리가 안 들어와요 — 출력 장치·녹음 권한 확인") }
        else if session.segment.mic == nil { body = String(localized: "마이크를 못 열었어요 — 마이크 권한·장치 확인") }
        else { body = String(localized: "마이크 소리가 안 들어와요 — 장치·음소거 확인") }
        Self.notify(body)
    }

    /// dBFS → 0~1 (-60dB 이하 0, 0dB 1)
    private static func normalized(_ decibels: Float) -> Double {
        Double(min(max((decibels - levelFloor) / -levelFloor, 0), 1))
    }

    nonisolated private static func requestNotificationAccess() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { MicMonitor.log("오류 알림 권한 요청: \(error.localizedDescription)") }
            else if !granted { MicMonitor.log("알림 권한 없음 — 무음 경고는 로그에만 남는다") }
        }
    }

    nonisolated private static func notify(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "EarShot"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { MicMonitor.log("오류 알림 보내기: \(error.localizedDescription)") }
        }
    }

    // MARK: - 장치 바뀜

    /// 지금 조각의 마이크 장치와 설정이 가리키는 장치가 다르면 조각을 나눈다.
    private func checkMicChange() {
        guard let session, session.micGranted, AudioSettings.shared.micDeviceID != session.segment.micDeviceID else { return }
        scheduleRotate("마이크 바뀜")
    }

    private func listenDeviceChanges() {
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = CoreAudioProperty.address(selector)
            let isOutput = selector == kAudioHardwarePropertyDefaultOutputDevice
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    // 마이크만 녹음할 땐 출력 장치가 바뀌어도 나눌 게 없다.
                    if isOutput, self?.session?.source == .micOnly { return }
                    self?.scheduleRotate("장치 바뀜")
                }
            }
            if status != noErr { MicMonitor.log("오류 장치 감시 등록 \(status)") }
        }
    }

    private func scheduleRotate(_ reason: String) {
        guard session != nil, retryingDirectory == nil, !rotateScheduled else { return }
        rotateScheduled = true
        rotateReason = reason
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.deviceChangeDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rotateScheduled = false
                self.rotateSegment(reason: self.rotateReason)
            }
        }
    }

    /// 지금 조각을 닫고 같은 대상으로 새 조각을 시작한다.
    private func rotateSegment(reason: String) {
        guard var session, retryingDirectory == nil else { return }
        if reason == Self.writeFailureReason {
            let now = Date()
            writeFailureTimes = writeFailureTimes.filter { now.timeIntervalSince($0) < Self.writeFailureWindow } + [now]
            guard writeFailureTimes.count < Self.writeFailureLimit else {
                MicMonitor.log("오류 쓰기 실패 \(Int(Self.writeFailureWindow))초 안에 \(writeFailureTimes.count)번 → 멈춤 \(session.name)")
                finish()
                Self.notify(String(localized: "녹음 저장 실패 — 디스크 공간 확인"))
                return
            }
        }
        session.segment.stop()
        session.finished.append(session.segment)
        session.segment = Segment(tap: nil, mic: nil)
        self.session = session
        startNextSegment(reason: reason, attempt: 0)
    }

    /// 새 조각을 시작한다. 소리·마이크 둘 다 실패하면 1초 간격으로 다시 하고, 끝내 안 되면 녹음을 멈춘다.
    private func startNextSegment(reason: String, attempt: Int) {
        guard var session else { return }
        let index = session.finished.count
        let objectIDs = currentObjectIDs(of: session.app)
        if let next = startSegment(objectIDs: objectIDs, source: session.source, name: session.name, index: index,
                                   in: session.directory, micGranted: session.micGranted) {
            retryingDirectory = nil
            session.segment = next
            session.knownObjectIDs.formUnion(objectIDs ?? [])
            self.session = session
            MicMonitor.log("\(reason) → 이어 녹음 \(session.name) 조각=\(index + 1)" + (objectIDs.map { " 객체=\($0.count)" } ?? ""))
            return
        }
        guard attempt < Self.segmentRetryCount else {
            retryingDirectory = nil
            MicMonitor.log("조각 시작 실패 → 멈춤 \(session.name)")
            finish()
            return
        }
        retryingDirectory = session.directory
        MicMonitor.log("오류 조각 시작 실패 \(attempt + 1)/\(Self.segmentRetryCount) → \(Int(Self.segmentRetryDelay))초 뒤 다시")
        let directory = session.directory
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.segmentRetryDelay) { [weak self] in
            MainActor.assumeIsolated {
                // 그사이 멈췄거나 다른 녹음이 시작됐으면 그만둔다.
                guard let self, self.session?.directory == directory else { return }
                self.startNextSegment(reason: reason, attempt: attempt + 1)
            }
        }
    }

    // MARK: - 시작·종료

    /// app 이 nil 이면 시스템 전체 소리 + 마이크(마이크만이면 마이크만)
    private func start(_ app: MeetingApp?, source: CaptureSource) async {
        defer { isStarting = false }
        let name = source == .micOnly ? Self.micOnlyName : app?.appName ?? Self.globalName
        Self.requestNotificationAccess()
        let micGranted = await MicRecorder.requestAccess()
        if source != .micOnly {
            let captureGranted = await AudioCapturePermission.request()
            if !captureGranted { MicMonitor.log("오류 시스템 오디오 녹음 권한 없음 — 앱 소리가 무음으로 녹음된다") }
        }
        if !micGranted { MicMonitor.log("오류 마이크 권한 없음") }
        // 권한 창 기다린 시간이 길이·시작 시각에 들어가지 않게 권한 뒤에 잰다.
        let startedAt = Date()

        let directory = Self.recordingURL.appending(path: UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(SessionInfo(name: name, startedAt: startedAt)).write(to: directory.appending(path: "session.json"))
        } catch {
            MicMonitor.log("오류 녹음 폴더 만들기: \(error.localizedDescription)")
            return
        }

        appMeter.reset()
        micMeter.reset()
        guard let segment = startSegment(objectIDs: app?.objectIDs, source: source, name: name, index: 0,
                                         in: directory, micGranted: micGranted) else {
            try? FileManager.default.removeItem(at: directory)
            MicMonitor.log("녹음 시작 실패 \(name)")
            return
        }

        session = Session(app: app, source: source, name: name, startedAt: startedAt, directory: directory, micGranted: micGranted,
                          finished: [], segment: segment, knownObjectIDs: Set(app?.objectIDs ?? []))
        current = (name, startedAt)
        elapsedText = "00:00"
        capturesAppSound = source != .micOnly
        startLevelTimer()
        let target = source == .micOnly ? "마이크만" : app.map { "[\($0.appBundleID)] 객체=\($0.objectIDs.count)" } ?? "시스템 전체"
        MicMonitor.log("녹음 시작 \(name) \(target) 소리=\(segment.tap != nil) 마이크=\(segment.mic != nil)")
    }

    /// 소리 탭과 마이크로 조각 하나를 시작한다. 둘 다 실패하면 nil. objectIDs 가 nil 이면 시스템 전체 소리, 마이크만이면 탭 없음.
    private func startSegment(objectIDs: [AudioObjectID]?, source: CaptureSource, name: String, index: Int,
                              in directory: URL, micGranted: Bool) -> Segment? {
        let prefix = String(format: "%03d", index)
        let onRestart = restartHandler()
        var tap: AppAudioTap?
        if source != .micOnly {
            tap = AppAudioTap(fileURL: directory.appending(path: "\(prefix)-app.caf"), meter: appMeter, onRestart: onRestart)
            do {
                try tap?.start(objectIDs: objectIDs)
            } catch {
                tap = nil
                MicMonitor.log("오류 소리 녹음 시작 \(name): \(error.localizedDescription)")
            }
        }

        var mic: MicRecorder?
        let settings = AudioSettings.shared
        var deviceID = settings.micDeviceID
        if micGranted {
            if deviceID == nil, let uid = settings.micUID { MicMonitor.log("고른 마이크 없음 \(uid) → 시스템 기본") }
            mic = MicRecorder(fileURL: directory.appending(path: "\(prefix)-mic.caf"), meter: micMeter, onRestart: onRestart)
            do {
                try mic?.start(deviceID: deviceID)
            } catch {
                MicMonitor.log("오류 마이크 녹음 시작: \(error.localizedDescription)")
                // 고른 장치가 안 열리면 시스템 기본으로 한 번 더. 조각에는 nil 을 남겨 다음 장치 이벤트에서 고른 장치를 다시 시도한다.
                if deviceID != nil {
                    deviceID = nil
                    // 실패한 인스턴스는 AUHAL 에 고른 장치가 남아 있을 수 있어 새로 만든다.
                    mic = MicRecorder(fileURL: directory.appending(path: "\(prefix)-mic.caf"), meter: micMeter, onRestart: onRestart)
                    do {
                        try mic?.start(deviceID: nil)
                        MicMonitor.log("고른 마이크 실패 → 시스템 기본")
                    } catch {
                        mic = nil
                        MicMonitor.log("오류 마이크 녹음 시작(시스템 기본): \(error.localizedDescription)")
                    }
                } else {
                    mic = nil
                }
            }
        }
        guard tap != nil || mic != nil else { return nil }
        return Segment(tap: tap, mic: mic, micDeviceID: deviceID)
    }

    private func finish() {
        guard let session else { return }
        self.session = nil
        retryingDirectory = nil
        writeFailureTimes = []
        current = nil
        elapsedText = ""
        capturesAppSound = false
        stopLevelTimer()

        // stop 은 쓰기 큐에서 파일을 닫은 뒤 돌아오므로, 그 뒤에 시작하는 mix 는 닫힌 파일만 읽는다.
        session.segment.stop()
        let segments = (session.finished + [session.segment]).map(\.sources).filter { !$0.isEmpty }
        MicMonitor.log("녹음 멈춤 \(session.name) \(Int(Date().timeIntervalSince(session.startedAt)))초 조각=\(segments.count)")

        let directory = session.directory
        let name = session.name, startedAt = session.startedAt
        Task.detached {
            await Self.mix(segments: segments, appName: name, startedAt: startedAt, removing: directory, prompt: true)
        }
    }

    /// Pending 쓰기(이름 정하기 + json + 옮기기)는 이 큐 하나에서만 한다 — 같은 분 녹음 둘이 같은 이름을 고르지 않게.
    nonisolated private static let pendingQueue = DispatchQueue(label: "io.taebong.EarShot.pending")

    /// 내보낸 mixed 를 Pending 에 넣는다. 이름은 여기서 정하고, 메타를 먼저 쓴 뒤 m4a 를 옮긴다.
    nonisolated private static func moveToPending(_ mixed: URL, meta: RecordingMeta) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            pendingQueue.async {
                let output = outputURL(appName: meta.appName, startedAt: meta.startedAt)
                let json = RecordingMeta.jsonURL(for: output)
                do {
                    try meta.write(to: json)
                    do {
                        try FileManager.default.moveItem(at: mixed, to: output)
                    } catch {
                        try? FileManager.default.removeItem(at: json)
                        throw error
                    }
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func outputURL(appName: String, startedAt: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let safeName = appName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = "\(formatter.string(from: startedAt))-\(safeName)"
        // 같은 분에 녹음이 둘이면 덮어쓰지 않도록 번호를 붙인다.
        var url = pendingURL.appending(path: "\(base).m4a")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path)
                || FileManager.default.fileExists(atPath: RecordingMeta.jsonURL(for: url).path) {
            url = pendingURL.appending(path: "\(base)-\(number).m4a")
            number += 1
        }
        return url
    }

    // MARK: - 복구

    /// 지난 실행이 녹음 중 죽어 남긴 조각들을 Pending 에 m4a 로 살린다.
    private static func recoverLeftovers() {
        let fm = FileManager.default
        let directories = (try? fm.contentsOfDirectory(at: recordingURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for directory in directories where directory.hasDirectoryPath {
            let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            // 파일 이름 앞 세 자리가 조각 번호
            let grouped = Dictionary(grouping: files.filter { $0.pathExtension == "caf" }) { $0.lastPathComponent.prefix(3) }
            let segments = grouped.keys.sorted().map { key in
                grouped[key, default: []].sorted { $0.lastPathComponent < $1.lastPathComponent }.map { MixSource(url: $0, hostTime: nil) }
            }
            guard !segments.isEmpty else {
                try? fm.removeItem(at: directory)
                continue
            }
            let info = (try? Data(contentsOf: directory.appending(path: "session.json")))
                .flatMap { try? JSONDecoder().decode(SessionInfo.self, from: $0) }
            let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            let name = info?.name ?? String(localized: "복구"), startedAt = info?.startedAt ?? modified
            MicMonitor.log("지난 녹음 복구 \(name) \(startedAt.formatted(.iso8601)) 조각=\(segments.count)")
            // 시작 때 살린 것은 창을 띄우지 않고 분류 안 됨 숫자로만 보인다.
            Task.detached {
                await mix(segments: segments, appName: name, startedAt: startedAt, removing: directory, prompt: false)
            }
        }
    }

    // MARK: - 섞기

    /// 조각들을 순서대로 이어 붙이고, 조각 안에서는 소리·마이크를 첫 버퍼 시각 차이만큼 어긋나게 놓아 M4A 로 내보낸다.
    /// 성공하거나 30초 미만이라 버리면 녹음 폴더를 지운다. 트랙을 못 읽은 파일은 로그만 남기고 건너뛴다.
    /// 읽은 트랙이 하나도 없으면 Failed 로 옮긴다(다음 실행 때 끝없이 다시 복구하지 않게). 그 밖의 실패는 폴더를 남긴다.
    /// 녹음 폴더 안에 내보낸 뒤 메타(.json)를 먼저 쓰고 m4a 를 Pending 으로 옮긴다 — Pending 의 m4a 는 늘 다 쓴 파일이다.
    nonisolated private static func mix(segments: [[MixSource]], appName: String, startedAt: Date,
                                        removing directory: URL, prompt: Bool) async {
        // 긴 회의는 내보내기에 수십 초 걸린다 — 그동안 메뉴에 진행률을 보인다.
        let key = directory.lastPathComponent
        await ConversionStatus.shared.begin(key, appName: appName)
        defer { Task { @MainActor in ConversionStatus.shared.end(key) } }
        do {
            let composition = AVMutableComposition()
            var cursor = CMTime.zero
            var unreadable: [String] = []
            var readCount = 0
            // 좌우로 나눌 때 쓴다 — 왼쪽 마이크(나), 오른쪽 맥 소리(상대)
            var micTracks: [AVAssetTrack] = []
            var appTracks: [AVAssetTrack] = []
            for sources in segments {
                let earliest = sources.compactMap(\.hostTime).min()
                var segmentEnd = cursor
                for source in sources {
                    let asset = AVURLAsset(url: source.url)
                    guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
                        unreadable.append(source.url.lastPathComponent)
                        MicMonitor.log("오류 트랙 못 읽음 \(source.url.lastPathComponent) → 건너뜀")
                        continue
                    }
                    // 길이 읽기·붙이기에서 던지는 손상 파일도 건너뛴다(던지면 폴더가 남아 실행마다 다시 실패한다).
                    let range: CMTimeRange
                    do { range = try await track.load(.timeRange) } catch {
                        unreadable.append(source.url.lastPathComponent)
                        MicMonitor.log("오류 트랙 길이 못 읽음 \(source.url.lastPathComponent) → 건너뜀")
                        continue
                    }
                    guard range.duration.seconds > 0,
                          let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                    var offset = 0.0
                    if let earliest, let hostTime = source.hostTime {
                        offset = AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: earliest)
                    }
                    let at = cursor + CMTime(seconds: offset, preferredTimescale: 48_000)
                    do { try target.insertTimeRange(range, of: track, at: at) } catch {
                        composition.removeTrack(target)
                        unreadable.append(source.url.lastPathComponent)
                        MicMonitor.log("오류 트랙 붙이기 실패 \(source.url.lastPathComponent) → 건너뜀")
                        continue
                    }
                    readCount += 1
                    if source.isMic { micTracks.append(target) } else { appTracks.append(target) }
                    segmentEnd = max(segmentEnd, at + range.duration)
                }
                cursor = segmentEnd
            }
            if readCount == 0, !unreadable.isEmpty {
                let failed = supportDirectory("Failed").appending(path: directory.lastPathComponent)
                do {
                    try FileManager.default.moveItem(at: directory, to: failed)
                    MicMonitor.log("오류 저장 \(appName) 읽을 트랙 없음 \(unreadable.joined(separator: ",")) → \(failed.path)")
                } catch {
                    MicMonitor.log("오류 저장 \(appName) 읽을 트랙 없음, Failed 옮기기 실패 \(error.localizedDescription)")
                }
                return
            }

            let duration = composition.duration.seconds
            guard duration >= minimumDuration else {
                MicMonitor.log("버림 \(appName) \(Int(duration))초 < \(Int(minimumDuration))초")
                try? FileManager.default.removeItem(at: directory)
                return
            }

            let mixed = directory.appending(path: "mixed.m4a")
            try? FileManager.default.removeItem(at: mixed)
            if AudioSettings.splitsChannels, !micTracks.isEmpty, !appTracks.isEmpty {
                try await renderSplit(composition, left: micTracks, right: appTracks, to: mixed, key: key)
            } else {
                guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
                    throw RecordingError("내보내기 세션 생성 실패")
                }
                let watcher = watchProgress(of: export, key: key)
                defer { watcher.cancel() }
                if #available(macOS 15, *) {
                    try await export.export(to: mixed, as: .m4a)
                } else {
                    export.outputURL = mixed
                    export.outputFileType = .m4a
                    await export.export()
                    if let error = export.error { throw error }
                }
            }
            let meta = RecordingMeta(startedAt: startedAt, appName: appName, duration: Int(duration.rounded()))
            let output = try await moveToPending(mixed, meta: meta)
            MicMonitor.log("저장 \(output.path) \(Int(duration))초")
            try? FileManager.default.removeItem(at: directory)
            await MainActor.run {
                NotificationCenter.default.post(name: .recordingSaved, object: output, userInfo: ["prompt": prompt])
            }
        } catch {
            MicMonitor.log("오류 저장 \(appName) \(startedAt.formatted(.iso8601)): \(error.localizedDescription)")
        }
    }
}

extension RecordingController {
    /// 왼쪽에 left 트랙들, 오른쪽에 right 트랙들을 각각 모노로 섞어 스테레오 AAC m4a 로 쓴다.
    /// 두 쪽을 1초씩 번갈아 읽어 메모리를 일정하게 둔다. 먼저 끝난 쪽은 무음으로 채운다.
    nonisolated fileprivate static func renderSplit(_ asset: AVAsset, left: [AVAssetTrack], right: [AVAssetTrack],
                                                    to url: URL, key: String) async throws {
        let rate = 48_000.0
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let reader = try AVAssetReader(asset: asset)
        let outputs = [left, right].map { AVAssetReaderAudioMixOutput(audioTracks: $0, audioSettings: pcm) }
        for output in outputs {
            guard reader.canAdd(output) else { throw RecordingError("좌우 나누기 읽기 출력 추가 실패") }
            reader.add(output)
        }
        guard reader.startReading() else { throw reader.error ?? RecordingError("좌우 나누기 읽기 시작 실패") }
        defer { if reader.status == .reading { reader.cancelReading() } }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            throw RecordingError("좌우 나누기 형식 생성 실패")
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)

        let chunk = Int(rate)
        let total = max(asset.duration.seconds * rate, 1)
        var queues: [[Float]] = [[], []]
        /// 쪽마다 지금까지 큐에 넣은 샘플 수 = 다음 샘플의 위치
        var positions = [0, 0]
        var finished = [false, false]
        var written = 0
        var reported = -1
        while true {
            for side in 0..<2 where !finished[side] {
                while queues[side].count < chunk {
                    guard let buffer = outputs[side].copyNextSampleBuffer() else {
                        finished[side] = true
                        break
                    }
                    try appendSamples(buffer, rate: rate, to: &queues[side], position: &positions[side])
                }
            }
            // 아직 읽는 쪽이 있으면 그쪽이 가진 만큼만, 다 끝났으면 남은 것 전부
            let open = (0..<2).filter { !finished[$0] }
            let count = open.isEmpty ? queues.map(\.count).max() ?? 0 : open.map { queues[$0].count }.min() ?? 0
            if count == 0 {
                if open.isEmpty { break }
                continue
            }
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channels = out.floatChannelData else { throw RecordingError("좌우 나누기 버퍼 생성 실패") }
            out.frameLength = AVAudioFrameCount(count)
            for side in 0..<2 {
                let available = min(count, queues[side].count)
                if available > 0 {
                    queues[side].withUnsafeBufferPointer { source in
                        channels[side].update(from: source.baseAddress!, count: available)
                    }
                    queues[side].removeFirst(available)
                }
                if available < count { (channels[side] + available).update(repeating: 0, count: count - available) }
            }
            try file.write(from: out)
            written += count
            let percent = Int(Double(written) / total * 100)
            if percent != reported {
                reported = percent
                await ConversionStatus.shared.update(key, fraction: Double(written) / total)
            }
        }
        if reader.status == .failed { throw reader.error ?? RecordingError("좌우 나누기 읽기 실패") }
    }

    /// 모노 Float32 인터리브 샘플 버퍼의 값을 queue 끝에 붙인다. 좌우가 어긋나지 않게 버퍼 시각(PTS)에 맞춘다 —
    /// 빈 구간을 건너뛰어 시각이 앞서 있으면 그만큼 0 을 먼저 넣고, 겹치면 겹친 앞부분을 버린다.
    nonisolated private static func appendSamples(_ sampleBuffer: CMSampleBuffer, rate: Double,
                                                  to queue: inout [Float], position: inout Int) throws {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mSampleRate == rate, asbd.mChannelsPerFrame == 1, asbd.mBitsPerChannel == 32,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw RecordingError("좌우 나누기 형식이 다름")
        }
        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &list, bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr else { throw RecordingError("좌우 나누기 샘플 읽기 실패 \(status)") }
        try withExtendedLifetime(blockBuffer) {
            guard let data = list.mBuffers.mData else { throw RecordingError("좌우 나누기 샘플 없음") }
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                              count: Int(list.mBuffers.mDataByteSize) / MemoryLayout<Float>.size)
            var skip = 0
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if pts.isNumeric {
                let start = Int((pts.seconds * rate).rounded())
                if start > position {
                    queue.append(contentsOf: repeatElement(0, count: start - position))
                    position = start
                } else if start < position {
                    skip = min(position - start, samples.count)
                }
            }
            queue.append(contentsOf: samples.dropFirst(skip))
            position += samples.count - skip
        }
    }

    /// 내보내기 진행률을 0.5초마다 ConversionStatus 에 옮긴다. 끝나면 cancel 한다.
    nonisolated fileprivate static func watchProgress(of export: AVAssetExportSession, key: String) -> Task<Void, Never> {
        Task {
            if #available(macOS 15, *) {
                for await state in export.states(updateInterval: 0.5) {
                    if case .exporting(let progress) = state {
                        await ConversionStatus.shared.update(key, fraction: progress.fractionCompleted)
                    }
                }
            } else {
                while !Task.isCancelled {
                    await ConversionStatus.shared.update(key, fraction: Double(export.progress))
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }
}

/// 녹음을 m4a 로 바꾸는 중인 것들. 메뉴와 메뉴 막대 아이콘이 본다.
@MainActor
final class ConversionStatus: ObservableObject {
    static let shared = ConversionStatus()

    struct Item: Identifiable {
        let id: String
        let appName: String
        /// 0~1. 내보내기 전(트랙 읽는 중)은 0
        var fraction: Double
    }

    /// 시작 순서대로
    @Published private(set) var items: [Item] = []

    /// 가장 먼저 시작한 것의 백분율. 없으면 nil
    var percent: Int? { items.first.map { Int(($0.fraction * 100).rounded(.down)) } }

    func begin(_ key: String, appName: String) {
        guard !items.contains(where: { $0.id == key }) else { return }
        items.append(Item(id: key, appName: appName, fraction: 0))
    }

    func update(_ key: String, fraction: Double) {
        guard let index = items.firstIndex(where: { $0.id == key }) else { return }
        let clamped = min(max(fraction, 0), 1)
        // 1% 단위로만 다시 그린다.
        guard Int(clamped * 100) != Int(items[index].fraction * 100) else { return }
        items[index].fraction = clamped
    }

    func end(_ key: String) {
        items.removeAll { $0.id == key }
    }
}

/// Pending 의 m4a 옆에 두는 같은 이름 .json. 시각은 ISO8601, 길이는 초.
struct RecordingMeta: Codable {
    let startedAt: Date
    let appName: String
    let duration: Int

    static func jsonURL(for m4a: URL) -> URL {
        m4a.deletingPathExtension().appendingPathExtension("json")
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// 메타가 없거나 깨졌으면(이 기능 전 녹음) 파일 이름 "yyyy-MM-dd-HHmm-<앱>[-N]" 에서 되살린다. 길이는 0.
    static func load(for m4a: URL) -> RecordingMeta {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: jsonURL(for: m4a)), let meta = try? decoder.decode(RecordingMeta.self, from: data) {
            return meta
        }
        let base = m4a.deletingPathExtension().lastPathComponent
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let stamp = String(base.prefix(15))
        let modified = (try? m4a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        var app = base.count > 16 ? String(base.dropFirst(16)) : String(localized: "알 수 없음")
        if let range = app.range(of: #"-\d+$"#, options: .regularExpression) { app.removeSubrange(range) }
        return RecordingMeta(startedAt: formatter.date(from: stamp) ?? modified, appName: app, duration: 0)
    }
}

extension Notification.Name {
    /// Pending 에 m4a 하나가 생김. object 는 그 URL, userInfo["prompt"] 는 저장 창을 띄울지
    static let recordingSaved = Notification.Name("EarShot.recordingSaved")
}

/// 섞을 .caf 하나와 그 첫 버퍼 호스트 시각(복구 때는 없음)
struct MixSource: Sendable {
    let url: URL
    let hostTime: UInt64?

    /// 마이크 조각인지(파일 이름 "NNN-mic.caf"). 아니면 맥 소리("NNN-app.caf")
    var isMic: Bool { url.lastPathComponent.hasSuffix("-mic.caf") }
}
