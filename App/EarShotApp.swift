import SwiftUI
import UserNotifications

@main
struct EarShotApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    init() {
        // 로그인 실행(launchd)과 직접 실행이 겹치면 잠금을 못 잡은 쪽이 조용히 물러난다(exit 0 이라 KeepAlive 도 다시 안 띄운다).
        // launchd 로 뜬 인스턴스는 NSRunningApplication 목록에 안 보일 수 있어 파일 잠금으로 가린다.
        if !Self.acquireInstanceLock() { exit(0) }
        // 직접 실행했는데 로그인 항목이 올라가 있으면 launchd 쪽으로 넘긴다 — 그래야 죽었을 때 다시 켜진다.
        if LoginItem.handOffToLaunchdIfNeeded() { exit(0) }
        // 분류 기본값을 로그인 항목 설정(loginItemConfigured)보다 먼저 정한다 — 그 키로 예전 사용자를 가린다.
        _ = StorageSettings.loadCategories()
        // 꺼져 있을 때 누른 알림도 받으려면 실행이 끝나기 전에 붙여야 한다.
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        let monitor = MicMonitor()
        let recorder = RecordingController(monitor: monitor)
        let delivery = Delivery()
        AppDelegate.statusMenu = StatusMenu(
            monitor: monitor,
            recorder: recorder,
            loginItem: LoginItem(),
            delivery: delivery,
            saveQueue: SaveQueue(delivery: delivery),
            autoRecorder: AutoRecorder(monitor: monitor, recorder: recorder)
        )
    }

    /// 프로세스가 살아 있는 동안 잠금을 쥔다(fd 는 일부러 닫지 않는다). 죽으면 커널이 풀어 준다.
    private static func acquireInstanceLock() -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/EarShot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appending(path: "instance.lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }

    // 메뉴 막대는 StatusMenu(AppKit)가 그린다. 앱에는 창 장면이 하나는 있어야 해서 빈 설정 장면을 둔다.
    var body: some Scene {
        Settings { EmptyView() }
            // 빈 설정 창이 ⌘, 로 뜨지 않게
            .commands { CommandGroup(replacing: .appSettings) {} }
    }
}

/// 실행이 끝나면 메뉴 막대 아이콘을 단다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 녹음·보내기 객체를 쥐고 있다(앱이 끝날 때까지).
    @MainActor static var statusMenu: StatusMenu?

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        Self.statusMenu?.install()
    }
}
