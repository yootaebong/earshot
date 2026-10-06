import AppKit
import Combine
import SwiftUI
import UserNotifications

/// Pending 의 m4a 목록과 저장 창. 녹음이 끝나면 창은 띄우지 않고 알림만 보낸다 — 알림이나 메뉴의 "분류 안 됨"을 누르면 그때 창을 띄운다.
/// "나중에"·창 닫기는 Pending 에 그대로 둔다(분류 안 됨).
@MainActor
final class SaveQueue: ObservableObject {
    /// 분류 안 됨(Pending 의 m4a). 이름순
    @Published private(set) var pending: [URL] = []

    private let delivery: Delivery
    /// 자동으로 띄울 차례
    private var waiting: [URL] = []
    /// 보내는 중이라 목록에서 뺄 것
    private var sending: Set<URL> = []
    private var shown: URL?
    private var panel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []

    init(delivery: Delivery) {
        self.delivery = delivery
        refresh()
        NotificationRouter.shared.setOnOpen { [weak self] url in
            guard let self else { return }
            refresh()
            // 이미 저장했거나 지운 녹음이면 아무것도 안 띄운다.
            guard let match = pending.first(where: { $0.path == url.path }) else {
                MicMonitor.log("알림 누름 — 이미 분류됨 \(url.lastPathComponent)")
                return
            }
            open(match)
        }
        NotificationCenter.default.publisher(for: .recordingSaved)
            .sink { [weak self] note in
                guard let url = note.object as? URL else { return }
                let prompt = note.userInfo?["prompt"] as? Bool ?? false
                Task { @MainActor in self?.added(url, prompt: prompt) }
            }
            .store(in: &cancellables)
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(at: RecordingController.pendingURL, includingPropertiesForKeys: nil)) ?? []
        let now = files.filter { $0.pathExtension == "m4a" && !sending.contains($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if now != pending { pending = now }
    }

    /// 메뉴에서 고른 파일의 창을 띄운다(떠 있던 것은 바꿔 끼운다).
    func open(_ url: URL) {
        waiting.removeAll { $0 == url }
        // 떠 있던 것이 아직 분류 안 됨이면 다음 차례 맨 앞에 되돌려 둔다(창을 닫으면 다시 뜬다).
        if let shown, shown != url, pending.contains(shown) {
            waiting.insert(shown, at: 0)
        }
        present(url)
    }

    /// 방금 끝난 녹음은 알림만 보낸다(회의 직후 창이 앞을 가리지 않게). 시작 때 복구한 것은 알림도 없다.
    /// 알림이 꺼져 있거나 못 보내면 예전처럼 창을 띄운다 — 아무 신호 없이 "분류 안 됨"에만 쌓이지 않게.
    private func added(_ url: URL, prompt: Bool) {
        refresh()
        guard prompt else { return }
        Task {
            guard await !NotificationRouter.notifySaved(url, meta: RecordingMeta.load(for: url)) else { return }
            if shown == nil {
                present(url)
            } else if shown != url, !waiting.contains(url) {
                waiting.append(url)
            }
        }
    }

    private func showNext() {
        refresh()
        while let next = waiting.first {
            waiting.removeFirst()
            if pending.contains(next) {
                present(next)
                return
            }
        }
    }

    private func present(_ url: URL) {
        let meta = RecordingMeta.load(for: url)
        let form = SaveForm(meta: meta, fileName: url.lastPathComponent,
                            onSave: { [weak self] category, date, topic, attendees in
                                self?.save(url, meta: meta, category: category, date: date, topic: topic, attendees: attendees)
                            },
                            onLater: { [weak self] in self?.panel?.close() })
        let panel = panel ?? makePanel()
        self.panel = panel
        shown = url
        NotificationRouter.removeNotification(for: url)
        panel.contentViewController = NSHostingController(rootView: form)
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func save(_ url: URL, meta: RecordingMeta, category: Category, date: Date, topic: String, attendees: String) {
        let name = Delivery.fileName(startedAt: date, appName: meta.appName, topic: topic, attendees: attendees)
        sending.insert(url)
        panel?.close()
        Task {
            await delivery.send(url, category: category, fileName: name)
            sending.remove(url)
            refresh()
        }
    }

    /// 포커스를 받아 앞에 뜨는 작은 창. 닫기(⌘W·빨간 단추)는 "나중에"와 같다.
    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
                            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = String(localized: "녹음 저장")
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: panel)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.shown = nil
                    self?.showNext()
                }
            }
            .store(in: &cancellables)
        return panel
    }
}

