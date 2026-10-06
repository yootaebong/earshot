import AppKit

/// 분류한 녹음을 분류별 폴더로 보낸다. 폴더가 없거나(NAS 안 붙음) 복사가 틀어지면 Outbox 에 두고
/// 60초마다·볼륨이 붙을 때 다시 보낸다. 파일 작업은 직렬 큐 하나에서만 한다(같은 이름 고르기가 겹치지 않게).
@MainActor
final class Delivery: ObservableObject {
    /// Outbox 에서 보낼 차례를 기다리는 파일 수
    @Published private(set) var waitingCount = 0
    /// 여러 번 복사에 실패해 Outbox/실패 로 뺀 파일 수
    @Published private(set) var failedCount = 0

    nonisolated static let outboxURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/EarShot/Outbox")
    /// 다시 보내도 계속 복사가 틀어지는 파일을 두는 곳. 자동으로 다시 보내지 않는다.
    nonisolated static let failedURL: URL = outboxURL.appending(path: "실패")
    private static let retryInterval: TimeInterval = 60
    /// 폴더 문제가 아닌 복사 실패가 같은 파일에 이만큼 쌓이면 실패 폴더로 뺀다.
    nonisolated private static let maxCopyFailures = 5
    nonisolated private static let queue = DispatchQueue(label: "io.taebong.EarShot.delivery")
    /// 파일 경로별 복사 실패 횟수. 직렬 큐에서만 만진다(메모리에만 — 앱을 다시 켜면 처음부터 센다).
    nonisolated(unsafe) private static var copyFailures: [String: Int] = [:]

