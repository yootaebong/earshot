import AppKit
import Combine
import SwiftUI

/// Pending 의 m4a 목록과 저장 창. 녹음이 끝나면 창을 앞에 띄우고, 여러 개면 하나씩 차례로 띄운다.
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

    private func added(_ url: URL, prompt: Bool) {
        refresh()
        guard prompt else { return }
        if shown == nil {
            present(url)
        } else if shown != url, !waiting.contains(url) {
            waiting.append(url)
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
