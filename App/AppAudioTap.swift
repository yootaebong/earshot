import Accelerate
import AVFoundation
import CoreAudio
import os

/// 녹음 단계에서 나는 오류. detect.log 에 그대로 남긴다.
struct RecordingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// 첫 버퍼가 들어온 호스트 시각. 오디오 스레드가 쓰고 메인이 읽는다.
final class FirstHostTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64?

    func mark(_ hostTime: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if value == nil, hostTime != 0 { value = hostTime }
    }

    var hostTime: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// 소리 크기(dBFS). 오디오 스레드가 버퍼마다 넣고 메인이 읽는다.
final class LevelMeter: Sendable {
    /// 소리 없음으로 치는 값
    static let silence: Float = -160

    private struct State: Sendable {
        /// 지난번 읽은 뒤 가장 큰 값
        var recent: Float = LevelMeter.silence
        /// reset 뒤 가장 큰 값
        var peak: Float = LevelMeter.silence
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func record(_ decibels: Float) {
        state.withLock {
            $0.recent = max($0.recent, decibels)
            $0.peak = max($0.peak, decibels)
        }
    }

    /// 지난번 읽은 뒤 가장 큰 값을 돌려주고 비운다.
    func takeRecent() -> Float {
        state.withLock {
            let value = $0.recent
            $0.recent = Self.silence
            return value
        }
    }

    var peak: Float { state.withLock { $0.peak } }

    func reset() { state.withLock { $0 = State() } }
}

/// 녹음 파일 하나를 직렬 큐에서만 쓰고 닫는다. 오디오 스레드는 버퍼를 복사해 넘기기만 한다.
final class AudioFileWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "earshot.write", qos: .userInitiated)
    /// queue 에서만 읽고 쓴다.
    private var file: AVAudioFile?
    /// queue 에서만 읽고 쓴다. 첫 실패만 로그·알림하려고 둔다.
    private var failed = false
    private let onFailure: () -> Void

    /// onFailure 는 첫 쓰기 실패 때 메인에서 한 번 불린다.
    init(file: AVAudioFile, onFailure: @escaping () -> Void) {
        self.file = file
        self.onFailure = onFailure
    }

    /// 오디오 스레드에서 부른다. 버퍼를 복사해 큐로 넘긴다.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.copied() else { return }
        queue.async { [self] in
            guard let file else { return }
            do {
                try file.write(from: copy)
            } catch {
                guard !failed else { return }
                failed = true
                MicMonitor.log("오류 쓰기 실패 \(file.url.lastPathComponent): \(error.localizedDescription)")
                DispatchQueue.main.async(execute: onFailure)
            }
        }
    }

    /// 남은 쓰기를 마치고 파일을 닫은 뒤 돌아온다. 여러 번 불러도 된다.
    func close() {
        queue.sync { file = nil }
    }
}

extension AVAudioPCMBuffer {
    /// 같은 포맷의 새 버퍼로 내용을 복사한다(빌린 메모리를 오디오 콜백 밖으로 넘기려고).
    func copied() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == target.count else { return nil }
        for (from, to) in zip(source, target) {
            guard let fromData = from.mData, let toData = to.mData else { return nil }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    /// 모든 채널 RMS(dBFS). float32 가 아니거나 비었으면 LevelMeter.silence
    var rmsDecibels: Float {
        guard format.commonFormat == .pcmFormatFloat32, frameLength > 0, let data = floatChannelData else { return LevelMeter.silence }
        // 인터리브면 첫 포인터에 모든 채널이 섞여 있다.
        let pointers = format.isInterleaved ? 1 : Int(format.channelCount)
        let count = vDSP_Length(Int(frameLength) * (format.isInterleaved ? Int(format.channelCount) : 1))
        var total: Float = 0
        for i in 0..<pointers {
            var meanSquare: Float = 0
            vDSP_measqv(data[i], 1, &meanSquare, count)
            total += meanSquare
        }
        let mean = total / Float(max(pointers, 1))
        return mean > 0 ? max(10 * log10(mean), LevelMeter.silence) : LevelMeter.silence
    }
}

/// 한 앱(프로세스 객체 묶음)이 내는 소리를 Core Audio 프로세스 탭으로 받아 .caf 에 쓴다.
/// 구조는 insidegui/AudioCap 의 ProcessTap 을 따른다.
final class AppAudioTap {
    let fileURL: URL
    let firstHostTime = FirstHostTime()

