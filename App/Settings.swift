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

    /// 보낼 대기·받아쓸 대기 파일이 있으면 지우지 않는다(Outbox·대기열에 남아 영영 안 간다).
    func remove(_ id: Category.ID) {
        guard categories.count > Self.minCount, Delivery.waitingCount(categoryID: id) == 0,
              Transcriber.waitingCount(categoryID: id) == 0 else { return }
        update(categories.filter { $0.id != id })
        TranscriptionSettings.shared.setTranscribes(false, for: id)
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
        .frame(width: 640)
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
        if Transcriber.waitingCount(categoryID: category.id) > 0 { return String(localized: "받아쓸 대기 파일이 있어 지울 수 없어요") }
        return nil
    }
}

/// 메뉴 "받아쓰기 설정…" 창: 받아쓸 분류, 모델 상태, 내 이름, 언어
struct TranscriptionSettingsView: View {
    @ObservedObject var storage = StorageSettings.shared
    @ObservedObject var transcription = TranscriptionSettings.shared
    @ObservedObject var models = ModelStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("켠 분류의 녹음은 이 맥에서 받아써 같은 폴더에 .md 로 보내요")
                .font(.callout)
                .foregroundStyle(.secondary)
            // 켰는데 모델이 없으면 바로 내려받는다.
            ForEach(storage.categories) { category in
                Toggle(category.name, isOn: Binding(
                    get: { transcription.transcribes(category.id) },
                    set: { on in
                        transcription.setTranscribes(on, for: category.id)
                        if on { models.downloadIfNeeded() }
                    }))
            }
            Divider()
            modelRow
            HStack {
                Text("내 이름")
                SpeakerNameField(value: transcription.speakerMe) { transcription.setSpeakerMe($0) }
                Spacer()
            }
            Text("상대 이름은 저장 창에 적은 참석자로 써요(비우면 \"상대\")")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("언어", selection: Binding(get: { transcription.language }, set: { transcription.setLanguage($0) })) {
                ForEach(TranscriptionSettings.languages, id: \.self) { code in
                    Text(verbatim: TranscriptionSettings.languageName(code)).tag(code)
                }
            }
            .fixedSize()
        }
        .padding(20)
        .frame(width: 480, alignment: .leading)
    }

    @ViewBuilder private var modelRow: some View {
        HStack {
            switch models.state {
            case .missing:
                downloadButton
            case .failed(let message):
                Text("내려받기 실패: \(message)")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                downloadButton
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .frame(width: 240)
                Text(verbatim: "\(Int((fraction * 100).rounded(.down)))%")
                    .monospacedDigit()
                Button("취소") { models.cancel() }
            case .ready:
                Text("모델 준비됨")
                Button("지우기") { models.delete() }
            }
            Spacer()
        }
    }

    private var downloadButton: some View {
        Button("모델 내려받기 (약 575MB)") { models.download() }
    }
}

/// 화자 이름 칸. 이름 칸처럼 엔터·포커스가 빠질 때 저장하고, 빈 이름이면 원래 이름으로 되돌린다.
private struct SpeakerNameField: View {
    let value: String
    let onCommit: (String) -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(value: String, onCommit: @escaping (String) -> Void) {
        self.value = value
        self.onCommit = onCommit
        _draft = State(initialValue: value)
    }

    var body: some View {
        TextField(value, text: $draft)
            .labelsHidden()
            .frame(width: 100)
            .focused($focused)
            .onChange(of: focused) { _, focused in if !focused { commit() } }
            .onSubmit { commit() }
            .onChange(of: value) { _, value in if !focused { draft = value } }
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            draft = value
        } else {
            draft = name
            onCommit(name)
        }
    }
}

/// 받아쓰기 설정. 분류마다 켜고 끄는 값은 Category 에 넣지 않고 따로 둔다 —
/// Category 에 키를 더하면 예전 JSON 을 못 읽어 분류가 기본값으로 날아간다.
@MainActor
final class TranscriptionSettings: ObservableObject {
    static let shared = TranscriptionSettings()
    /// 언어 선택지. auto 는 첫 조각에서 정해 그 파일 끝까지 쓴다.
    nonisolated static let languages = ["auto", "ko", "en", "ja", "zh"]
    nonisolated static let autoLanguage = "auto"

    nonisolated private static let categoryIDsKey = "transcribeCategoryIDs"
    nonisolated private static let meKey = "speakerNameMe"
    nonisolated private static let languageKey = "transcribeLanguage"

    /// 받아쓰기를 켠 분류 id
    @Published private(set) var categoryIDs: Set<Category.ID>
    @Published private(set) var speakerMe: String
    @Published private(set) var language: String

    private init() {
        categoryIDs = Self.transcribedCategoryIDs
        speakerMe = Self.speakerMe
        language = Self.languageCode
    }

    // 받아쓰기 큐(백그라운드)에서 읽는다.
    nonisolated static var transcribedCategoryIDs: Set<Category.ID> {
        Set(UserDefaults.standard.stringArray(forKey: categoryIDsKey) ?? [])
    }

    nonisolated static var speakerMe: String {
        UserDefaults.standard.string(forKey: meKey) ?? String(localized: "나")
    }

    nonisolated static var languageCode: String {
        UserDefaults.standard.string(forKey: languageKey).flatMap { languages.contains($0) ? $0 : nil } ?? autoLanguage
    }

    /// 화면에 보일 언어 이름(지금 언어로)
    static func languageName(_ code: String) -> String {
        guard code != autoLanguage else { return String(localized: "자동") }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    func transcribes(_ id: Category.ID) -> Bool {
        categoryIDs.contains(id)
    }

    func setTranscribes(_ on: Bool, for id: Category.ID) {
        guard on != categoryIDs.contains(id) else { return }
        var ids = categoryIDs
        if on { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(ids.sorted(), forKey: Self.categoryIDsKey)
        categoryIDs = ids
        MicMonitor.log("받아쓰기 \(id) → \(on)")
    }

    func setSpeakerMe(_ name: String) {
        guard let name = Self.cleanName(name), name != speakerMe else { return }
        UserDefaults.standard.set(name, forKey: Self.meKey)
        speakerMe = name
    }

    func setLanguage(_ code: String) {
        guard Self.languages.contains(code), code != language else { return }
        UserDefaults.standard.set(code, forKey: Self.languageKey)
        language = code
        MicMonitor.log("받아쓰기 언어 → \(code)")
    }

    /// 앞뒤 공백을 뗀다. 비면 nil(저장 안 함)
    private static func cleanName(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

/// 설정 창 하나를 재사용한다.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        window = present(window) { NSHostingController(rootView: StorageSettingsView(settings: .shared)) }
        window?.title = String(localized: "저장 위치")
    }

    /// 있으면 앞으로, 없으면 만들어 띄운다.
    static func present(_ existing: NSWindow?, content: () -> NSViewController) -> NSWindow {
        let window = existing ?? {
            let window = NSWindow(contentViewController: content())
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            return window
        }()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

/// 받아쓰기 설정 창 하나를 재사용한다.
@MainActor
enum TranscriptionSettingsWindow {
    private static var window: NSWindow?

    static func show() {
        window = SettingsWindow.present(window) { NSHostingController(rootView: TranscriptionSettingsView()) }
        window?.title = String(localized: "받아쓰기 설정")
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
