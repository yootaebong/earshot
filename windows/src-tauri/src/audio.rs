//! 캡처(마이크 + 출력 loopback) · wav 쓰기 · 스테레오 합치기 · 재시작 복구.

use std::fs::{self, File};
use std::io::{BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use chrono::{Local, NaiveDateTime, SecondsFormat, TimeZone};
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
const PART_SUFFIX: &str = "part";

#[derive(Clone, Copy)]
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
    stop_tx: Sender<()>,
    control: JoinHandle<()>,
}

impl Recording {
    /// 두 스트림 중 하나라도 열리면 시작한다. 둘 다 안 되면 Err.
    pub fn start() -> Result<Self> {
        let now = Local::now();
        let id = now.format(store::RECORDING_DIR_FORMAT).to_string();
        let dir = store::recording_root()?.join(&id);
        fs::create_dir_all(&dir).with_context(|| format!("{} 만들기", dir.display()))?;
        let started_at = now.to_rfc3339_opts(SecondsFormat::Secs, false);
        store::write_meta(
            &dir.join(STARTED_FILE),
            &Meta { started_at: started_at.clone(), duration: 0 },
        )?;

        let started = Instant::now();
        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let (ready_tx, ready_rx) = mpsc::channel::<std::result::Result<Vec<String>, String>>();
        let capture_dir = dir.clone();
        let control = thread::Builder::new()
            .name("earshot-capture".into())
            .spawn(move || capture(capture_dir, started, ready_tx, stop_rx))?;

        let failed = match ready_rx.recv() {
            Ok(Ok(warnings)) => {
                return Ok(Self { id, dir, started_at, started, warnings, stop_tx, control });
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

    /// 스트림을 닫고 wav 를 마무리한 뒤 합쳐 Pending 으로 보낸다.
    pub fn stop(self) -> Result<Outcome> {
        let _ = self.stop_tx.send(());
        self.control.join().map_err(|_| anyhow!("캡처 스레드 패닉"))?;
        finalize_dir(&self.dir, &self.id, &self.started_at)
    }
}

/// 캡처 스레드 본문. 스트림을 열고 멈춤 신호를 기다린다.
fn capture(
    dir: PathBuf,
    started: Instant,
    ready_tx: Sender<std::result::Result<Vec<String>, String>>,
    stop_rx: Receiver<()>,
) {
    let host = cpal::default_host();
    let mut streams = Vec::new();
    let mut writers = Vec::new();
    let mut errors = Vec::new();
    for source in [Source::Mic, Source::System] {
        match open_source(&host, source, &dir, started) {
            Ok((stream, writer)) => {
                streams.push(stream);
                writers.push(writer);
            }
            Err(e) => errors.push(format!("{}: {e:#}", source.label())),
        }
    }
    if streams.is_empty() {
        let _ = ready_tx.send(Err(errors.join(" / ")));
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
    let writer = spawn_writer(dir.join(source.file()), config.sample_rate.0, started, rx, source)?;
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
        move |data: &[T], _: &cpal::InputCallbackInfo| {
            let samples: Vec<f32> = data
                .chunks(channels)
                .map(|frame| {
                    frame.iter().map(|&s| f32::from_sample(s)).sum::<f32>() / frame.len() as f32
                })
                .collect();
            let _ = tx.send(Chunk { at: Instant::now(), samples });
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
            for chunk in rx {
                out.clear();
                resampler.process(&chunk.samples, &mut out);
                // loopback 은 무음이면 콜백이 안 온다 → 시작 후 경과시간 기준으로 밀린 만큼 0 을 먼저 채운다.
                // 이번 덩어리는 "지금" 끝난 소리라 그 길이만큼은 빼고 채운다.
                let expected =
                    (chunk.at.saturating_duration_since(started).as_secs_f64() * f64::from(SAMPLE_RATE)) as u64;
                let behind = expected.saturating_sub(written);
                let zeros = if behind > GAP_THRESHOLD {
                    behind.saturating_sub(out.len() as u64)
                } else {
                    0
                };
                if let Err(e) = write_samples(&mut writer, zeros, &out) {
                    eprintln!("[{label}] 쓰기 실패: {e}");
                    break;
                }
                written += zeros + out.len() as u64;
            }
            if let Err(e) = writer.finalize() {
                eprintln!("[{label}] wav 마무리 실패: {e}");
            }
        })?;
    Ok(handle)
}

fn write_samples<W: Write + Seek>(
    writer: &mut hound::WavWriter<W>,
    zeros: u64,
    samples: &[f32],
) -> std::result::Result<(), hound::Error> {
    for _ in 0..zeros {
        writer.write_sample(0i16)?;
    }
    for &sample in samples {
        writer.write_sample(to_i16(sample))?;
    }
    Ok(())
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
    inner: BufReader<File>,
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
                return Ok(Self { inner: BufReader::new(file), remaining });
            }
            let size = u64::from(u32::from_le_bytes([chunk[4], chunk[5], chunk[6], chunk[7]]));
            pos += size + (size & 1);
            file.seek(SeekFrom::Start(pos))?;
        }
    }

