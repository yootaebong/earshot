//! 캡처(마이크 + 출력 loopback) · wav 쓰기 · 스테레오 합치기 · 재시작 복구.

use std::fs::{self, File};
use std::io::{ErrorKind, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use chrono::{Local, SecondsFormat, TimeZone};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
// f32::from_sample 은 Sample 트레이트 메서드라 같이 가져온다.
use cpal::{FromSample, Sample, SampleFormat, SizedSample};

use crate::store::{self, Meta};

pub const SAMPLE_RATE: u32 = 48_000;
/// 이보다 짧으면 버린다.
pub const MIN_DURATION_SECS: u64 = 30;
/// 0.1초 넘게 밀리면 무음으로 메운다.
const GAP_THRESHOLD: u64 = 4_800;
const BITS_PER_SAMPLE: u16 = 16;
const MIC_FILE: &str = "mic.wav";
const SYSTEM_FILE: &str = "system.wav";
const STARTED_FILE: &str = "started.json";
const WAV_EXT: &str = "wav";
const META_EXT: &str = "json";
const PART_EXT: &str = "wav.part";
/// 합칠 때 한 번에 읽는 바이트(채널마다)
const MERGE_BLOCK_BYTES: usize = 64 * 1024;
/// 무음을 한 번에 쓰는 샘플 수
const ZERO_BLOCK: usize = 48_000;

/// wav 쓰기 실패를 알리는 콜백(한 번만 불린다)
type Alert = Arc<dyn Fn() + Send + Sync>;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Source {
    Mic,
    System,
}

impl Source {
    fn label(self) -> &'static str {
        match self {
            Source::Mic => "마이크",
            Source::System => "시스템",
        }
    }

    fn file(self) -> &'static str {
        match self {
            Source::Mic => MIC_FILE,
            Source::System => SYSTEM_FILE,
        }
    }
}

/// 콜백 한 번 분량(모노, 장치 샘플레이트)
struct Chunk {
    /// 첫 샘플이 잡힌 시각
    at: Instant,
    samples: Vec<f32>,
}

pub enum Outcome {
    /// Pending 에 둔 녹음 id
    Saved(String),
    /// 30초 미만이라 버림
    TooShort,
}

/// 녹음 중인 세션. cpal::Stream 은 Send 가 아니라 캡처 스레드가 들고 있고, 여기선 멈춤 신호만 보낸다.
pub struct Recording {
    id: String,
    dir: PathBuf,
    started_at: String,
    started: Instant,
    warnings: Vec<String>,
    /// 열지 못한 쪽
    missing: Vec<Source>,
    stop_tx: Sender<()>,
    control: JoinHandle<()>,
}

impl Recording {
    /// 두 스트림 중 하나라도 열리면 시작한다. 둘 다 안 되면 Err.
    /// on_write_error: wav 쓰기에 실패하면 녹음마다 한 번 불린다(쓰기 스레드에서).
    pub fn start<F>(on_write_error: F) -> Result<Self>
    where
        F: Fn() + Send + Sync + 'static,
    {
        let now = Local::now();
        // 같은 초에 다시 시작해도 겹치지 않게 랜덤을 붙인다.
        let id = store::new_recording_id(&now);
        let dir = store::recording_root()?.join(&id);
        fs::create_dir_all(&dir).with_context(|| format!("{} 만들기", dir.display()))?;
        let started_at = now.to_rfc3339_opts(SecondsFormat::Secs, false);
        store::write_meta(
            &dir.join(STARTED_FILE),
            &Meta { started_at: started_at.clone(), duration: 0 },
        )?;

        let started = Instant::now();
        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let (ready_tx, ready_rx) = mpsc::channel::<std::result::Result<Vec<(Source, String)>, String>>();
        let fired = AtomicBool::new(false);
        let alert: Alert = Arc::new(move || {
            if !fired.swap(true, Ordering::SeqCst) {
                on_write_error();
            }
        });
        let capture_dir = dir.clone();
        let control = thread::Builder::new()
            .name("earshot-capture".into())
            .spawn(move || capture(capture_dir, started, alert, ready_tx, stop_rx))?;

        let failed = match ready_rx.recv() {
            Ok(Ok(errors)) => {
                let missing = errors.iter().map(|(source, _)| *source).collect();
                let warnings = errors
                    .into_iter()
                    .map(|(source, e)| format!("{}: {e}", source.label()))
                    .collect();
                return Ok(Self { id, dir, started_at, started, warnings, missing, stop_tx, control });
            }
            Ok(Err(message)) => anyhow!(message),
            Err(_) => anyhow!("캡처 스레드가 멈췄어요"),
        };
        let _ = control.join();
        let _ = fs::remove_dir_all(&dir);
        Err(failed)
    }

