import Foundation
import os

/// 시스템 오디오 녹음 권한(kTCCServiceAudioCapture). 공개 API 가 없어 TCC 비공개 함수를 dlsym 으로 부른다(AudioCap 과 같은 방식).
/// 이 권한 없이 탭을 열면 오류 없이 무음만 들어온다.
enum AudioCapturePermission {
    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunc = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    /// 0 허용, 1 거부, 그 밖은 아직 안 물어봄. 함수를 못 찾으면 nil
    static func preflight() -> Int? {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: PreflightFunc.self)(service, nil)
    }

    /// 콜백이 이만큼 안 오면 거부로 보고 끝낸다(녹음 시작이 영영 멈추지 않게).
    private static let requestTimeout: TimeInterval = 60

    /// 이미 허용이면 바로 true, 아니면 권한 창을 띄우고 답을 기다린다. 시간 안에 답이 없으면 false.
    static func request() async -> Bool {
        if preflight() == 0 { return true }
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return false }
        let request = unsafeBitCast(symbol, to: RequestFunc.self)
        return await withCheckedContinuation { continuation in
            // 콜백과 시간 초과 중 먼저 온 쪽만 resume 한다(두 번 resume 하면 죽는다).
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Bool) -> Bool = { granted in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: granted) }
                return first
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + requestTimeout) {
                if finish(false) { MicMonitor.log("오류 시스템 오디오 녹음 권한 응답 없음 \(Int(requestTimeout))초 → 거부로 봄") }
            }
            request(service, nil) { granted in _ = finish(granted) }
        }
    }
}