    private var timer: Timer?
    private var mountObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    init() {
        for category in StorageSettings.loadCategories() {
            try? FileManager.default.createDirectory(at: Self.outbox(category), withIntermediateDirectories: true)
        }
        waitingCount = Self.countOutbox()
        failedCount = Self.countFailed()
        // 종료 때 보내던 복사가 중간에 끊기지 않게 큐를 비우고 끝낸다. queue nil 이라 알림을 보낸 메인에서 바로 돈다.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            Self.drain()
        }
        let timer = Timer(timeInterval: Self.retryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.retry() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.retry() }
        }
        retry()
    }

    /// Pending 의 m4a(+json)를 category 폴더에 fileName 으로 보낸다. 안 되면 Outbox 로 옮긴다.
    func send(_ m4a: URL, category: Category, fileName: String) async {
        await Self.run { Self.deliver(m4a, category: category, fileName: fileName) }
        await refreshCounts()
    }

    /// Outbox 에 남은 것을 다시 보낸다.
    func retry() {
        Task {
            await Self.run { Self.flushOutbox() }
            await refreshCounts()
        }
    }

    private func refreshCounts() async {
        let counts = await Self.run { (waiting: Self.countOutbox(), failed: Self.countFailed()) }
        waitingCount = counts.waiting
        failedCount = counts.failed
    }

    /// 큐에 걸린 파일 작업이 다 끝날 때까지 기다린다(앱 종료 때).
    nonisolated static func drain() {
        queue.sync {}
    }

    // MARK: - 파일 작업(직렬 큐)

    nonisolated private static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    nonisolated private static func outbox(_ category: Category) -> URL {
        outbox(id: category.id)
    }

    nonisolated private static func outbox(id: Category.ID) -> URL {
        outboxURL.appending(path: id)
    }

    /// 실패 폴더를 뺀 Outbox 하위 폴더 전부. 목록에서 지운 분류 폴더도 들어간다(남은 파일을 대기 수에 센다).
    nonisolated private static func outboxFolders() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: outboxURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { url in
            url.lastPathComponent != failedURL.lastPathComponent
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    nonisolated private static func countOutbox() -> Int {
        outboxFolders().reduce(0) { $0 + m4aFiles(in: $1).count }
    }

    /// 이 분류의 Outbox 에서 보낼 차례를 기다리는 파일 수(설정 창에서 지워도 되는지 볼 때)
    nonisolated static func waitingCount(categoryID: Category.ID) -> Int {
        m4aFiles(in: outbox(id: categoryID)).count
    }

    nonisolated private static func countFailed() -> Int {
        m4aFiles(in: failedURL).count
    }

    /// 복사 실패를 하나 센다. maxCopyFailures 에 닿으면 실패 폴더로 옮기고 true.
    nonisolated private static func recordCopyFailure(_ file: URL, error: Error) -> Bool {
        // NAS 꽉 참·권한·네트워크 흔들림은 고치면 풀리니 세지 않는다(세면 몇 분 만에 격리돼 영영 안 간다).
        if let posix = error as? POSIXError, transientCodes.contains(posix.code) { return false }
        let count = copyFailures[file.path, default: 0] + 1
        guard count >= maxCopyFailures else {
            copyFailures[file.path] = count
            return false
        }
        copyFailures[file.path] = nil
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: failedURL, withIntermediateDirectories: true)
            let moved = uniqueURL(in: failedURL, fileName: file.lastPathComponent)
            try fm.moveItem(at: file, to: moved)
            MicMonitor.log("오류 보내기 \(count)번 실패 \(error.localizedDescription) → \(moved.path)")
        } catch let moveError {
            MicMonitor.log("오류 보내기 \(count)번 실패 \(error.localizedDescription), 실패 폴더 옮기기 실패 \(moveError.localizedDescription)")
        }
        return true
    }

    nonisolated private static let transientCodes: Set<POSIXErrorCode> = [
        .ENOSPC, .EDQUOT, .EACCES, .EPERM, .EIO, .ETIMEDOUT, .ENETDOWN, .ENETUNREACH, .ENOTCONN, .EHOSTUNREACH, .ECONNRESET, .ESTALE,
    ]

    nonisolated private static func m4aFiles(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 없으면 만들어도 되는 경로인지. 홈 폴더 아래만 만들고, 외장·네트워크 볼륨(/Volumes)과
    /// 클라우드 동기화 폴더(~/Library/CloudStorage)는 안 붙어 있으면 만들지 않고 붙을 때까지 기다린다.
    nonisolated private static func canCreate(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") && !path.hasPrefix(home + "/Library/CloudStorage/")
    }

    /// 보낼 폴더가 있고 쓸 수 있으면 그 URL, 아니면 이유. 로컬 경로는 없으면 만든다.
    nonisolated private static func destination(_ category: Category) -> Result<URL, DeliveryError> {
        let path = category.path
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: path), canCreate(path) {
            do {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                MicMonitor.log("폴더 만듦 \(path)")
            } catch {
                return .failure(DeliveryError("\(category.name) 폴더 만들기 실패 \(path) \(error.localizedDescription)"))
            }
        }
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(DeliveryError("\(category.name) 폴더 없음 \(path)"))
        }
        guard FileManager.default.isWritableFile(atPath: path) else {
            return .failure(DeliveryError("\(category.name) 폴더 쓰기 불가 \(path)"))
        }
        return .success(URL(filePath: path, directoryHint: .isDirectory))
    }

    nonisolated private static func deliver(_ m4a: URL, category: Category, fileName: String) {
        let fm = FileManager.default
        // 저장 창이 뜬 뒤 설정에서 경로를 바꿨을 수 있으니 지금 목록에서 다시 찾는다(지운 분류면 받은 그대로).
        let category = StorageSettings.loadCategories().first { $0.id == category.id } ?? category
        let json = RecordingMeta.jsonURL(for: m4a)
        // 폴더 없음·쓰기 불가는 붙으면 풀리니 세지 않는다. 그 뒤(복사)에서 틀어진 것만 센다.
        var copyAttempted = false
        do {
            let folder = try destination(category).get()
            copyAttempted = true
            let sent = try copyVerified(m4a, to: folder, fileName: fileName)
            try? fm.removeItem(at: m4a)
            try? fm.removeItem(at: json)
            MicMonitor.log("보냄 \(sent.path)")
        } catch {
            do {
                try fm.createDirectory(at: outbox(category), withIntermediateDirectories: true)
                let held = uniqueURL(in: outbox(category), fileName: fileName)
                try fm.moveItem(at: m4a, to: held)
                try? fm.removeItem(at: json)
                MicMonitor.log("보류 \(error.localizedDescription) → \(held.path)")
                // 이후 Outbox 재시도와 이어 세도록 옮긴 경로로 센다.
                if copyAttempted { _ = recordCopyFailure(held, error: error) }
            } catch let moveError {
                // Outbox 로도 못 옮기면 Pending 에 그대로 둔다(분류 안 됨으로 남음).
                MicMonitor.log("보류 \(error.localizedDescription), Outbox 옮기기 실패 \(moveError.localizedDescription) → Pending 에 둠")
            }
        }
    }

    nonisolated private static func flushOutbox() {
        // 사용자가 Outbox 에서 지운 파일의 횟수는 버린다(같은 이름이 다시 오면 처음부터 센다).
        let present = Set(outboxFolders().flatMap { m4aFiles(in: $0).map(\.path) })
        copyFailures = copyFailures.filter { present.contains($0.key) }
        let categories = StorageSettings.loadCategories()
        moveOrphans(keeping: Set(categories.map(\.id)))
        // 목록에 있는 분류만 다시 보낸다.
        for category in categories {
            // 폴더가 없으면 조용히 다음 때 다시(60초마다 같은 보류 로그를 쌓지 않는다).
            guard case .success(let folder) = destination(category) else { continue }
            removeLeftoverParts(in: folder)
            let files = m4aFiles(in: outbox(category))
            for file in files {
                do {
                    let sent = try copyVerified(file, to: folder, fileName: file.lastPathComponent)
                    try? FileManager.default.removeItem(at: file)
                    copyFailures[file.path] = nil
                    MicMonitor.log("보냄 \(sent.path)")
                } catch {
                    // 폴더 확인은 위에서 끝났으니 여기 실패는 복사 실패다.
                    if !recordCopyFailure(file, error: error) {
                        MicMonitor.log("보류 \(file.lastPathComponent) \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// 지운 분류의 Outbox 에 남은 파일은 보낼 곳이 없으니 실패 폴더로 옮겨 "보내지 못한 파일"에 보이게 한다.
    /// (전송 중에 그 분류를 지우면 복사 실패 파일이 여기로 온다.)
    nonisolated private static func moveOrphans(keeping ids: Set<Category.ID>) {
        let fm = FileManager.default
        for folder in outboxFolders() where !ids.contains(folder.lastPathComponent) {
            for file in m4aFiles(in: folder) {
                do {
                    try fm.createDirectory(at: failedURL, withIntermediateDirectories: true)
                    let moved = uniqueURL(in: failedURL, fileName: file.lastPathComponent)
                    try fm.moveItem(at: file, to: moved)
                    copyFailures[file.path] = nil
                    MicMonitor.log("지운 분류 \(folder.lastPathComponent) 의 대기 파일 → \(moved.path)")
                } catch {
                    MicMonitor.log("오류 지운 분류 대기 파일 옮기기 실패 \(file.path) \(error.localizedDescription)")
                }
            }
        }
    }

    /// 복사 중 임시 파일 접두사. NAS 쪽 봇은 "." 로 시작하는 파일을 무시한다.
    nonisolated private static let partPrefix = ".earshot-"
    nonisolated private static let partExtension = "part"

    /// 지난번에 끊긴 복사가 남긴 .earshot-*.part 를 지운다.
    nonisolated private static func removeLeftoverParts(in folder: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(partPrefix) && file.pathExtension == partExtension {
            try? FileManager.default.removeItem(at: file)
            MicMonitor.log("잔재 지움 \(file.path)")
        }
    }

    /// .part 로 복사 → 크기 확인 → 최종 이름으로 rename. 어느 단계든 실패하면 .part 를 지우고 던진다.
    /// 원본은 건드리지 않는다(지우는 건 부른 쪽이 성공 뒤에).
    nonisolated private static func copyVerified(_ source: URL, to folder: URL, fileName: String) throws -> URL {
        let fm = FileManager.default
        let part = folder.appending(path: "\(partPrefix)\(UUID().uuidString).\(partExtension)")
        do {
            // 내용만 복사한다. NAS(SMB)는 com.apple.provenance 같은 확장 속성을 거부해 copyItem 이 통째로 실패한다.
            if copyfile(source.path, part.path, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_EXCL)) != 0 {
                let code = errno
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            let sourceSize = (try? fm.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? nil
            let partSize = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? nil
            guard let sourceSize, sourceSize == partSize else {
                throw DeliveryError("크기 다름 \(sourceSize.map(String.init) ?? "?")≠\(partSize.map(String.init) ?? "?")")
            }
            let target = uniqueURL(in: folder, fileName: fileName)
            try fm.moveItem(at: part, to: target)
            return target
        } catch {
            try? fm.removeItem(at: part)
            throw error
        }
    }

    /// 같은 이름이 있으면 "-2", "-3" 을 붙인다.
    nonisolated static func uniqueURL(in folder: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var url = folder.appending(path: fileName)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base)-\(number).\(ext)")
            number += 1
        }
        return url
    }

    // MARK: - 파일 이름

    /// 파일 이름 UTF-8 상한(확장자 포함)
    nonisolated private static let maxNameBytes = 200
    /// uniqueURL 이 붙이는 "-N" 자리
    nonisolated private static let suffixReserveBytes = 6
    /// 파일 이름에 못 쓰는 문자(NAS·윈도우 공유 기준)
    nonisolated private static let forbidden = CharacterSet(charactersIn: "/:\\*?\"<>|").union(.controlCharacters)

    /// "yyyy-MM-dd-HHmm-<앱>[-<주제>][-참석 a,b].m4a". 못 쓰는 문자는 지우고 공백은 하나로.
    /// "-N" 자리까지 200바이트를 넘으면 참석자 → 주제 → 앱 순으로 끝 글자부터 잘라 맞춘다.
    nonisolated static func fileName(startedAt: Date, appName: String, topic: String, attendees: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let stamp = formatter.string(from: startedAt)
        let cleanedApp = clean(appName)
        var app = cleanedApp.isEmpty ? RecordingController.globalName : cleanedApp
        var topic = clean(topic)
        var names = attendees.split(separator: ",").map { clean(String($0)) }.filter { !$0.isEmpty }.joined(separator: ",")
        // 한국어 값 "참석" 은 NAS 쪽 봇이 읽으니 바꾸지 않는다.
        let attendeesPrefix = String(localized: "참석", comment: "파일 이름에서 참석자 앞에 붙는 말")

        func build() -> String {
            var parts = [stamp, app]
            if !topic.isEmpty { parts.append(topic) }
            if !names.isEmpty { parts.append("\(attendeesPrefix) \(names)") }
            return parts.joined(separator: "-") + ".m4a"
        }
        let limit = maxNameBytes - suffixReserveBytes
        while build().utf8.count > limit {
            if !names.isEmpty {
                names = trimTail(String(names.dropLast()))
            } else if !topic.isEmpty {
                topic = trimTail(String(topic.dropLast()))
            } else if app.count > 1 {
                app = trimTail(String(app.dropLast()))
            } else {
                break
            }
        }
        return build()
    }

    nonisolated private static func clean(_ text: String) -> String {
        let kept = String(String.UnicodeScalarView(text.unicodeScalars.filter { !forbidden.contains($0) }))
        return kept.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 자른 끝에 남은 공백·쉼표를 지운다.
    nonisolated private static func trimTail(_ text: String) -> String {
        var text = text
        while let last = text.last, last.isWhitespace || last == "," { text.removeLast() }
        return text
    }
}

struct DeliveryError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
