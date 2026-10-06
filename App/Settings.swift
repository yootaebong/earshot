import AppKit
import CoreAudio
import SwiftUI

/// 분류. id 는 Outbox 하위 폴더 이름이라 바꾸지 않는다. name 은 화면에 보이는 이름, path 는 보낼 폴더
struct Category: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var path: String
}

/// 분류 목록. UserDefaults 에 JSON 으로 둔다.
@MainActor
final class StorageSettings: ObservableObject {
    static let shared = StorageSettings()
    static let minCount = 1
    static let maxCount = 6

    nonisolated private static let categoriesKey = "categories"
    /// 예전 빌드(회사·개인 고정)가 쓰던 키
    nonisolated private static let legacyFolderKeys = (company: "folderCompany", personal: "folderPersonal")
    nonisolated private static let legacyIDs = (company: "회사", personal: "개인")

    @Published private(set) var categories: [Category]

    private init() {
        categories = Self.loadCategories()
    }

    /// 전송 큐에서도 읽으므로 UserDefaults 를 바로 읽는다. 처음이면 기본 목록을 만들어 저장한다.
    nonisolated static func loadCategories() -> [Category] {
        if let data = UserDefaults.standard.data(forKey: categoriesKey),
           let list = try? JSONDecoder().decode([Category].self, from: data), !list.isEmpty {
            return list
        }
        let list = isLegacyUser() ? legacyCategories() : defaultCategories()
        store(list)
        return list
    }

    nonisolated private static func store(_ list: [Category]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: categoriesKey)
    }

    /// 분류 목록이 생기기 전 빌드를 쓴 사람인지. 로그인 항목을 한 번이라도 정했거나 Outbox 에 회사·개인 폴더가 있으면 그렇다.
    nonisolated private static func isLegacyUser() -> Bool {
        let defaults = UserDefaults.standard
        if ["loginItemConfigured", legacyFolderKeys.company, legacyFolderKeys.personal]
            .contains(where: { defaults.object(forKey: $0) != nil }) { return true }
        return [legacyIDs.company, legacyIDs.personal].contains { id in
            FileManager.default.fileExists(atPath: Delivery.outboxURL.appending(path: id).path)
        }
    }

    /// 예전 회사·개인. id 를 옛 폴더 이름으로 둬서 Outbox 에 남은 것을 그대로 보낸다.
    nonisolated private static func legacyCategories() -> [Category] {
        let defaults = UserDefaults.standard
        return [
            Category(id: legacyIDs.company, name: legacyIDs.company,
                     path: defaults.string(forKey: legacyFolderKeys.company) ?? "/Volumes/회의록/\(legacyIDs.company)"),
            Category(id: legacyIDs.personal, name: legacyIDs.personal,
                     path: defaults.string(forKey: legacyFolderKeys.personal) ?? "/Volumes/회의록/\(legacyIDs.personal)"),
        ]
    }

    /// 새로 설치한 사람의 기본값. ~/Documents/EarShot/<이름>
    nonisolated private static func defaultCategories() -> [Category] {
        [
            Category(id: "work", name: String(localized: "회사"), path: ""),
            Category(id: "personal", name: String(localized: "개인"), path: ""),
        ].map { category in
            var category = category
            category.path = defaultPath(name: category.name)
            return category
        }
    }

    nonisolated private static func defaultPath(name: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/EarShot/\(name)").path
    }

    private func update(_ list: [Category]) {
        categories = list
        Self.store(list)
    }

    /// 앞뒤 공백을 떼고, 빈 이름은 저장하지 않는다. id 는 그대로라 Outbox 폴더도 그대로다.
    func rename(_ id: Category.ID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = categories.firstIndex(where: { $0.id == id }), categories[index].name != name else { return }
        var list = categories
        list[index].name = name
        update(list)
    }

    func setPath(_ path: String, for id: Category.ID) {
        guard let index = categories.firstIndex(where: { $0.id == id }) else { return }
        var list = categories
        list[index].path = path
        update(list)
        MicMonitor.log("저장 위치 \(list[index].name) → \(path)")
    }

    func add() {
        guard categories.count < Self.maxCount else { return }
        let name = String(localized: "새 분류")
        update(categories + [Category(id: UUID().uuidString, name: name, path: Self.defaultPath(name: name))])
    }

    /// 보낼 대기 파일이 있으면 지우지 않는다(Outbox 에 남아 영영 안 간다).
    func remove(_ id: Category.ID) {
        guard categories.count > Self.minCount, Delivery.waitingCount(categoryID: id) == 0 else { return }
        update(categories.filter { $0.id != id })
    }

    /// NSOpenPanel 로 폴더를 고른다.
    func choose(for id: Category.ID) {
        guard let category = categories.first(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "선택")
        panel.message = String(localized: "\(category.name) 회의록을 보낼 폴더")
        let current = URL(filePath: category.path)
        if FileManager.default.fileExists(atPath: current.path) { panel.directoryURL = current }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setPath(url.path, for: id)
    }
}