    fn len(&self) -> u64 {
        self.remaining
    }
}

impl Iterator for PcmReader {
    type Item = i16;

    fn next(&mut self) -> Option<i16> {
        if self.remaining == 0 {
            return None;
        }
        let mut bytes = [0u8; 2];
        self.inner.read_exact(&mut bytes).ok()?;
        self.remaining -= 1;
        Some(i16::from_le_bytes(bytes))
    }
}

/// 왼쪽 마이크, 오른쪽 시스템. 짧은 쪽은 0.
fn merge(mic: Option<PcmReader>, system: Option<PcmReader>, out: &Path) -> Result<()> {
    let mut writer = hound::WavWriter::create(out, stereo_spec())
        .with_context(|| format!("{} 만들기", out.display()))?;
    let mut left = mic.into_iter().flatten();
    let mut right = system.into_iter().flatten();
    loop {
        let l = left.next();
        let r = right.next();
        if l.is_none() && r.is_none() {
            break;
        }
        writer.write_sample(l.unwrap_or(0))?;
        writer.write_sample(r.unwrap_or(0))?;
    }
    writer.finalize()?;
    Ok(())
}

/// 녹음 폴더 하나를 마무리한다. 30초 미만이면 지우고 TooShort.
fn finalize_dir(dir: &Path, id: &str, started_at: &str) -> Result<Outcome> {
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
    let wav = pending.join(format!("{id}.wav"));
    // 합치다 죽어도 반쪽 파일이 Pending 에 보이지 않게 .part 로 쓰고 옮긴다(다음 실행 때 다시 합침).
    let part = pending.join(format!("{id}.wav.{PART_SUFFIX}"));
    merge(mic, system, &part)?;
    store::write_meta(
        &pending.join(format!("{id}.json")),
        &Meta { started_at: started_at.to_string(), duration },
    )?;
    fs::rename(&part, &wav).with_context(|| format!("{} 옮기기", wav.display()))?;
    fs::remove_dir_all(dir).with_context(|| format!("{} 지우기", dir.display()))?;
    Ok(Outcome::Saved(id.to_string()))
}

/// 앱 시작 때 Recording 에 남은 녹음을 합쳐 Pending 으로 보낸다. 보낸 id 들을 돌려준다.
pub fn recover_all() -> Vec<String> {
    let mut saved = Vec::new();
    let Ok(root) = store::recording_root() else {
        return saved;
    };
    let Ok(entries) = fs::read_dir(&root) else {
        return saved;
    };
    for entry in entries.flatten() {
        let dir = entry.path();
        if !dir.is_dir() {
            continue;
        }
        let id = entry.file_name().to_string_lossy().into_owned();
        let started_at = store::read_meta(&dir.join(STARTED_FILE))
            .map(|meta| meta.started_at)
            .unwrap_or_else(|_| started_at_from_id(&id));
        match finalize_dir(&dir, &id, &started_at) {
            Ok(Outcome::Saved(id)) => saved.push(id),
            Ok(Outcome::TooShort) => {}
            Err(e) => eprintln!("복구 실패 {id}: {e:#}"),
        }
    }
    saved
}

/// started.json 이 없으면 폴더 이름(시작 시각)으로 대신한다.
fn started_at_from_id(id: &str) -> String {
    NaiveDateTime::parse_from_str(id, store::RECORDING_DIR_FORMAT)
        .ok()
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
