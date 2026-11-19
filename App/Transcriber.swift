import AVFoundation
import Combine
import CryptoKit
import whisper

/// 받아쓰기 모델 두 개(whisper·VAD)를 Application Support 에 내려받아 둔다.
/// 받은 뒤 SHA256 을 확인하고 맞을 때만 제자리로 옮긴다. 시작할 때는 크기만 본다(575MB 해시는 매번 재기엔 무겁다).
@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    enum State: Equatable {
        case missing
        /// 두 파일 합산 0~1
        case downloading(Double)
        case ready
        case failed(String)
    }

    struct ModelFile: Sendable {
        let name: String
        let url: URL
        let size: Int64
        let sha256: String

        var localURL: URL { ModelStore.directory.appending(path: name) }
        /// 받는 중인 파일. "." 로 시작해 Finder 에 안 보인다.
        var stagedURL: URL { ModelStore.directory.appending(path: ".\(name).download") }
    }

    nonisolated static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/EarShot/Models")
    // URL 은 고정 문자열이라 ! 로 푼다.
    nonisolated static let whisperModel = ModelFile(
        name: "ggml-large-v3-turbo-q5_0.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
        size: 574_041_195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2")
    nonisolated static let vadModel = ModelFile(
        name: "ggml-silero-v5.1.2.bin",
        url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!,
        size: 885_098,
        sha256: "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf")
    nonisolated static let files = [whisperModel, vadModel]
    nonisolated private static let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
    /// 해시를 잴 때 한 번에 읽는 크기
    nonisolated private static let hashReadSize = 4 << 20

    @Published private(set) var state: State
    private var task: Task<Void, Never>?

    private init() {
        state = Self.isInstalled ? .ready : .missing
    }

    /// 두 파일이 다 제자리에 있는지(크기만 본다). 받아쓰기 큐에서도 읽는다.
    nonisolated static var isInstalled: Bool {
        files.allSatisfy(isPresent)
    }

    nonisolated private static func isPresent(_ file: ModelFile) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.localURL.path)[.size] as? Int64) ?? nil
        return size == file.size
    }

    var isReady: Bool { state == .ready }

    /// 모델 파일은 있는데 whisper 가 못 열었을 때. 받아쓰기는 멈추고 사용자가 지우고 다시 받게 한다.
    func markBroken() {
        guard task == nil else { return }
        state = .failed(String(localized: "모델 파일이 손상됐어요 — 지우고 다시 받아 주세요"))
        MicMonitor.log("오류 모델 열기 실패 → 받아쓰기 멈춤")
    }

    /// 받는 중이 아니면 파일이 지금 있는지 다시 본다(Finder 에서 지웠을 때).
    func refresh() {
        guard task == nil, state == .ready || state == .missing else { return }
        let now: State = Self.isInstalled ? .ready : .missing
        if now != state { state = now }
    }

    /// 없거나 실패했을 때만 받는다(받아쓰기를 켤 때).
    func downloadIfNeeded() {
        switch state {
        case .missing, .failed: download()
        case .downloading, .ready: break
        }
    }

    func download() {
        guard task == nil, state != .ready else { return }
        state = .downloading(0)
        MicMonitor.log("모델 내려받기 시작")
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
    }

    /// 받아 둔 모델을 지운다. 받아쓰는 중이던 파일은 이미 모델을 메모리에 올려 끝까지 간다.
    func delete() {
        guard task == nil else { return }
        for file in Self.files {
            do {
                if FileManager.default.fileExists(atPath: file.localURL.path) { try FileManager.default.removeItem(at: file.localURL) }
            } catch {
                MicMonitor.log("오류 모델 지우기 \(file.name) \(error.localizedDescription)")
            }
        }
        state = Self.isInstalled ? .ready : .missing
        MicMonitor.log("모델 지움")
    }

    private func run() async {
        defer { task = nil }
        var done: Int64 = 0
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            for file in Self.files {
                // 지난번에 하나만 받고 끊겼으면 받은 것은 건너뛴다.
                if Self.isPresent(file) {
                    done += file.size
                    report(done)
                    continue
                }
                let base = done
                let downloader = FileDownloader(staged: file.stagedURL) { [weak self] written in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.report(base + written) }
                    }
                }
                let staged = try await withTaskCancellationHandler {
                    try await downloader.download(file.url)
                } onCancel: {
                    downloader.cancel()
                }
                try Task.checkCancellation()
                // 분리 작업이라 취소가 저절로 넘어가지 않는다 — 넘겨 준다. 취소되면 아래 catch 가 staged 를 지운다.
                let hashing = Task.detached { try Self.sha256(of: staged) }
                let digest = try await withTaskCancellationHandler {
                    try await hashing.value
                } onCancel: {
                    hashing.cancel()
                }
                guard digest == file.sha256 else {
                    try? FileManager.default.removeItem(at: staged)
                    throw TranscriptionError(String(localized: "받은 파일의 확인값이 달라요"))
                }
                if FileManager.default.fileExists(atPath: file.localURL.path) { try FileManager.default.removeItem(at: file.localURL) }
                try FileManager.default.moveItem(at: staged, to: file.localURL)
                done += file.size
                MicMonitor.log("모델 받음 \(file.name)")
            }
            state = .ready
        } catch {
            for file in Self.files { try? FileManager.default.removeItem(at: file.stagedURL) }
            if Task.isCancelled {
                MicMonitor.log("모델 내려받기 취소")
                state = Self.isInstalled ? .ready : .missing
            } else {
                MicMonitor.log("오류 모델 내려받기 \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// 1% 단위로만 다시 그린다. 취소한 뒤 늦게 온 진행률은 버린다.
    private func report(_ bytes: Int64) {
        guard case .downloading(let current) = state else { return }
        let fraction = min(max(Double(bytes) / Double(Self.totalBytes), 0), 1)
        guard Int(fraction * 100) != Int(current * 100) else { return }
        state = .downloading(fraction)
    }

    /// 파일을 조금씩 읽어 SHA256 을 잰다(575MB 를 메모리에 올리지 않게).
    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let finished = try autoreleasepool {
                guard let data = try handle.read(upToCount: hashReadSize), !data.isEmpty else { return true }
                hasher.update(data: data)
                return false
            }
            if finished { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// URLSession 내려받기 하나. 진행률은 받은 바이트로 알리고, 끝나면 임시 파일을 staged 로 옮겨 돌려준다.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let staged: URL
    private let onProgress: @Sendable (Int64) -> Void
    /// 아래 값은 lock 으로만 만진다(델리게이트 큐와 부른 쪽이 다르다).
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false

    init(staged: URL, onProgress: @escaping @Sendable (Int64) -> Void) {
        self.staged = staged
        self.onProgress = onProgress
    }

    func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            let cancelled = lock.withLock {
                self.continuation = continuation
                self.task = task
                return self.cancelled
            }
            if cancelled {
                session.invalidateAndCancel()
                finish(.failure(CancellationError()))
                return
            }
            task.resume()
            // 끝나면 세션을 놓는다(델리게이트를 잡고 있다).
            session.finishTasksAndInvalidate()
        }
    }

    func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten)
    }

    /// location 은 이 함수가 끝나면 지워지므로 여기서 바로 옮긴다.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(TranscriptionError("HTTP \(http.statusCode)")))
            return
        }
        do {
            if FileManager.default.fileExists(atPath: staged.path) { try FileManager.default.removeItem(at: staged) }
            try FileManager.default.moveItem(at: location, to: staged)
            finish(.success(staged))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}

