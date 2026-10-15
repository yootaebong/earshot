import AppKit
import Combine

/// 메뉴 막대 아이콘과 메뉴. SwiftUI MenuBarExtra 는 값이 하나만 바뀌어도 하위 메뉴 항목까지 다시 설정해서
/// 녹음 중(0.25초마다 소리 크기 갱신)에는 하위 메뉴가 안 열렸다. 그래서 AppKit 으로 그린다 —
/// 메뉴는 열 때 새로 만들고, 열려 있는 동안 소리 크기·경과 시간·변환 % 는 그 줄 글자만 고친다.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let monitor: MicMonitor
    private let recorder: RecordingController
    private let loginItem: LoginItem
    private let delivery: Delivery
    private let saveQueue: SaveQueue
    private let autoRecorder: AutoRecorder
    private let audioSettings = AudioSettings.shared
    private let autoSettings = AutoRecordSettings.shared
    private let conversion = ConversionStatus.shared
    private let updates = UpdateChecker()

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var isOpen = false
    /// 열려 있는 동안 글자만 고칠 줄
    private var appLevelItem: NSMenuItem?
    private var micLevelItem: NSMenuItem?
    private var elapsedItem: NSMenuItem?
    private var conversionItems: [String: NSMenuItem] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var structureDirty = false
    /// 마지막으로 만든 메뉴의 구조(줄·체크). 같으면 다시 만들지 않는다 — 다시 만들면 열린 하위 메뉴가 닫힌다.
    private var builtStructure: [String] = []
    private var labelSymbol: String?
    private var liveDirty = false

    /// 녹음 중 아이콘. SF Symbols 에 없으면 record.circle
    private static let recordingSymbol = NSImage(systemSymbolName: "ear.badge.waveform", accessibilityDescription: nil) != nil ? "ear.badge.waveform" : "record.circle"
    private static let levelBarCount = 10

    init(monitor: MicMonitor, recorder: RecordingController, loginItem: LoginItem, delivery: Delivery, saveQueue: SaveQueue, autoRecorder: AutoRecorder) {
        self.monitor = monitor
        self.recorder = recorder
        self.loginItem = loginItem
        self.delivery = delivery
        self.saveQueue = saveQueue
        self.autoRecorder = autoRecorder
        super.init()
    }

    /// 실행이 끝난 뒤 부른다.
    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item

        // objectWillChange 는 바뀌기 전에 오므로 다음 차례에 읽는다. 메뉴가 열려 있으면 런루프가 이벤트 추적 모드라
        // RunLoop.main(기본 모드)으로 미루면 닫을 때까지 안 돈다 — DispatchQueue.main 은 그 모드에서도 돈다.
        let structural: [AnyPublisher<Void, Never>] = [
            monitor.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            recorder.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            loginItem.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            delivery.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            saveQueue.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            autoRecorder.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            audioSettings.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            autoSettings.objectWillChange.map { _ in }.eraseToAnyPublisher(),
            updates.objectWillChange.map { _ in }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(structural)
            .sink { [weak self] in self?.schedule(structure: true) }
            .store(in: &cancellables)
        Publishers.Merge(recorder.live.objectWillChange.map { _ in }, conversion.objectWillChange.map { _ in })
            .sink { [weak self] in self?.schedule(structure: false) }
            .store(in: &cancellables)
        updateLabel()
        updates.start()
    }

    // MARK: - 갱신

    private func schedule(structure: Bool) {
        let pending = structureDirty || liveDirty
        if structure { structureDirty = true } else { liveDirty = true }
        guard !pending else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        let structure = structureDirty
        structureDirty = false
        liveDirty = false
        updateLabel()
        guard isOpen else { return }
        // 신호는 값이 같아도 온다(보낼 대기 개수는 1분마다 다시 넣는다). 보이는 구조가 바뀔 때만 다시 만든다.
        if structure && currentStructure != builtStructure || Set(conversion.items.map(\.id)) != Set(conversionItems.keys) {
            rebuild()
        } else {
            updateLiveTitles()
        }
    }

    private func updateLabel() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        if recorder.isRecording {
            symbol = Self.recordingSymbol
        } else if !conversion.items.isEmpty {
            symbol = "hourglass"
        } else {
            symbol = monitor.inputApps.contains(where: \.isMeeting) ? "ear.fill" : "ear"
        }
        if labelSymbol != symbol {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "EarShot")
            image?.isTemplate = true
            button.image = image
            labelSymbol = symbol
        }
        // 변환 중이면 진행률, 아니면 분류 안 됨 개수(0이면 숫자 없음)
        let title: String
        if !recorder.isRecording, let percent = conversion.percent {
            title = "\(percent)%"
        } else if !saveQueue.pending.isEmpty {
            title = "\(saveQueue.pending.count)"
        } else {
            title = ""
        }
        if button.title != title { button.title = title }
    }

    private func updateLiveTitles() {
        appLevelItem?.title = appLevelTitle
        micLevelItem?.title = micLevelTitle
        elapsedItem?.title = elapsedTitle
        for item in conversion.items {
            conversionItems[item.id]?.title = Self.conversionTitle(item)
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === self.menu { isOpen = true }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { isOpen = false }
    }

    // MARK: - 메뉴 만들기

    /// 메뉴에 보이는 줄과 체크(자주 바뀌는 글자는 뺀다)
    private var currentStructure: [String] {
        var parts = [
            autoRecorder.statusText ?? "",
            updates.available?.version ?? "",
            "\(recorder.current?.appName ?? "-") \(recorder.isRecording) \(recorder.capturesAppSound)",
            "\(saveQueue.pending) \(delivery.waitingCount) \(delivery.failedCount) \(loginItem.isEnabled)",
            "\(autoSettings.isEnabled) \(autoSettings.appIDs.sorted())",
            "\(audioSettings.source) \(audioSettings.splitChannels) \(audioSettings.micUID ?? "-") \(audioSettings.isMicMissing)",
        ]
        parts += audioSettings.inputDevices.map { "\($0.uid) \($0.name)" }
        parts += monitor.inputApps.map { "\($0.appName) \($0.appBundleID) \($0.isMeeting) \(autoSettings.isTarget($0))" }
        return parts
    }

    private func rebuild() {
        builtStructure = currentStructure
        menu.removeAllItems()
        appLevelItem = nil
        micLevelItem = nil
        elapsedItem = nil
        conversionItems = [:]

        if let release = updates.available {
            menu.addItem(ActionItem(String(localized: "새 버전 \(release.version) 받기…")) { [weak self] in self?.updates.download() })
            menu.addItem(.separator())
        }
        // 자동 녹음 상태(켜져 있을 때만)
        if let text = autoRecorder.statusText {
            menu.addItem(Self.label(text))
        }
        if recorder.current != nil {
            if recorder.isRecording {
                if recorder.capturesAppSound {
                    let item = Self.label(appLevelTitle)
                    menu.addItem(item)
                    appLevelItem = item
                }
                let item = Self.label(micLevelTitle)
                menu.addItem(item)
                micLevelItem = item
            }
            let item = Self.label(elapsedTitle)
            menu.addItem(item)
            elapsedItem = item
        }
        // 멈춘 뒤 m4a 로 바꾸는 중. 2시간 회의면 40초쯤 걸린다.
        for conversionItem in conversion.items {
            let item = Self.label(Self.conversionTitle(conversionItem))
            menu.addItem(item)
            conversionItems[conversionItem.id] = item
        }
        // 전역 단축키는 GlobalHotKey 가 잡는다. 여기 지정은 메뉴에 표시하려는 것.
        let toggle = ActionItem(recorder.isRecording ? String(localized: "녹음 멈추기") : String(localized: "녹음 시작")) { [weak self] in
            self?.recorder.toggle()
        }
        toggle.keyEquivalent = "r"
        toggle.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(toggle)
        menu.addItem(.separator())

        if monitor.inputApps.isEmpty {
            menu.addItem(Self.label(String(localized: "마이크 쓰는 앱 없음")))
        } else {
            menu.addItem(Self.label(String(localized: "지금 마이크 쓰는 앱")))
            for app in monitor.inputApps {
                let mark = app.isMeeting ? "● " : ""
                let title = autoSettings.isTarget(app)
                    ? String(localized: "\(mark)\(app.appName) — 자동 녹음 대상")
                    : String(localized: "\(mark)\(app.appName)  (\(app.appBundleID))")
                menu.addItem(Self.label(title))
            }
        }
        menu.addItem(.separator())

        // 창을 "나중에"로 닫았거나 시작 때 남아 있던 녹음. 고르면 저장 창을 다시 띄운다.
        if !saveQueue.pending.isEmpty {
            let submenu = NSMenu()
            for url in saveQueue.pending {
                submenu.addItem(ActionItem(url.deletingPathExtension().lastPathComponent) { [weak self] in self?.saveQueue.open(url) })
            }
            submenu.addItem(.separator())
            submenu.addItem(ActionItem(String(localized: "모두 휴지통으로 옮기기…")) { [weak self] in self?.saveQueue.confirmTrashAll() })
            menu.addItem(Self.submenu(String(localized: "분류 안 됨 \(saveQueue.pending.count)개"), submenu))
        }
        // 고르면 그 폴더를 Finder 로 연다(손으로 옮기거나 지울 수 있게).
        if delivery.waitingCount > 0 {
            menu.addItem(ActionItem(String(localized: "보낼 대기 \(delivery.waitingCount)개")) { NSWorkspace.shared.open(Delivery.outboxURL) })
        }
        if delivery.failedCount > 0 {
            menu.addItem(ActionItem(String(localized: "보내지 못한 파일 \(delivery.failedCount)개")) { NSWorkspace.shared.open(Delivery.failedURL) })
        }
        menu.addItem(ActionItem(String(localized: "저장 위치…")) { SettingsWindow.show() })

        let auto = NSMenu()
        auto.addItem(ActionItem(String(localized: "회의 앱이 마이크를 쓰면 자동 녹음"), isOn: autoSettings.isEnabled) { [weak self] in
            guard let self else { return }
            autoSettings.setEnabled(!autoSettings.isEnabled)
        })
        auto.addItem(.separator())
        auto.addItem(Self.label(String(localized: "대상 앱")))
        for app in AutoRecordApp.all {
            let on = autoSettings.appIDs.contains(app.id)
            auto.addItem(ActionItem(app.name, isOn: on) { [weak self] in self?.autoSettings.setApp(app.id, on: !on) })
        }
        menu.addItem(Self.submenu(String(localized: "자동 녹음"), auto))

        let sound = NSMenu()
        for source in CaptureSource.allCases {
            sound.addItem(ActionItem(source.title, isOn: audioSettings.source == source) { [weak self] in self?.audioSettings.setSource(source) })
        }
        sound.addItem(.separator())
        // 받아쓰기에서 누가 말했는지 가를 수 있게. 마이크만 녹음은 나눌 게 없다.
        let split = audioSettings.splitChannels
        sound.addItem(ActionItem(String(localized: "내 목소리·상대 좌우로 나누기"), isOn: split) { [weak self] in self?.audioSettings.setSplitChannels(!split) })
        menu.addItem(Self.submenu(String(localized: "녹음할 소리"), sound))

        let mic = NSMenu()
        mic.addItem(ActionItem(String(localized: "시스템 기본"), isOn: audioSettings.micUID == nil) { [weak self] in self?.audioSettings.setMic(nil) })
        mic.addItem(.separator())
        for device in audioSettings.inputDevices {
            mic.addItem(ActionItem(device.name, isOn: audioSettings.micUID == device.uid) { [weak self] in self?.audioSettings.setMic(device.uid) })
        }
        // 고른 장치가 빠져 있으면 시스템 기본으로 녹음한다.
        if audioSettings.isMicMissing {
            let missing = NSMenuItem(title: String(localized: "고른 마이크(연결 안 됨)"), action: nil, keyEquivalent: "")
            missing.state = .on
            mic.addItem(missing)
        }
        menu.addItem(Self.submenu(String(localized: "마이크"), mic))
        menu.addItem(.separator())

        let login = loginItem.isEnabled
        menu.addItem(ActionItem(String(localized: "로그인 시 실행"), isOn: login) { [weak self] in self?.loginItem.setEnabled(!login) })
        menu.addItem(ActionItem(String(localized: "업데이트 확인…")) { [weak self] in self?.updates.checkFromMenu() })
        menu.addItem(ActionItem(String(localized: "감지 로그 열기")) { NSWorkspace.shared.open(MicMonitor.logURL) })
        // 정상 종료(0)라 LaunchAgent 가 다시 켜지 않는다.
        menu.addItem(ActionItem(String(localized: "종료")) { NSApp.terminate(nil) })
    }

    private var appLevelTitle: String { String(localized: "맥 소리 \(Self.levelBar(recorder.live.appLevel))") }
    private var micLevelTitle: String { String(localized: "마이크 \(Self.levelBar(recorder.live.micLevel))") }
    private var elapsedTitle: String { String(localized: "녹음 중: \(recorder.current?.appName ?? "") \(recorder.live.elapsedText)") }

    private static func conversionTitle(_ item: ConversionStatus.Item) -> String {
        String(localized: "변환 중: \(item.appName) \(Int((item.fraction * 100).rounded(.down)))%")
    }

    /// 0~1 → 10칸 막대
    private static func levelBar(_ level: Double) -> String {
        let filled = min(max(Int((level * Double(levelBarCount)).rounded()), 0), levelBarCount)
        return String(repeating: "▮", count: filled) + String(repeating: "▯", count: levelBarCount - filled)
    }

    /// 누를 수 없는 안내 줄
    private static func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func submenu(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        submenu.autoenablesItems = false
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
}

/// 누르면 클로저를 부르는 메뉴 항목. isOn 을 주면 체크 표시를 단다.
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, isOn: Bool? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let isOn { state = isOn ? .on : .off }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