    pub fn id(&self) -> &str {
        &self.id
    }

    pub fn elapsed(&self) -> Duration {
        self.started.elapsed()
    }

    /// 열지 못한 쪽 스트림 사유
    pub fn warnings(&self) -> &[String] {
        &self.warnings
    }

    /// 마이크를 못 열고 시스템 소리만 녹음 중
    pub fn missing_mic(&self) -> bool {
        self.missing.contains(&Source::Mic)
    }

    /// 시스템 소리를 못 열고 마이크만 녹음 중
    pub fn missing_system(&self) -> bool {
        self.missing.contains(&Source::System)
    }

    /// 스트림을 닫고 wav 를 마무리한 뒤 합쳐 Pending 으로 보낸다.
    pub fn stop(self) -> Result<Outcome> {
        let _ = self.stop_tx.send(());
        self.control.join().map_err(|_| anyhow!("캡처 스레드 패닉"))?;
        finalize_dir(&self.dir, &self.id, &self.started_at, false)
    }
}

/// 캡처 스레드 본문. 스트림을 열고 멈춤 신호를 기다린다.
fn capture(
    dir: PathBuf,
    started: Instant,
    alert: Alert,
    ready_tx: Sender<std::result::Result<Vec<(Source, String)>, String>>,
    stop_rx: Receiver<()>,
) {
    let host = cpal::default_host();
    let mut streams = Vec::new();
    let mut writers = Vec::new();
    let mut errors = Vec::new();
    for source in [Source::Mic, Source::System] {
        match open_source(&host, source, &dir, started, alert.clone()) {
            Ok((stream, writer)) => {
                streams.push(stream);
                writers.push(writer);
            }
            Err(e) => errors.push((source, format!("{e:#}"))),
        }
    }
    if streams.is_empty() {
        let text: Vec<String> =
            errors.iter().map(|(source, e)| format!("{}: {e}", source.label())).collect();
        let _ = ready_tx.send(Err(text.join(" / ")));
        return;
    }
    let _ = ready_tx.send(Ok(errors));
    // 멈춤 신호나 Recording 이 버려지면(Err) 끝낸다.
    let _ = stop_rx.recv();
    // 스트림을 닫으면 콜백이 들고 있던 Sender 도 닫혀 쓰기 스레드가 끝난다.
    drop(streams);
    for writer in writers {
        if writer.join().is_err() {
            eprintln!("쓰기 스레드 패닉");
        }
    }
}

fn open_source(
    host: &cpal::Host,
    source: Source,
    dir: &Path,
    started: Instant,
    alert: Alert,
) -> Result<(cpal::Stream, JoinHandle<()>)> {
    let (device, supported) = match source {
        Source::Mic => {
            let device = host.default_input_device().context("기본 입력 장치가 없어요")?;
            let config = device.default_input_config()?;
            (device, config)
        }
        Source::System => {
            // WASAPI 는 출력 장치에 input stream 을 열면 loopback 으로 받는다.
            let device = host.default_output_device().context("기본 출력 장치가 없어요")?;
            let config = device.default_output_config()?;
            (device, config)
        }
    };
    let config: cpal::StreamConfig = supported.config();
    let (tx, rx) = mpsc::channel::<Chunk>();
    let writer =
        spawn_writer(dir.join(source.file()), config.sample_rate.0, started, rx, source, alert)?;
    let stream = match supported.sample_format() {
        SampleFormat::F32 => build_stream::<f32>(&device, &config, tx, source)?,
        SampleFormat::I16 => build_stream::<i16>(&device, &config, tx, source)?,
        SampleFormat::U16 => build_stream::<u16>(&device, &config, tx, source)?,
        SampleFormat::I32 => build_stream::<i32>(&device, &config, tx, source)?,
        other => bail!("지원하지 않는 샘플 형식: {other:?}"),
    };
    stream.play()?;
    Ok((stream, writer))
}