/// 받아쓰기를 켠 분류로 저장한 녹음을 대기열에 두었다가, 녹음·변환이 없을 때 whisper.cpp 로 받아써
/// 같은 폴더로 <같은 이름>.md 를 보낸다. 한 번에 한 파일, 무거운 일은 전용 큐에서 한다.
@MainActor
final class Transcriber: ObservableObject {
    /// 지금 받아쓰는 파일의 앱 이름. 없으면 nil
    @Published private(set) var currentAppName: String?
    /// 지금 파일의 진행률 0~1(처리한 오디오 초 / 채널 수 × 길이)
    @Published private(set) var fraction: Double = 0
    /// 대기열의 파일 수(받아쓰는 중인 것 포함)
    @Published private(set) var waitingCount = 0

    nonisolated static let queueURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/EarShot/Transcribe")
    /// 받아쓰기에 실패한 파일. 자동으로 다시 하지 않는다.
    nonisolated static let failedURL: URL = queueURL.appending(path: "실패")
    nonisolated private static let workQueue = DispatchQueue(label: "io.taebong.EarShot.transcribe", qos: .utility)
    /// 신호가 오고 이만큼 기다렸다 본다. 겹쳐 온 신호(녹음 끝·변환 시작·끝)를 한 번으로 모은다.
    private static let kickDelay: TimeInterval = 1

