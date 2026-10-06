import Foundation
import ServiceManagement

/// 로그인 시 실행 + 죽으면 다시 켜기. ~/Library/LaunchAgents 에 KeepAlive(SuccessfulExit=false) plist 를 두고 launchctl 로 올린다.
/// SMAppService.agent 는 정식 인증서 없는 빌드를 Launch Constraint 로 막아(EX_CONFIG) 쓰지 않는다.
/// 메뉴 "종료"는 정상 종료(0)라 다시 켜지지 않는다.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = false

    nonisolated private static let label = "io.taebong.EarShot"
    /// 처음 실행 때 한 번만 기본값(켬)으로 등록한다. 이후엔 사용자가 고른 대로 둔다.
    private static let configuredKey = "loginItemConfigured"

    nonisolated private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist")
    }

    init() {
        // 예전 빌드가 SMAppService 로 등록해 둔 것은 걷어 낸다.
        let legacy = SMAppService.agent(plistName: "io.taebong.EarShot.agent.plist")
        if legacy.status != .notRegistered && legacy.status != .notFound { try? legacy.unregister() }

        if !UserDefaults.standard.bool(forKey: Self.configuredKey) {
            UserDefaults.standard.set(true, forKey: Self.configuredKey)
            setEnabled(true)
        } else if Self.installedProgram() != nil, Self.installedProgram() != Bundle.main.executablePath {
            // 앱 위치가 바뀌었으면 새 경로로 다시 쓴다.
            setEnabled(true)
        }
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        let domain = "gui/\(getuid())"
        // launchd 가 띄운 나를 bootout 하면 내 프로세스가 죽는다. 그땐 plist 만 고치고 다음 로그인부터 적용한다.
        let launchedByLaunchd = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == Self.label
        if !launchedByLaunchd { Self.launchctl(["bootout", "\(domain)/\(Self.label)"]) }
        if enabled {
            let plist: [String: Any] = [
                "Label": Self.label,
                "Program": Bundle.main.executablePath ?? "",
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
                "ProcessType": "Interactive",
            ]
            do {
                try FileManager.default.createDirectory(at: Self.plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: Self.plistURL)
                if launchedByLaunchd {
                    MicMonitor.log("로그인 시 실행 등록(plist 만, 다음 로그인부터 적용)")
                } else {
                    // 지금 떠 있는 나와 겹치면 새로 뜬 쪽이 인스턴스 잠금을 못 잡고 exit(0) 한다.
                    let status = Self.launchctl(["bootstrap", domain, Self.plistURL.path])
                    if status == 0 {
                        MicMonitor.log("로그인 시 실행 등록 launchctl=\(status)")
                    } else {
                        // 올라가지 않은 plist 를 남기면 켜짐으로 보이므로 지운다.
                        try? FileManager.default.removeItem(at: Self.plistURL)
                        MicMonitor.log("오류 로그인 시 실행 등록 launchctl bootstrap=\(status) → plist 지움")
                    }
                }
            } catch {
                MicMonitor.log("오류 로그인 시 실행 등록: \(error.localizedDescription)")
            }
        } else {
            try? FileManager.default.removeItem(at: Self.plistURL)
            MicMonitor.log(launchedByLaunchd ? "로그인 시 실행 해제(다음 로그인부터 적용)" : "로그인 시 실행 해제")
        }
        refresh()
    }

    /// launchd 가 띄운 게 아니고 작업이 올라가 있으면, 잠깐 뒤 launchd 로 다시 띄우도록 걸어 두고 true(호출자가 exit(0)).
    /// plist 가 다른 위치의 앱을 가리키면 넘기지 않는다(옛 빌드가 대신 떠 버린다).
    nonisolated static func handOffToLaunchdIfNeeded() -> Bool {
        guard ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != label,
              let program = installedProgram(), program == Bundle.main.executablePath,
              launchctl(["print", "gui/\(getuid())/\(label)"]) == 0 else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /bin/launchctl kickstart gui/\(getuid())/\(label)"]
        do { try process.run() } catch { return false }
        return true
    }

    private func refresh() {
        isEnabled = FileManager.default.fileExists(atPath: Self.plistURL.path)
    }

    nonisolated private static func installedProgram() -> String? {
        guard let dict = NSDictionary(contentsOf: plistURL) else { return nil }
        return dict["Program"] as? String
    }

    @discardableResult
    nonisolated private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