/// 콜백에서는 모노로 다운믹스만 하고 쓰기 스레드로 넘긴다.
fn build_stream<T>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    tx: Sender<Chunk>,
    source: Source,
) -> Result<cpal::Stream>
where
    T: SizedSample + Send + 'static,
    f32: FromSample<T>,
{
    let channels = usize::from(config.channels.max(1));
    let label = source.label();
    let stream = device.build_input_stream(
        config,
        move |data: &[T], info: &cpal::InputCallbackInfo| {
            // 콜백 시각이 아니라 캡처 시각 기준 — 몰려 들어온 패킷도 제자리에 놓인다.
            let now = Instant::now();
            let timestamp = info.timestamp();
            let at = timestamp
                .callback
                .duration_since(&timestamp.capture)
                .and_then(|delay| now.checked_sub(delay))
                .unwrap_or(now);
            let samples: Vec<f32> = data
                .chunks(channels)
                .map(|frame| {
                    frame.iter().map(|&s| f32::from_sample(s)).sum::<f32>() / frame.len() as f32
                })
                .collect();
            let _ = tx.send(Chunk { at, samples });
        },
        move |err| eprintln!("[{label}] 스트림 오류: {err}"),
        None,
    )?;
    Ok(stream)
}

fn mono_spec() -> hound::WavSpec {
    hound::WavSpec {
        channels: 1,
        sample_rate: SAMPLE_RATE,
        bits_per_sample: BITS_PER_SAMPLE,
        sample_format: hound::SampleFormat::Int,
    }
}

fn stereo_spec() -> hound::WavSpec {
    hound::WavSpec { channels: 2, ..mono_spec() }
}

/// 48k 로 바꾸고, 밀린 만큼 무음을 채워 mono 16비트로 쓴다.
fn spawn_writer(
    path: PathBuf,
    in_rate: u32,
    started: Instant,
    rx: Receiver<Chunk>,
    source: Source,
    alert: Alert,
) -> Result<JoinHandle<()>> {
    let mut writer = hound::WavWriter::create(&path, mono_spec())
        .with_context(|| format!("{} 만들기", path.display()))?;
    let label = source.label();
    let handle = thread::Builder::new()
        .name(format!("earshot-writer-{}", source.file()))
        .spawn(move || {
            let mut resampler = Resampler::new(in_rate, SAMPLE_RATE);
            let mut written: u64 = 0;
            let mut out = Vec::new();
            let mut block = Vec::new();
            for chunk in rx {
                out.clear();
                resampler.process(&chunk.samples, &mut out);
                // loopback 은 무음이면 콜백이 안 온다 → 이 덩어리가 시작했어야 할 자리까지 0 을 먼저 채운다.
                // chunk.at 은 첫 샘플의 캡처 시각이다.
                let expected =
                    (chunk.at.saturating_duration_since(started).as_secs_f64() * f64::from(SAMPLE_RATE)) as u64;
                let behind = expected.saturating_sub(written);
                let zeros = if behind > GAP_THRESHOLD { behind } else { 0 };
                if let Err(e) = write_samples(&mut writer, zeros, &out, &mut block) {
                    eprintln!("[{label}] 쓰기 실패: {e}");
                    alert();
                    break;
                }
                written += zeros + out.len() as u64;
            }
            if let Err(e) = writer.finalize() {
                eprintln!("[{label}] wav 마무리 실패: {e}");
                alert();
            }
        })?;
    Ok(handle)
}