    private let recorder: RecordingController
    private let delivery: Delivery
    private let models = ModelStore.shared
    private let conversion = ConversionStatus.shared
    /// 녹음이 시작되면 선다. 받아쓰기 큐가 조각 사이마다 본다.
    nonisolated private let interrupt = InterruptFlag()
    private var isRunning = false
    private var kickScheduled = false
    private var cancellables: Set<AnyCancellable> = []

    init(recorder: RecordingController, delivery: Delivery) {
        self.recorder = recorder
        self.delivery = delivery
        // @Published 는 바뀌기 전에 알리므로 Task 로 미뤄서 본다. 구독하자마자 한 번 오므로 시작 때 남은 대기열도 이어서 한다.
        let interrupt = interrupt
        recorder.$current
            .sink { [weak self] current in
                if current != nil { interrupt.set() }
                Task { @MainActor in self?.scheduleKick() }
            }
            .store(in: &cancellables)
        Publishers.Merge(conversion.$items.map { _ in () }, models.$state.map { _ in () })
            .sink { [weak self] in Task { @MainActor in self?.scheduleKick() } }
            .store(in: &cancellables)
        refreshCount()
    }

    /// 대기열에 넣는다. Pending 의 m4a·json 을 복사한다(같은 APFS 라 클론). 실패하면 로그만 남긴다.
    /// meta 는 저장 창에서 고친 날짜를 담은 것 — md 의 날짜가 파일 이름 날짜와 같게.
    func enqueue(_ m4a: URL, meta: RecordingMeta, categoryID: Category.ID, fileName: String) async {
        await Task.detached { Self.copyToQueue(m4a, meta: meta, categoryID: categoryID, fileName: fileName) }.value
        refreshCount()
        scheduleKick()
    }

    /// 이 분류에서 받아쓸 차례를 기다리는 파일 수(설정 창에서 지워도 되는지 볼 때)
    nonisolated static func waitingCount(categoryID: Category.ID) -> Int {
        m4aFiles(in: queueURL.appending(path: categoryID)).count
    }

    // MARK: - 처리 루프

