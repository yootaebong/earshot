import AVFoundation

/// 고른 입력 장치(없으면 시스템 기본, 내 마이크)를 AVAudioEngine 탭으로 받아 .caf 에 쓴다.
final class MicRecorder {
    let fileURL: URL
    let firstHostTime = FirstHostTime()

    private let engine = AVAudioEngine()
    private var writer: AudioFileWriter?
    private var configObserver: NSObjectProtocol?
    /// 조각을 새로 나눠야 할 때(포맷 바뀜·쓰기 실패) 메인에서 이유와 함께 부른다.
    private let onRestart: (String) -> Void
    private let meter: LevelMeter

    init(fileURL: URL, meter: LevelMeter, onRestart: @escaping (String) -> Void) {
        self.fileURL = fileURL
        self.meter = meter
        self.onRestart = onRestart
    }

    deinit { stop() }

    /// 마이크 권한을 묻는다. 이미 정해졌으면 창 없이 바로 돌아온다.
    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// deviceID 가 nil 이면 시스템 기본 입력을 쓴다.
    func start(deviceID: AudioDeviceID?) throws {
        let input = engine.inputNode
        // 엔진 시작 전에 입력 AUHAL 의 장치를 바꿔야 포맷도 그 장치 것으로 읽힌다.
        if let deviceID {
            try input.auAudioUnit.setDeviceID(deviceID)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecordingError("마이크 입력 포맷 없음") }
        // 장치 쪽과 샘플레이트가 다르면 installTap 이 NSException 으로 앱을 죽인다. 미리 던져 시스템 기본으로 넘어가게 한다.
        guard format.sampleRate == input.inputFormat(forBus: 0).sampleRate else { throw RecordingError("마이크 포맷 불일치") }

        let file = try AVAudioFile(forWriting: fileURL, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let onRestart = self.onRestart
        let writer = AudioFileWriter(file: file) { onRestart("쓰기 실패") }
        self.writer = writer

        let firstHostTime = self.firstHostTime
        let meter = self.meter
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            if time.isHostTimeValid { firstHostTime.mark(time.hostTime) }
            meter.record(buffer.rmsDecibels)
            writer.write(buffer)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            writer.close()
            self.writer = nil
            throw error
        }
        // 입력 장치 포맷이 바뀌면 엔진이 멈추므로 조각을 나눈다.
        // 장치를 고르면(setDeviceID) 시작 직후에도 이 알림이 온다. 포맷이 그대로면 나누지 않고 멈춘 엔진만 다시 켠다
        // (나누면 새 조각이 또 장치를 고르며 알림을 불러 1초마다 조각이 생긴다).
        let engine = self.engine
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            let now = engine.inputNode.inputFormat(forBus: 0)
            guard now.sampleRate == format.sampleRate, now.channelCount == format.channelCount else {
                MicMonitor.log("마이크 포맷 \(Int(format.sampleRate))/\(format.channelCount) → \(Int(now.sampleRate))/\(now.channelCount)")
                onRestart("포맷 바뀜")
                return
            }
            guard !engine.isRunning else { return }
            do {
                try engine.start()
            } catch {
                onRestart("포맷 바뀜")
            }
        }
    }

    /// 탭을 떼고, 쓰기 큐에서 파일을 닫은 뒤 돌아온다.
    func stop() {
        guard let writer else { return }
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer.close()
        self.writer = nil
    }
}