/// 무음 zeros 개를 쓰고 samples 를 쓴다. block 은 재사용 버퍼.
fn write_samples<W: Write + Seek>(
    writer: &mut hound::WavWriter<W>,
    zeros: u64,
    samples: &[f32],
    block: &mut Vec<i16>,
) -> std::result::Result<(), hound::Error> {
    let mut left = zeros;
    while left > 0 {
        let n = left.min(ZERO_BLOCK as u64) as usize;
        block.clear();
        block.resize(n, 0);
        write_block(writer, block)?;
        left -= n as u64;
    }
    block.clear();
    block.extend(samples.iter().map(|&s| to_i16(s)));
    write_block(writer, block)
}

/// 버퍼 단위로 쓴다(샘플마다 write_sample 보다 빠름).
fn write_block<W: Write + Seek>(
    writer: &mut hound::WavWriter<W>,
    samples: &[i16],
) -> std::result::Result<(), hound::Error> {
    if samples.is_empty() {
        return Ok(());
    }
    let mut sample_writer = writer.get_i16_writer(samples.len() as u32);
    for &sample in samples {
        sample_writer.write_sample(sample);
    }
    sample_writer.flush()
}

fn to_i16(sample: f32) -> i16 {
    (sample.clamp(-1.0, 1.0) * f32::from(i16::MAX)) as i16
}

/// 덩어리를 넘나드는 선형 보간. 이전 덩어리의 마지막 샘플을 들고 있다.
struct Resampler {
    step: f64,
    pos: f64,
    prev: f32,
}

impl Resampler {
    fn new(in_rate: u32, out_rate: u32) -> Self {
        Self { step: f64::from(in_rate) / f64::from(out_rate), pos: 0.0, prev: 0.0 }
    }

    fn process(&mut self, input: &[f32], out: &mut Vec<f32>) {
        if (self.step - 1.0).abs() < f64::EPSILON {
            out.extend_from_slice(input);
            return;
        }
        // 가상 버퍼 [prev, input...] 의 위치 pos 에서 뽑는다(0 = prev).
        let n = input.len();
        while self.pos < n as f64 {
            let i = self.pos.floor() as usize;
            let frac = (self.pos - i as f64) as f32;
            let a = if i == 0 { self.prev } else { input[i - 1] };
            let b = input[i];
            out.push(a + (b - a) * frac);
            self.pos += self.step;
        }
        self.pos -= n as f64;
        if let Some(&last) = input.last() {
            self.prev = last;
        }
    }
}

// MARK: - 합치기

/// 16비트 PCM wav 의 data 부분을 끝까지 읽는다.
/// 앱이 죽어 hound 가 헤더를 마무리 못 한 파일(data 크기 0)도 읽도록 선언 크기 대신 파일 끝까지 본다.
struct PcmReader {
    inner: File,
    /// 남은 샘플 수
    remaining: u64,
}

impl PcmReader {
    fn open(path: &Path) -> Result<Self> {
        let mut file = File::open(path)?;
        let len = file.metadata()?.len();
        let mut head = [0u8; 12];
        file.read_exact(&mut head)?;
        if &head[0..4] != b"RIFF" || &head[8..12] != b"WAVE" {
            bail!("{} 은 wav 가 아니에요", path.display());
        }
        let mut pos: u64 = 12;
        loop {
            let mut chunk = [0u8; 8];
            file.read_exact(&mut chunk).context("data 청크가 없어요")?;
            pos += 8;
            if &chunk[0..4] == b"data" {
                let remaining = len.saturating_sub(pos) / 2;
                return Ok(Self { inner: file, remaining });
            }
            let size = u64::from(u32::from_le_bytes([chunk[4], chunk[5], chunk[6], chunk[7]]));
            pos += size + (size & 1);
            file.seek(SeekFrom::Start(pos))?;
        }
    }