    private func scheduleKick() {
        guard !kickScheduled else { return }
        kickScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.kickDelay) { [weak self] in
            MainActor.assumeIsolated {
                self?.kickScheduled = false
                self?.kick()
            }
        }
    }

    /// 모델이 있고 녹음·변환이 없으면 가장 오래된 파일 하나를 받아쓴다. 끝나면 다음 것을 본다.
    /// 지난번에 m4a 를 지운 뒤 보내기 전에 끊겨 md 만 남았으면 받아쓰지 않고 그것부터 보낸다.
    private func kick() {
        guard !isRunning else { return }
        if let leftover = Self.leftoverMarkdown() {
            isRunning = true
            Task {
                await sendMarkdown(leftover.md, categoryID: leftover.categoryID)
                isRunning = false
                refreshCount()
                scheduleKick()
            }
            return
        }
        guard models.isReady, !recorder.isRecording, conversion.items.isEmpty,
              let job = Self.nextJob() else { return }
        isRunning = true
        interrupt.reset()
        let meta = RecordingMeta.load(for: job.m4a)
        currentAppName = meta.appName
        fraction = 0
        MicMonitor.log("받아쓰기 시작 \(job.m4a.lastPathComponent)")
        let interrupt = interrupt
        let progress: @Sendable (Double) -> Void = { [weak self] value in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.report(value) }
            }
        }
        Task {
            let outcome = await Self.runOnWorkQueue { Self.transcribe(job, meta: meta, interrupt: interrupt, progress: progress) }
            switch outcome {
            case .done(let md):
                await deliver(job, md: md)
            case .interrupted:
                // 지우지 않고 남겨 둔다 — 다음 차례에 처음부터 다시 한다.
                MicMonitor.log("받아쓰기 멈춤 \(job.m4a.lastPathComponent) → 대기열에 둠")
                // 모델 파일이 없어 멈췄으면 상태를 고쳐 같은 파일을 계속 다시 잡지 않게 한다.
                models.refresh()
            case .modelBroken:
                // 파일 탓이 아니니 대기열에 남긴다. 상태가 실패가 되어 루프가 멈춘다.
                models.markBroken()
            case .failed(let message):
                MicMonitor.log("오류 받아쓰기 \(job.m4a.lastPathComponent) \(message)")
                await Task.detached { Self.moveToFailed(job) }.value
            }
            isRunning = false
            currentAppName = nil
            fraction = 0
            refreshCount()
            scheduleKick()
        }
    }

    private func report(_ value: Double) {
        guard isRunning else { return }
        let clamped = min(max(value, 0), 1)
        // 1% 단위로만 다시 그린다.
        guard Int(clamped * 100) != Int(fraction * 100) else { return }
        fraction = clamped
    }

    private func refreshCount() {
        let count = Self.allJobs().count
        if count != waitingCount { waitingCount = count }
    }

    /// 대기열의 m4a·json 을 먼저 지우고 md 를 분류 폴더로 보낸다(안 되면 Outbox 로).
    /// 이 순서라 중간에 앱이 꺼져도 다음 시작 때 같은 파일을 다시 받아써 md 가 두 번 가지 않는다 — 남은 md 만 보낸다.
    private func deliver(_ job: Job, md: URL) async {
        guard StorageSettings.loadCategories().contains(where: { $0.id == job.categoryID }) else {
            MicMonitor.log("오류 받아쓰기 분류 없음 \(job.categoryID) \(job.m4a.lastPathComponent)")
            await Task.detached { Self.moveToFailed(job) }.value
            return
        }
        await Task.detached {
            try? FileManager.default.removeItem(at: job.m4a)
            try? FileManager.default.removeItem(at: RecordingMeta.jsonURL(for: job.m4a))
        }.value
        await sendMarkdown(md, categoryID: job.categoryID)
    }

    /// 대기열의 md 하나를 보낸다. 분류가 없거나 Outbox 로도 못 옮겨 대기열에 남으면 실패 폴더로 뺀다.
    private func sendMarkdown(_ md: URL, categoryID: Category.ID) async {
        if let category = StorageSettings.loadCategories().first(where: { $0.id == categoryID }) {
            await delivery.send(md, category: category, fileName: md.lastPathComponent)
        } else {
            MicMonitor.log("오류 받아쓰기 분류 없음 \(categoryID) \(md.lastPathComponent)")
        }
        await Task.detached {
            if FileManager.default.fileExists(atPath: md.path) { Self.moveToFailed([md]) }
        }.value
        MicMonitor.log("받아쓰기 끝 \(md.lastPathComponent)")
    }

    // MARK: - 대기열 파일(백그라운드)

    struct Job: Sendable {
        let m4a: URL
        let categoryID: Category.ID
    }

    nonisolated private static func m4aFiles(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "m4a" }
    }

    /// 실패 폴더를 뺀 분류 폴더 전부
    nonisolated private static func queueFolders() -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: queueURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return folders.filter { $0.lastPathComponent != failedURL.lastPathComponent && $0.hasDirectoryPath }
    }

    /// 분류 폴더 전부의 m4a
    nonisolated private static func allJobs() -> [Job] {
        queueFolders().flatMap { folder in m4aFiles(in: folder).map { Job(m4a: $0, categoryID: folder.lastPathComponent) } }
    }

    /// 옆에 m4a 가 없는 md(받아쓰기는 끝났고 보내기 전에 끊긴 것) 하나
    nonisolated private static func leftoverMarkdown() -> (md: URL, categoryID: Category.ID)? {
        let fm = FileManager.default
        for folder in queueFolders() {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for md in files where md.pathExtension == "md"
                && !fm.fileExists(atPath: md.deletingPathExtension().appendingPathExtension("m4a").path) {
                return (md, folder.lastPathComponent)
            }
        }
        return nil
    }

    /// 가장 오래된 것. 파일 이름이 녹음 시각(yyyy-MM-dd-HHmm)으로 시작한다.
    nonisolated private static func nextJob() -> Job? {
        allJobs().min { ($0.m4a.lastPathComponent, $0.m4a.path) < ($1.m4a.lastPathComponent, $1.m4a.path) }
    }

    nonisolated private static func copyToQueue(_ m4a: URL, meta: RecordingMeta, categoryID: Category.ID, fileName: String) {
        let fm = FileManager.default
        let folder = queueURL.appending(path: categoryID)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = Delivery.uniqueURL(in: folder, fileName: fileName)
            let json = RecordingMeta.jsonURL(for: target)
            // 메타를 먼저 둔다 — 대기열의 m4a 는 늘 메타가 옆에 있다.
            try meta.write(to: json)
            do {
                try fm.copyItem(at: m4a, to: target)
            } catch {
                try? fm.removeItem(at: json)
                throw error
            }
            MicMonitor.log("받아쓰기 대기 \(target.path)")
        } catch {
            MicMonitor.log("오류 받아쓰기 대기열 복사 \(m4a.lastPathComponent) \(error.localizedDescription)")
        }
    }

    /// 대기열의 m4a·json·md 를 실패 폴더로 옮긴다.
    nonisolated private static func moveToFailed(_ job: Job) {
        let base = job.m4a.deletingPathExtension()
        moveToFailed([job.m4a, base.appendingPathExtension("json"), base.appendingPathExtension("md")])
    }

    nonisolated private static func moveToFailed(_ files: [URL]) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: failedURL, withIntermediateDirectories: true)
        } catch {
            MicMonitor.log("오류 받아쓰기 실패 폴더 만들기 \(error.localizedDescription)")
            return
        }
        for file in files where fm.fileExists(atPath: file.path) {
            do {
                let moved = Delivery.uniqueURL(in: failedURL, fileName: file.lastPathComponent)
                try fm.moveItem(at: file, to: moved)
                MicMonitor.log("받아쓰기 실패 → \(moved.path)")
            } catch {
                MicMonitor.log("오류 받아쓰기 실패 폴더 옮기기 \(file.path) \(error.localizedDescription)")
            }
        }
    }

    nonisolated private static func runOnWorkQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            workQueue.async { continuation.resume(returning: work()) }
        }
    }
}