/// 메뉴 "저장 위치…" 창
struct StorageSettingsView: View {
    @ObservedObject var settings: StorageSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(settings.categories) { category in
                CategoryRow(category: category, settings: settings)
            }
            HStack {
                Spacer()
                Button("추가") { settings.add() }
                    .disabled(settings.categories.count >= StorageSettings.maxCount)
                    .help(settings.categories.count >= StorageSettings.maxCount
                          ? String(localized: "분류는 최대 \(StorageSettings.maxCount)개까지예요") : "")
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// 분류 한 줄: [이름][경로][바꾸기][삭제]
private struct CategoryRow: View {
    let category: Category
    @ObservedObject var settings: StorageSettings

    @State private var draft: String
    @FocusState private var nameFocused: Bool

    init(category: Category, settings: StorageSettings) {
        self.category = category
        self.settings = settings
        _draft = State(initialValue: category.name)
    }

    var body: some View {
        HStack {
            // 한글 조합이 끊기지 않게 칠 때가 아니라 엔터·포커스가 빠질 때 저장한다. 빈 이름이면 원래 이름으로 되돌린다.
            TextField("이름", text: $draft)
                .labelsHidden()
                .frame(width: 100)
                .focused($nameFocused)
                .onChange(of: nameFocused) { _, focused in if !focused { commit() } }
                .onSubmit { commit() }
            Text((category.path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("바꾸기") { settings.choose(for: category.id) }
            Button("삭제") { settings.remove(category.id) }
                .disabled(deleteBlockedReason != nil)
                .help(deleteBlockedReason ?? "")
        }
    }

    private func commit() {
        settings.rename(category.id, to: draft)
        draft = settings.categories.first { $0.id == category.id }?.name ?? category.name
    }

    /// 지울 수 없으면 그 이유
    private var deleteBlockedReason: String? {
        if settings.categories.count <= StorageSettings.minCount { return String(localized: "분류는 하나 이상 있어야 해요") }
        if Delivery.waitingCount(categoryID: category.id) > 0 { return String(localized: "보낼 대기 파일이 있어 지울 수 없어요") }
        return nil
    }
}

/// 설정 창 하나를 재사용한다.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        let window = window ?? {
            let window = NSWindow(contentViewController: NSHostingController(rootView: StorageSettingsView(settings: .shared)))
            window.title = String(localized: "저장 위치")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            return window
        }()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// 녹음할 소리. rawValue 는 UserDefaults 값
enum CaptureSource: String, CaseIterable, Sendable {
    case meetingApp
    case system
    case micOnly

    var title: String {
        switch self {
        case .meetingApp: String(localized: "회의 앱 소리(없으면 맥 전체)")
        case .system: String(localized: "맥 전체")
        case .micOnly: String(localized: "마이크만")
        }
    }
}

/// 입력 채널이 있는 오디오 장치
struct InputDevice: Hashable, Identifiable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// 마이크 장치·녹음할 소리. UserDefaults 에 두고, 장치 목록은 Core Audio 알림으로 갱신한다.
@MainActor
final class AudioSettings: ObservableObject {
    static let shared = AudioSettings()

    private static let micKey = "micDeviceUID"
    private static let sourceKey = "captureSource"
    nonisolated private static let splitKey = "splitChannels"

    /// nil 이면 시스템 기본 입력
    @Published private(set) var micUID: String?
    @Published private(set) var source: CaptureSource
    @Published private(set) var inputDevices: [InputDevice] = []
    /// 내 목소리(마이크)는 왼쪽, 상대(맥 소리)는 오른쪽으로 나눠 저장할지. 기본 켜짐
    @Published private(set) var splitChannels = AudioSettings.splitsChannels

    /// 섞을 때(백그라운드) 읽는다.
    nonisolated static var splitsChannels: Bool {
        UserDefaults.standard.object(forKey: splitKey) as? Bool ?? true
    }

    private init() {
        micUID = UserDefaults.standard.string(forKey: Self.micKey)
        source = UserDefaults.standard.string(forKey: Self.sourceKey).flatMap(CaptureSource.init(rawValue:)) ?? .meetingApp
        inputDevices = Self.currentInputDevices()
        var address = CoreAudioProperty.address(kAudioHardwarePropertyDevices)
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        if status != noErr { MicMonitor.log("오류 장치 목록 감시 등록 \(status)") }
    }

    func setMic(_ uid: String?) {
        guard uid != micUID else { return }
        UserDefaults.standard.set(uid, forKey: Self.micKey)
        micUID = uid
        MicMonitor.log("마이크 → \(uid.map { uid in inputDevices.first { $0.uid == uid }?.name ?? uid } ?? "시스템 기본")")
    }

    func setSource(_ source: CaptureSource) {
        guard source != self.source else { return }
        UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey)
        self.source = source
        MicMonitor.log("녹음할 소리 → \(source.title)")
    }

    func setSplitChannels(_ on: Bool) {
        guard on != splitChannels else { return }
        UserDefaults.standard.set(on, forKey: Self.splitKey)
        splitChannels = on
        MicMonitor.log("좌우 나누기 → \(on)")
    }

    private func refreshDevices() {
        let now = Self.currentInputDevices()
        if now != inputDevices { inputDevices = now }
    }

    /// 고른 마이크의 지금 장치 ID. 시스템 기본이거나 고른 장치가 없으면 nil
    var micDeviceID: AudioDeviceID? {
        guard let micUID else { return nil }
        return Self.currentInputDevices().first { $0.uid == micUID }?.id
    }

    /// 고른 마이크가 지금 연결돼 있지 않은지
    var isMicMissing: Bool {
        guard let micUID else { return false }
        return !inputDevices.contains { $0.uid == micUID }
    }

    // MARK: - Core Audio

    /// 입력 채널이 있는 장치 전부. 녹음용으로 만든 EarShot aggregate 는 뺀다.
    nonisolated static func currentInputDevices() -> [InputDevice] {
        let ids: [AudioDeviceID] = CoreAudioProperty.readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0, let uid = CoreAudioProperty.readString(id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = CoreAudioProperty.readString(id, kAudioObjectPropertyName) ?? uid
            guard !name.hasPrefix("EarShot") else { return nil }
            return InputDevice(id: id, uid: uid, name: name)
        }
    }

    nonisolated private static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