    fn len(&self) -> u64 {
        self.remaining
    }

    /// bytes 크기만큼(남은 만큼) 읽어 out 에 담는다. 끝이면 out 이 빈다.
    /// 다 못 채우면 파일이 짧은 것이라 그 덩어리를 마지막으로 본다.
    fn read_block(&mut self, bytes: &mut [u8], out: &mut Vec<i16>) -> Result<()> {
        out.clear();
        let want = (self.remaining.saturating_mul(2)).min(bytes.len() as u64) as usize;
        if want == 0 {
            return Ok(());
        }
        let mut filled = 0;
        while filled < want {
            match self.inner.read(&mut bytes[filled..want]) {
                Ok(0) => break,
                Ok(n) => filled += n,
                Err(e) if e.kind() == ErrorKind::Interrupted => {}
                Err(e) => return Err(e.into()),
            }
        }
        let samples = filled / 2;
        self.remaining = if filled < want { 0 } else { self.remaining - samples as u64 };
        out.extend(bytes[..samples * 2].chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])));
        Ok(())
    }
}

fn read_side(reader: &mut Option<PcmReader>, bytes: &mut [u8], out: &mut Vec<i16>) -> Result<()> {
    match reader {
        Some(reader) => reader.read_block(bytes, out),
        None => {
            out.clear();
            Ok(())
        }
    }
}

/// 왼쪽 마이크, 오른쪽 시스템. 짧은 쪽은 0. 64KB 씩 읽어 덩어리로 쓴다.
fn merge(mut mic: Option<PcmReader>, mut system: Option<PcmReader>, out: &Path) -> Result<()> {
    let mut writer = hound::WavWriter::create(out, stereo_spec())
        .with_context(|| format!("{} 만들기", out.display()))?;
    let mut bytes = vec![0u8; MERGE_BLOCK_BYTES];
    let mut left = Vec::new();
    let mut right = Vec::new();
    let mut frames = Vec::with_capacity(MERGE_BLOCK_BYTES);
    loop {
        // 양쪽 모두 같은 크기로 읽으니 덩어리마다 위치가 맞는다.
        read_side(&mut mic, &mut bytes, &mut left)?;
        read_side(&mut system, &mut bytes, &mut right)?;
        let count = left.len().max(right.len());
        if count == 0 {
            break;
        }
        frames.clear();
        for i in 0..count {
            frames.push(left.get(i).copied().unwrap_or(0));
            frames.push(right.get(i).copied().unwrap_or(0));
        }
        write_block(&mut writer, &frames)?;
    }
    writer.finalize()?;
    Ok(())
}

