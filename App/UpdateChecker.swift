import AppKit
import UserNotifications

/// GitHub 최신 릴리스를 보고 새 버전이 있으면 알린다. 설치는 하지 않는다 — DMG 를 받아 덮어쓴다.
/// 공증이 없어서 자동 설치(Sparkle)는 업데이트마다 권한을 다시 묻게 된다. 공증을 하면 그때 바꾼다.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable {
        let version: String
        /// DMG 가 없으면 릴리스 페이지
        let downloadURL: URL
    }

    /// 지금보다 새 버전. 없거나 아직 모르면 nil
    @Published private(set) var available: Release?

    nonisolated static let downloadKey = "updateDownloadURL"
    private static let apiURL = URL(string: "https://api.github.com/repos/yootaebong/earshot/releases/latest")!
    /// 같은 버전은 한 번만 알린다.
    private static let notifiedKey = "updateNotifiedVersion"
    private static let interval: TimeInterval = 24 * 60 * 60

    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// 시작 1분 뒤 한 번, 그다음 하루마다
    func start() {
        Task {
            try? await Task.sleep(for: .seconds(60))
            await check(userInitiated: false)
        }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(userInitiated: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 메뉴 "업데이트 확인…" — 결과를 창으로 알려 준다.
    func checkFromMenu() {
        Task { await check(userInitiated: true) }
    }

    func download() {
        guard let available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["update-\(available.version)"])
        NSWorkspace.shared.open(available.downloadURL)
    }

    private func check(userInitiated: Bool) async {
        let release: Release
        do {
            release = try await Self.fetchLatest()
        } catch {
            MicMonitor.log("오류 업데이트 확인: \(error.localizedDescription)")
            if userInitiated { Self.alert(String(localized: "업데이트를 확인하지 못했어요"), String(localized: "인터넷 연결을 확인하고 다시 시도해 주세요.")) }
            return
        }
        guard Self.isNewer(release.version, than: Self.currentVersion) else {
            if available != nil { available = nil }
            // 이미 깐 버전의 알림이 남아 있으면 치운다.
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["update-\(release.version)"])
            if userInitiated { Self.alert(String(localized: "최신 버전이에요"), String(localized: "EarShot \(Self.currentVersion)")) }
            return
        }
        if available != release { available = release }
        MicMonitor.log("새 버전 \(release.version) (지금 \(Self.currentVersion))")
        // 메뉴로 이미 본 버전은 자동 확인 때 다시 알리지 않는다.
        let notified = UserDefaults.standard.string(forKey: Self.notifiedKey) == release.version
        UserDefaults.standard.set(release.version, forKey: Self.notifiedKey)
        if userInitiated {
            let alert = NSAlert()
            alert.messageText = String(localized: "새 버전 \(release.version)이 있어요")
            alert.informativeText = String(localized: "DMG 를 받아 열고 EarShot 을 Applications 로 끌어 덮어쓰세요. 지금은 \(Self.currentVersion)이에요.")
            alert.addButton(withTitle: String(localized: "받기"))
            alert.addButton(withTitle: String(localized: "나중에"))
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { download() }
        } else if !notified {
            Self.notify(release)
        }
    }

    private static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: apiURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("EarShot/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 403 은 레이트 리밋(비인증 시간당 60회), 404 는 릴리스 없음
        guard status == 200 else {
            MicMonitor.log("업데이트 확인 HTTP \(status)")
            throw URLError(.badServerResponse)
        }
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Latest: Decodable { let tag_name: String; let html_url: URL; let assets: [Asset] }
        let latest = try JSONDecoder().decode(Latest.self, from: data)
        let version = latest.tag_name.hasPrefix("v") ? String(latest.tag_name.dropFirst()) : latest.tag_name
        let dmg = latest.assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.browser_download_url
        return Release(version: version, downloadURL: dmg ?? latest.html_url)
    }

    /// "1.10.0" > "1.9.2". 숫자가 아닌 칸은 0
    nonisolated static func isNewer(_ version: String, than current: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }

    /// 누르면 DMG 를 받는다(NotificationRouter 가 downloadKey 를 본다).
    private static func notify(_ release: Release) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "EarShot \(release.version)이 나왔어요")
        content.body = String(localized: "눌러서 받기 · 지금은 \(currentVersion)")
        content.userInfo = [downloadKey: release.downloadURL.absoluteString]
        let request = UNNotificationRequest(identifier: "update-\(release.version)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { MicMonitor.log("오류 알림 보내기: \(error.localizedDescription)") }
        }
    }
}