// MARK: - 받아쓰기(전용 큐)

extension Transcriber {
    enum Outcome: Sendable {
        /// 대기열 폴더에 쓴 md
        case done(URL)
        /// 녹음이 시작돼 멈췄다(대기열에 그대로 둔다).
        case interrupted
        /// 모델 파일을 못 열었다(파일은 대기열에 그대로 두고 루프를 멈춘다).
        case modelBroken
        case failed(String)
    }

    /// 받아쓴 한 줄. speaker 는 좌우로 나눈 녹음에서만 있다(0 나, 1 상대).
    private struct Line {
        let time: Double
        let speaker: Int?
        let text: String
        /// 같은 시각·같은 화자일 때 나온 순서
        let order: Int
    }

    /// 원래 녹음 시간축의 표본 범위 [start, end)
    private struct Span {
        var start: Int
        var end: Int
        var count: Int { end - start }
    }

    nonisolated private static let sampleRate = Double(WHISPER_SAMPLE_RATE)
    /// 말한 구간을 이어 붙인 한 조각의 최대 길이. whisper 창(30초)보다 조금 짧게
    nonisolated private static let maxChunkSeconds = 28.0
    /// 말한 구간 앞뒤 여유
    nonisolated private static let speechPadSeconds = 0.2
    nonisolated private static let maxThreads = 8
    /// 디코드할 때 한 번에 읽는 프레임 수
    nonisolated private static let readFrames: AVAudioFrameCount = 65_536
    /// whisper_full_get_segment_t0 의 단위(10ms)
    nonisolated private static let centisecond = 0.01