/// 녹음 폴더 하나를 마무리한다. 30초 미만이면 지우고 TooShort.
/// Pending 이름은 id 를 기본으로, 겹치면 "-2" 를 붙인다. wav·json 은 같은 기본 이름.
fn finalize_dir(dir: &Path, id: &str, started_at: &str, recovering: bool) -> Result<Outcome> {
    // 없거나 못 읽는 쪽(스트림 실패)은 무음으로 본다.
    let mic = PcmReader::open(&dir.join(MIC_FILE)).ok();
    let system = PcmReader::open(&dir.join(SYSTEM_FILE)).ok();
    let frames = mic.as_ref().map_or(0, PcmReader::len).max(system.as_ref().map_or(0, PcmReader::len));
    let duration = frames / u64::from(SAMPLE_RATE);
    if duration < MIN_DURATION_SECS {
        fs::remove_dir_all(dir).with_context(|| format!("{} 지우기", dir.display()))?;
        return Ok(Outcome::TooShort);
    }

    let pending = store::pending_root()?;
    fs::create_dir_all(&pending)?;
    let own = |ext: &str| pending.join(format!("{id}.{ext}"));
    // 지난번 옮긴 뒤 폴더만 못 지우고 죽었으면 이미 끝난 녹음이다(id 에 랜덤이 있어 남의 것일 리 없음).
    if recovering && own(WAV_EXT).exists() && own(META_EXT).exists() {
        fs::remove_dir_all(dir).with_context(|| format!("{} 지우기", dir.display()))?;
        return Ok(Outcome::Saved(id.to_string()));
    }
    // 지난번 합치다 죽은 흔적(반쪽 part, wav 없는 json)을 치운다.
    let _ = fs::remove_file(own(PART_EXT));
    if !own(WAV_EXT).exists() {
        let _ = fs::remove_file(own(META_EXT));
    }

    let stem = store::unique_stem(&pending, id, &[WAV_EXT, META_EXT, PART_EXT]);
    let wav = pending.join(format!("{stem}.{WAV_EXT}"));
    // 합치다 죽어도 반쪽 파일이 Pending 에 보이지 않게 .part 로 쓰고 옮긴다(다음 실행 때 다시 합침).
    let part = pending.join(format!("{stem}.{PART_EXT}"));
    if let Err(e) = merge(mic, system, &part) {
        let _ = fs::remove_file(&part);
        return Err(e);
    }
    store::write_meta(
        &pending.join(format!("{stem}.{META_EXT}")),
        &Meta { started_at: started_at.to_string(), duration },
    )?;
    fs::rename(&part, &wav).with_context(|| format!("{} 옮기기", wav.display()))?;
    fs::remove_dir_all(dir).with_context(|| format!("{} 지우기", dir.display()))?;
    Ok(Outcome::Saved(stem))
}

/// Recording 에 남은 녹음 폴더 목록. 앱 시작 때 녹음을 시작하기 전에 모은다.
pub fn leftover_dirs() -> Vec<PathBuf> {
    let Ok(root) = store::recording_root() else {
        return Vec::new();
    };
    let Ok(entries) = fs::read_dir(&root) else {
        return Vec::new();
    };
    entries.flatten().map(|entry| entry.path()).filter(|path| path.is_dir()).collect()
}

/// 미리 모은 폴더만 합쳐 Pending 으로 보낸다. is_recording(id) 가 참이면 건너뛴다. 보낸 id 들을 돌려준다.
pub fn recover(dirs: Vec<PathBuf>, is_recording: impl Fn(&str) -> bool) -> Vec<String> {
    let mut saved = Vec::new();
    for dir in dirs {
        let Some(id) = dir.file_name().map(|name| name.to_string_lossy().into_owned()) else {
            continue;
        };
        if is_recording(&id) || !dir.is_dir() {
            continue;
        }
        let started_at = store::read_meta(&dir.join(STARTED_FILE))
            .map(|meta| meta.started_at)
            .unwrap_or_else(|_| started_at_from_id(&id));
        match finalize_dir(&dir, &id, &started_at, true) {
            Ok(Outcome::Saved(id)) => saved.push(id),
            Ok(Outcome::TooShort) => {}
            Err(e) => eprintln!("복구 실패 {id}: {e:#}"),
        }
    }
    saved
}

/// started.json 이 없으면 폴더 이름(시작 시각)으로 대신한다.
fn started_at_from_id(id: &str) -> String {
    store::started_from_id(id)
        .and_then(|naive| Local.from_local_datetime(&naive).single())
        .unwrap_or_else(Local::now)
        .to_rfc3339_opts(SecondsFormat::Secs, false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 같은_레이트는_그대로() {
        let mut r = Resampler::new(SAMPLE_RATE, SAMPLE_RATE);
        let mut out = Vec::new();
        r.process(&[0.1, 0.2], &mut out);
        assert_eq!(out, vec![0.1, 0.2]);
    }

    #[test]
    fn 레이트_변환_길이() {
        let mut r = Resampler::new(44_100, SAMPLE_RATE);
        let mut out = Vec::new();
        for _ in 0..100 {
            r.process(&[0.0; 441], &mut out);
        }
        // 44100 → 48000 이면 1초 분량이 약 48000
        assert!((out.len() as i64 - 48_000).abs() <= 2);
    }
}