    private let queue = DispatchQueue(label: "io.taebong.EarShot.AppAudioTap", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var writer: AudioFileWriter?
    private var rateListener: AudioObjectPropertyListenerBlock?
    /// IOProc 에서 탭 몫 버퍼만 가리키는 목록. stop 에서 IOProc 를 멈춘 뒤 해제한다.
    private var tailBufferList: UnsafeMutableAudioBufferListPointer?
    /// 조각을 새로 나눠야 할 때(포맷 바뀜·쓰기 실패) 메인에서 이유와 함께 부른다.
    private let onRestart: (String) -> Void
    private let meter: LevelMeter

    init(fileURL: URL, meter: LevelMeter, onRestart: @escaping (String) -> Void) {
        self.fileURL = fileURL
        self.meter = meter
        self.onRestart = onRestart
    }

    deinit { stop() }

    /// 탭 → private aggregate device → IOProc 순으로 만들고 돌린다. 실패하면 만든 것을 모두 치운다.
    /// objectIDs 가 nil 이면 시스템 전체 소리를 받는다.
    func start(objectIDs: [AudioObjectID]?) throws {
        do {
            try prepare(objectIDs: objectIDs)
        } catch {
            stop()
            throw error
        }
    }

    private func prepare(objectIDs: [AudioObjectID]?) throws {
        let description = objectIDs.map { CATapDescription(stereoMixdownOfProcesses: $0) }
            ?? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "EarShot"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var err = AudioHardwareCreateProcessTap(description, &tapID)
        guard err == noErr else { throw RecordingError("탭 생성 실패 \(err)") }

        guard var format: AudioStreamBasicDescription = CoreAudioProperty.read(tapID, kAudioTapPropertyFormat),
              let audioFormat = AVAudioFormat(streamDescription: &format) else {
            throw RecordingError("탭 포맷 읽기 실패")
        }

        let outputID: AudioObjectID = CoreAudioProperty.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? AudioObjectID(kAudioObjectUnknown)
        guard outputID != kAudioObjectUnknown, let outputUID = CoreAudioProperty.readString(outputID, kAudioDevicePropertyDeviceUID) else {
            throw RecordingError("기본 출력 장치 없음")
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EarShot-Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard err == noErr else { throw RecordingError("aggregate 장치 생성 실패 \(err)") }

        let file = try AVAudioFile(forWriting: fileURL, settings: audioFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: audioFormat.isInterleaved)
        let onRestart = self.onRestart
        let writer = AudioFileWriter(file: file) { onRestart("쓰기 실패") }
        self.writer = writer

        let firstHostTime = self.firstHostTime
        let meter = self.meter
        // 출력 장치에 입력 채널도 있으면(USB 믹서 등) aggregate 입력 앞쪽에 그 장치의 마이크가 오고, 탭은 맨 뒤에 붙는다.
        // 앞쪽을 쓰면 앱 소리 대신 마이크가 녹음되므로 뒤에서 탭 몫만큼만 떼어 쓴다.
        let tapBufferCount = audioFormat.isInterleaved ? 1 : Int(audioFormat.channelCount)
        let tail = AudioBufferList.allocate(maximumBuffers: tapBufferCount)
        tailBufferList = tail
        var loggedLayout = false
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inputData, inputTime, _, _ in
            let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            if !loggedLayout {
                loggedLayout = true
                MicMonitor.log("탭 입력 버퍼 \(all.count)개 중 뒤 \(tapBufferCount)개 사용")
            }
            guard all.count >= tapBufferCount else { return }
            for i in 0..<tapBufferCount { tail[i] = all[all.count - tapBufferCount + i] }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, bufferListNoCopy: tail.unsafePointer, deallocator: nil) else { return }
            firstHostTime.mark(inputTime.pointee.mHostTime)
            meter.record(buffer.rmsDecibels)
            writer.write(buffer)
        }
        guard err == noErr else { throw RecordingError("IOProc 생성 실패 \(err)") }

        // 출력 장치 샘플레이트가 바뀌면 탭 포맷과 파일 포맷이 어긋나므로 조각을 나눈다.
        // 다른 장치(마이크)를 열 때도 알림이 오므로, 실제 값이 탭 포맷과 다를 때만 나눈다(같은데 나누면 1초마다 조각이 생긴다).
        let tapRate = audioFormat.sampleRate
        let aggregateID = self.aggregateID
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            let rate: Float64? = CoreAudioProperty.read(aggregateID, kAudioDevicePropertyNominalSampleRate)
            guard let rate, rate != tapRate else { return }
            MicMonitor.log("탭 샘플레이트 \(Int(tapRate)) → \(Int(rate))")
            onRestart("포맷 바뀜")
        }
        var rateAddress = CoreAudioProperty.address(kAudioDevicePropertyNominalSampleRate)
        err = AudioObjectAddPropertyListenerBlock(aggregateID, &rateAddress, .main, listener)
        if err == noErr {
            rateListener = listener
        } else {
            MicMonitor.log("오류 샘플레이트 감시 등록 \(err)")
        }

        err = AudioDeviceStart(aggregateID, procID)
        guard err == noErr else { throw RecordingError("aggregate 장치 시작 실패 \(err)") }
    }

    /// IOProc 정지·해제 → aggregate 해제 → 탭 해제. 여러 번 불러도 된다.
    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let rateListener {
                var rateAddress = CoreAudioProperty.address(kAudioDevicePropertyNominalSampleRate)
                let err = AudioObjectRemovePropertyListenerBlock(aggregateID, &rateAddress, .main, rateListener)
                if err != noErr { MicMonitor.log("오류 샘플레이트 감시 해제 \(err)") }
                self.rateListener = nil
            }
            if let procID {
                var err = AudioDeviceStop(aggregateID, procID)
                if err != noErr { MicMonitor.log("오류 aggregate 정지 \(err)") }
                err = AudioDeviceDestroyIOProcID(aggregateID, procID)
                if err != noErr { MicMonitor.log("오류 IOProc 해제 \(err)") }
                self.procID = nil
            }
            let err = AudioHardwareDestroyAggregateDevice(aggregateID)
            if err != noErr { MicMonitor.log("오류 aggregate 해제 \(err)") }
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            let err = AudioHardwareDestroyProcessTap(tapID)
            if err != noErr { MicMonitor.log("오류 탭 해제 \(err)") }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        // IOProc 큐를 비워 마지막 버퍼까지 쓰기 큐로 넘긴 뒤, 쓰기 큐에서 파일을 닫고 돌아온다.
        queue.sync {}
        tailBufferList.map { free($0.unsafeMutablePointer) }
        tailBufferList = nil
        writer?.close()
        writer = nil
    }
}