/// 저장 창 내용
struct SaveForm: View {
    let meta: RecordingMeta
    let fileName: String
    let onSave: (Category, Date, String, String) -> Void
    let onLater: () -> Void

    @ObservedObject private var settings = StorageSettings.shared
    @State private var date: Date
    @State private var topic = ""
    @State private var attendees = ""
    @FocusState private var topicFocused: Bool

    init(meta: RecordingMeta, fileName: String, onSave: @escaping (Category, Date, String, String) -> Void, onLater: @escaping () -> Void) {
        self.meta = meta
        self.fileName = fileName
        self.onSave = onSave
        self.onLater = onLater
        _date = State(initialValue: meta.startedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(meta.appName) · \(durationText)")
                .foregroundStyle(.secondary)
            Form {
                DatePicker("날짜·시간", selection: $date, displayedComponents: [.date, .hourAndMinute])
                TextField("주제", text: $topic)
                    .focused($topicFocused)
                TextField("참석자", text: $attendees, prompt: Text("쉼표로 구분(선택)"))
            }
            HStack {
                Button("나중에", action: onLater)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                // 분류 버튼은 설정의 목록 순서대로
                ForEach(settings.categories) { category in
                    Button(category.name) { onSave(category, date, topic, attendees) }
                        .lineLimit(1)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 380)
        .onAppear { topicFocused = true }
    }

    /// 메타가 없던 옛 녹음은 길이 0 → 파일 이름으로 대신한다.
    private var durationText: String {
        guard meta.duration > 0 else { return fileName }
        let minutes = meta.duration / 60, seconds = meta.duration % 60
        return minutes > 0 ? String(localized: "\(minutes)분 \(seconds)초") : String(localized: "\(seconds)초")
    }
}

/// 녹음 준비 알림을 보내고, 누르면 그 녹음의 저장 창을 띄운다.
/// 앱이 꺼져 있을 때 누른 알림도 받도록 EarShotApp.init 에서 바로 delegate 로 붙인다.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    private static let urlKey = "url"
    @MainActor private var onOpen: ((URL) -> Void)?
    /// onOpen 이 붙기 전에 누른 알림
    @MainActor private var early: URL?

    @MainActor func setOnOpen(_ handler: @escaping (URL) -> Void) {
        onOpen = handler
        if let early {
            self.early = nil
            handler(early)
        }
    }

    @MainActor private func open(_ url: URL) {
        if let onOpen { onOpen(url) } else { early = url }
    }

    /// 알림 id 는 파일 경로 — 창을 열면 그 알림을 알림 센터에서 지운다. 알림이 꺼져 있거나 실패하면 false.
    static func notifySaved(_ url: URL, meta: RecordingMeta) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else {
            MicMonitor.log("알림 꺼짐 → 저장 창 띄움")
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "녹음 준비됨")
        let minutes = meta.duration / 60
        let length = minutes >= 60
            ? String(localized: "\(minutes / 60)시간 \(minutes % 60)분")
            : String(localized: "\(max(minutes, 1))분")
        content.body = String(localized: "\(meta.appName) · \(length) — 눌러서 주제를 적고 저장하세요")
        content.sound = .default
        content.userInfo = [urlKey: url.path]
        let request = UNNotificationRequest(identifier: url.path, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            MicMonitor.log("오류 알림 보내기: \(error.localizedDescription) → 저장 창 띄움")
            return false
        }
    }

    static func removeNotification(for url: URL) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [url.path])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        // 무음 경고 같은 다른 알림은 url 이 없다.
        let path = request.content.userInfo[Self.urlKey] as? String
        MicMonitor.log("알림 누름 \(path ?? "-") id=\(request.identifier) title=\(request.content.title)")
        Task { @MainActor in
            if let path { self.open(URL(fileURLWithPath: path)) }
            completionHandler()
        }
    }

    /// 앱이 앞에 있어도(저장 창을 보고 있을 때 등) 배너를 띄운다.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