    /// ggml 로그는 오류만 감지 로그에 남긴다. 한 번만 건다.
    nonisolated private static let installLogger: Void = {
        whisper_log_set({ level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            // Core ML 인코더는 따로 받지 않는다 — 못 찾으면 whisper 가 Metal 로 넘어가니 오류가 아니다.
            let message = String(cString: text)
            if message.contains("Core ML") { return }
            MicMonitor.log("오류 whisper \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }, nil)
    }()

    /// 파일 하나를 받아써 같은 폴더에 md 를 쓴다. 조각 사이마다 interrupt 를 본다.
    nonisolated private static func transcribe(_ job: Job, meta: RecordingMeta, interrupt: InterruptFlag,
                                               progress: @Sendable (Double) -> Void) -> Outcome {
        _ = installLogger
        // 받아쓰는 사이 모델을 지웠으면 실패로 치지 않고 남겨 둔다(모델을 받으면 다시 한다).
        guard ModelStore.isInstalled else { return .interrupted }
        do {
            let info = try AVAudioFile(forReading: job.m4a)
            let channels = Int(info.processingFormat.channelCount)
            let seconds = Double(info.length) / info.processingFormat.sampleRate
            // 좌우로 나눈 녹음은 한 채널씩 따로 디코드·처리한다(메모리 절약). 아니면 섞어서 한 번, 화자 없음
            let passes: [(channel: Int?, speaker: Int?)] = meta.split == true && channels == 2 ? [(0, 0), (1, 1)] : [(nil, nil)]
            let threads = Int32(min(maxThreads, ProcessInfo.processInfo.activeProcessorCount))

            guard let ctx = whisper_init_from_file_with_params(ModelStore.whisperModel.localURL.path, whisper_context_default_params()) else {
                return ModelStore.isInstalled ? .modelBroken : .interrupted
            }
            defer { whisper_free(ctx) }
            var vadParams = whisper_vad_default_context_params()
            vadParams.n_threads = threads
            vadParams.use_gpu = false
            guard let vad = whisper_vad_init_from_file_with_params(ModelStore.vadModel.localURL.path, vadParams) else {
                return ModelStore.isInstalled ? .modelBroken : .interrupted
            }
            defer { whisper_vad_free(vad) }

            var language = TranscriptionSettings.languageCode
            var lines: [Line] = []
            let total = max(seconds * Double(passes.count), 1)
            for (index, pass) in passes.enumerated() {
                if interrupt.isSet { return .interrupted }
                guard let samples = try decode(job.m4a, channel: pass.channel, interrupt: interrupt) else { return .interrupted }
                let chunks = try speechChunks(samples, vad: vad)
                if interrupt.isSet { return .interrupted }
                for chunk in chunks {
                    if interrupt.isSet { return .interrupted }
                    let segments = try run(ctx, samples: samples, chunk: chunk, language: language, threads: threads)
                    // auto 면 첫 조각에서 정한 언어를 그 파일 끝까지 쓴다.
                    if language == TranscriptionSettings.autoLanguage, let detected = whisper_lang_str(whisper_full_lang_id(ctx)) {
                        language = String(cString: detected)
                        MicMonitor.log("받아쓰기 언어 감지 \(language)")
                    }
                    for segment in segments {
                        lines.append(Line(time: Double(chunk.start) / sampleRate + segment.t0, speaker: pass.speaker,
                                          text: segment.text, order: lines.count))
                    }
                    progress((Double(index) * seconds + Double(chunk.end) / sampleRate) / total)
                }
            }
            // 두 채널 줄은 시각순으로 섞는다(같으면 나 먼저).
            lines.sort { ($0.time, $0.speaker ?? 0, $0.order) < ($1.time, $1.speaker ?? 0, $1.order) }
            let duration = meta.duration > 0 ? meta.duration : Int(seconds.rounded())
            let md = job.m4a.deletingPathExtension().appendingPathExtension("md")
            try render(title: job.m4a.deletingPathExtension().lastPathComponent, meta: meta, duration: duration, lines: lines)
                .write(to: md, atomically: true, encoding: .utf8)
            return .done(md)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 조각 하나를 whisper 로 돌린다. 줄 시각은 조각 시작 기준 초
    nonisolated private static func run(_ ctx: OpaquePointer, samples: [Float], chunk: Span, language: String,
                                        threads: Int32) throws -> [(t0: Double, text: String)] {
        // 내장 VAD(params.vad)는 쓰지 않는다 — 무음을 빼고 이은 시간축이라 시각이 밀린다.
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = threads
        params.no_context = true
        params.suppress_nst = true
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        let status = language.withCString { code -> Int32 in
            params.language = code
            return samples.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return -1 }
                return whisper_full(ctx, params, base + chunk.start, Int32(chunk.count))
            }
        }
        guard status == 0 else { throw TranscriptionError("whisper_full \(status)") }
        var segments: [(t0: Double, text: String)] = []
        for index in 0..<whisper_full_n_segments(ctx) {
            guard let raw = whisper_full_get_segment_text(ctx, index) else { continue }
            let text = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            // 빈 글·문장부호만 있는 줄은 버린다.
            guard text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { continue }
            segments.append((Double(whisper_full_get_segment_t0(ctx, index)) * centisecond, text))
        }
        return segments
    }

    /// VAD 로 말한 구간을 찾아 앞뒤 0.2초씩 늘리고, 이어서 28초 이하 조각으로 묶는다(28초 넘는 한 구간은 그대로 한 조각).
    /// 구간 사이 무음도 조각 안에 그대로 둬서 원래 시간축을 지킨다.
    nonisolated private static func speechChunks(_ samples: [Float], vad: OpaquePointer) throws -> [Span] {
        guard !samples.isEmpty else { return [] }
        let found = samples.withUnsafeBufferPointer { buffer in
            whisper_vad_segments_from_samples(vad, whisper_vad_default_params(), buffer.baseAddress, Int32(buffer.count))
        }
        guard let found else { throw TranscriptionError("VAD 실패") }
        defer { whisper_vad_free_segments(found) }
        let pad = Int(speechPadSeconds * sampleRate)
        let maxCount = Int(maxChunkSeconds * sampleRate)
        var chunks: [Span] = []
        var current: Span?
        for index in 0..<whisper_vad_segments_n_segments(found) {
            // VAD 구간 시각은 센티초(1/100초) — whisper.cpp src/whisper.cpp 의 samples_to_cs 로 바꿔 담는다.
            let t0 = Double(whisper_vad_segments_get_segment_t0(found, index)) * centisecond
            let t1 = Double(whisper_vad_segments_get_segment_t1(found, index)) * centisecond
            let start = max(Int((t0 * sampleRate).rounded()) - pad, 0)
            let end = min(Int((t1 * sampleRate).rounded()) + pad, samples.count)
            guard end > start else { continue }
            if var span = current, end - span.start <= maxCount {
                span.end = max(span.end, end)
                current = span
            } else {
                // 앞 조각과 패딩이 겹치면 겹친 앞부분을 뺀다(같은 소리를 두 번 받아쓰지 않게).
                let previousEnd = current?.end ?? chunks.last?.end ?? 0
                if let current { chunks.append(current) }
                let trimmed = max(start, previousEnd)
                current = end > trimmed ? Span(start: trimmed, end: end) : nil
            }
        }
        if let current { chunks.append(current) }
        return chunks
    }

    /// m4a 를 16kHz 모노 Float32 로 읽는다. channel 이 nil 이면 모든 채널을 섞는다. 읽는 사이 녹음이 시작되면 nil
    nonisolated private static func decode(_ url: URL, channel: Int?, interrupt: InterruptFlag) throws -> [Float]? {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readFrames),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: readFrames),
              let output = AVAudioPCMBuffer(pcmFormat: outFormat,
                                            frameCapacity: AVAudioFrameCount(Double(readFrames) * sampleRate / format.sampleRate) + 1_024)
        else { throw TranscriptionError("받아쓰기 디코드 준비 실패") }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * sampleRate / format.sampleRate) + 1_024)
        var ended = false
        var interrupted = false
        var readError: Error?
        while true {
            output.frameLength = 0
            var convertError: NSError?
            let status = converter.convert(to: output, error: &convertError) { _, inputStatus in
                // 2시간 회의는 디코드만 수십 초라 블록마다 본다.
                if interrupt.isSet {
                    interrupted = true
                    ended = true
                }
                // 끝에서 read 를 부르면 던질 수 있어 위치로 먼저 본다.
                guard !ended, file.framePosition < file.length else {
                    ended = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: readFrames)
                } catch {
                    readError = error
                    ended = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let frames = Int(input.frameLength)
                guard frames > 0, let source = input.floatChannelData, let target = mono.floatChannelData else {
                    ended = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if let channel, channel < channels {
                    target[0].update(from: source[channel], count: frames)
                } else {
                    let scale = 1 / Float(channels)
                    for frame in 0..<frames {
                        var sum: Float = 0
                        for index in 0..<channels { sum += source[index][frame] }
                        target[0][frame] = sum * scale
                    }
                }
                mono.frameLength = AVAudioFrameCount(frames)
                inputStatus.pointee = .haveData
                return mono
            }
            if status == .error { throw convertError ?? TranscriptionError("받아쓰기 변환 실패") }
            if let data = output.floatChannelData, output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            }
            if status == .endOfStream || status == .inputRanDry { break }
        }
        if let readError { throw readError }
        return interrupted ? nil : samples
    }

    nonisolated private static func render(title: String, meta: RecordingMeta, duration: Int, lines: [Line]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let me = TranscriptionSettings.speakerMe
        // 오른쪽 화자는 저장 창의 참석자. 비었으면 "상대"
        let attendees = (meta.attendees ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let other = attendees.isEmpty ? String(localized: "상대") : attendees.joined(separator: ", ")
        var text = "# \(title)\n\n"
        text += "- \(String(localized: "날짜")): \(formatter.string(from: meta.startedAt))\n"
        text += "- \(String(localized: "길이")): \(duration / 3600):\(String(format: "%02d:%02d", duration / 60 % 60, duration % 60))\n"
        text += "- \(String(localized: "앱")): \(meta.appName)\n"
        if !attendees.isEmpty { text += "- \(String(localized: "참석자")): \(attendees.joined(separator: ", "))\n" }
        for line in lines {
            let seconds = Int(line.time.rounded())
            let stamp = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            switch line.speaker {
            case 0?: text += "\n**[\(stamp)] \(me):** \(line.text)\n"
            case 1?: text += "\n**[\(stamp)] \(other):** \(line.text)\n"
            default: text += "\n**[\(stamp)]** \(line.text)\n"
            }
        }
        return text
    }
}

/// 녹음이 시작됐는지 알리는 깃발. 메인에서 세우고 받아쓰기 큐에서 본다.
final class InterruptFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }

    func reset() { lock.withLock { value = false } }
}

struct TranscriptionError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
