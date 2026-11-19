//! 설정(분류 목록)·Pending 폴더·파일 이름.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use chrono::{DateTime, Local, NaiveDateTime};
use serde::{Deserialize, Serialize};

pub const APP_NAME: &str = "EarShot";
/// 시스템 전체를 녹음할 때 파일 이름·저장 창의 앱 자리
pub const GLOBAL_APP_NAME: &str = "시스템 전체";
pub const MIN_CATEGORIES: usize = 1;
pub const MAX_CATEGORIES: usize = 6;
/// Recording 아래 녹음 폴더 이름(시작 시각)
pub const RECORDING_DIR_FORMAT: &str = "%Y-%m-%d-%H%M%S";

const RECORDING_DIR: &str = "Recording";
const PENDING_DIR: &str = "Pending";
const TRASH_DIR: &str = "Trash";
const SETTINGS_FILE: &str = "settings.json";
const WAV_EXT: &str = "wav";
const META_EXT: &str = "json";
/// datetime-local 입력 값
const INPUT_FORMAT: &str = "%Y-%m-%dT%H:%M";
const INPUT_FORMAT_SECONDS: &str = "%Y-%m-%dT%H:%M:%S";
/// 파일 이름 앞 시각
const STAMP_FORMAT: &str = "%Y-%m-%d-%H%M";

/// 파일 이름 UTF-8 상한(확장자 포함) — Delivery.swift maxNameBytes
const MAX_NAME_BYTES: usize = 200;
/// unique_path 가 붙이는 "-N" 자리 — Delivery.swift suffixReserveBytes
const SUFFIX_RESERVE_BYTES: usize = 6;
/// 파일 이름에 못 쓰는 문자(NAS·윈도우 공유 기준)
const FORBIDDEN: &[char] = &['/', ':', '\\', '*', '?', '"', '<', '>', '|'];
/// NAS 쪽 봇이 읽는 말이라 바꾸지 않는다.
const ATTENDEES_PREFIX: &str = "참석";
const NEW_CATEGORY_IDS: [(&str, &str); 2] = [("work", "회사"), ("personal", "개인")];

/// 분류. id 는 바꾸지 않는다. name 은 화면 이름, path 는 보낼 폴더
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Category {
    pub id: String,
    pub name: String,
    pub path: String,
}

#[derive(Serialize, Deserialize, Default)]
struct Settings {
    categories: Vec<Category>,
}

/// Pending\<id>.json, Recording\<id>\started.json
#[derive(Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Meta {
    /// ISO8601
    pub started_at: String,
    /// 초
    pub duration: u64,
}

/// 저장 창에 보낼 녹음 하나
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingItem {
    pub id: String,
    pub app_name: String,
    pub duration: u64,
    /// datetime-local 초기값(로컬 시각)
    pub local_input: String,
}

// MARK: - 경로

fn local_root() -> Result<PathBuf> {
    Ok(dirs::data_local_dir()
        .context("LOCALAPPDATA 를 찾지 못했어요")?
        .join(APP_NAME))
}

pub fn recording_root() -> Result<PathBuf> {
    Ok(local_root()?.join(RECORDING_DIR))
}

pub fn pending_root() -> Result<PathBuf> {
    Ok(local_root()?.join(PENDING_DIR))
}

/// %APPDATA%\EarShot\settings.json
fn settings_path() -> Result<PathBuf> {
    Ok(dirs::config_dir()
        .context("APPDATA 를 찾지 못했어요")?
        .join(APP_NAME)
        .join(SETTINGS_FILE))
}

/// Documents\EarShot\<이름>
fn default_path(name: &str) -> String {
    let documents = dirs::document_dir()
        .or_else(|| dirs::home_dir().map(|home| home.join("Documents")))
        .unwrap_or_default();
    documents.join(APP_NAME).join(name).to_string_lossy().into_owned()
}

// MARK: - 설정

fn default_categories() -> Vec<Category> {
    NEW_CATEGORY_IDS
        .iter()
        .map(|(id, name)| Category {
            id: (*id).to_string(),
            name: (*name).to_string(),
            path: default_path(name),
        })
        .collect()
}

/// 처음이거나 읽지 못하면 기본 목록을 만들어 저장한다(맥과 같음).
pub fn load_categories() -> Result<Vec<Category>> {
    let path = settings_path()?;
    if let Ok(text) = fs::read_to_string(&path) {
        if let Ok(settings) = serde_json::from_str::<Settings>(&text) {
            if !settings.categories.is_empty() {
                return Ok(settings.categories);
            }
        }
    }
    let list = default_categories();
    store_categories(&list)?;
    Ok(list)
}

fn store_categories(list: &[Category]) -> Result<()> {
    let path = settings_path()?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let settings = Settings { categories: list.to_vec() };
    fs::write(&path, serde_json::to_string_pretty(&settings)?)
        .with_context(|| format!("{} 저장", path.display()))
}

/// 이름은 앞뒤 공백을 떼고, 빈 경로는 기본 경로로 채워 저장한다.
pub fn save_categories(list: Vec<Category>) -> Result<Vec<Category>> {
    if !(MIN_CATEGORIES..=MAX_CATEGORIES).contains(&list.len()) {
        bail!("분류는 {MIN_CATEGORIES}~{MAX_CATEGORIES}개여야 해요");
    }
    let mut normalized: Vec<Category> = Vec::with_capacity(list.len());
    for category in list {
        let id = category.id.trim().to_string();
        let name = category.name.trim().to_string();
        if id.is_empty() || name.is_empty() {
            bail!("분류 이름이 비어 있어요");
        }
        if normalized.iter().any(|c| c.id == id) {
            bail!("분류 id 가 겹쳐요: {id}");
        }
        let path = if category.path.trim().is_empty() {
            default_path(&name)
        } else {
            category.path
        };
        normalized.push(Category { id, name, path });
    }
    store_categories(&normalized)?;
    Ok(normalized)
}

// MARK: - 메타

pub fn write_meta(path: &Path, meta: &Meta) -> Result<()> {
    fs::write(path, serde_json::to_string_pretty(meta)?)
        .with_context(|| format!("{} 저장", path.display()))
}

pub fn read_meta(path: &Path) -> Result<Meta> {
    let text = fs::read_to_string(path).with_context(|| format!("{} 읽기", path.display()))?;
    Ok(serde_json::from_str(&text)?)
}

// MARK: - Pending

/// 경로 문자가 섞인 id 를 막는다(프런트에서 온 값).
fn check_id(id: &str) -> Result<()> {
    if id.is_empty() || id.contains(['/', '\\', ':']) || id.contains("..") {
        bail!("잘못된 녹음 id: {id}");
    }
    Ok(())
}

fn pending_wav(id: &str) -> Result<PathBuf> {
    check_id(id)?;
    Ok(pending_root()?.join(format!("{id}.{WAV_EXT}")))
}

fn pending_meta(id: &str) -> Result<PathBuf> {
    check_id(id)?;
    Ok(pending_root()?.join(format!("{id}.{META_EXT}")))
}

/// 분류 안 된 녹음 id. 이름이 시작 시각이라 정렬하면 오래된 순
pub fn pending_ids() -> Result<Vec<String>> {
    let root = pending_root()?;
    let Ok(entries) = fs::read_dir(&root) else {
        return Ok(Vec::new());
    };
    let mut ids: Vec<String> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.is_file() && path.extension().is_some_and(|ext| ext == WAV_EXT))
        .filter_map(|path| path.file_stem().map(|stem| stem.to_string_lossy().into_owned()))
        .collect();
    ids.sort();
    Ok(ids)
}

pub fn pending_item(id: &str) -> Result<PendingItem> {
    let wav = pending_wav(id)?;
    if !wav.exists() {
        bail!("녹음 파일이 없어요: {id}");
    }
    let meta = read_meta(&pending_meta(id)?).ok();
    let started = meta
        .as_ref()
        .and_then(|m| DateTime::parse_from_rfc3339(&m.started_at).ok())
        .map(|t| t.with_timezone(&Local).naive_local())
        .or_else(|| NaiveDateTime::parse_from_str(id, RECORDING_DIR_FORMAT).ok())
        .unwrap_or_else(|| Local::now().naive_local());
    Ok(PendingItem {
        id: id.to_string(),
        app_name: GLOBAL_APP_NAME.to_string(),
        duration: meta.map_or(0, |m| m.duration),
        local_input: started.format(INPUT_FORMAT).to_string(),
    })
}

fn parse_input(date: &str) -> Result<NaiveDateTime> {
    NaiveDateTime::parse_from_str(date, INPUT_FORMAT)
        .or_else(|_| NaiveDateTime::parse_from_str(date, INPUT_FORMAT_SECONDS))
        .with_context(|| format!("날짜·시간을 읽지 못했어요: {date}"))
}

/// 파일 이름을 만들어 분류 폴더로 옮긴다. 옮긴 경로를 돌려준다.
pub fn classify(
    id: &str,
    category_id: &str,
    date: &str,
    topic: &str,
    attendees: &str,
) -> Result<PathBuf> {
    let wav = pending_wav(id)?;
    if !wav.exists() {
        bail!("녹음 파일이 없어요: {id}");
    }
    let started = parse_input(date)?;
    let category = load_categories()?
        .into_iter()
        .find(|c| c.id == category_id)
        .context("분류를 찾지 못했어요")?;
    let folder = PathBuf::from(&category.path);
    fs::create_dir_all(&folder).with_context(|| format!("{} 만들기", folder.display()))?;
    let target = unique_path(&folder, &file_name(&started, GLOBAL_APP_NAME, topic, attendees));
    move_file(&wav, &target)?;
    let _ = fs::remove_file(pending_meta(id)?);
    Ok(target)
}

/// 영구 삭제 대신 Pending\Trash 로 옮긴다(휴지통 크레이트를 쓰지 않으려고).
pub fn trash(id: &str) -> Result<()> {
    let trash = pending_root()?.join(TRASH_DIR);
    fs::create_dir_all(&trash)?;
    let wav = pending_wav(id)?;
    move_file(&wav, &unique_path(&trash, &format!("{id}.{WAV_EXT}")))?;
    let meta = pending_meta(id)?;
    if meta.exists() {
        move_file(&meta, &unique_path(&trash, &format!("{id}.{META_EXT}")))?;
    }
    Ok(())
}

/// 같은 볼륨이면 rename, 아니면 복사 후 지운다.
fn move_file(from: &Path, to: &Path) -> Result<()> {
    if fs::rename(from, to).is_ok() {
        return Ok(());
    }
    fs::copy(from, to).with_context(|| format!("{} → {} 복사", from.display(), to.display()))?;
    fs::remove_file(from).with_context(|| format!("{} 지우기", from.display()))?;
    Ok(())
}

// MARK: - 파일 이름 (Delivery.swift 그대로)

/// 같은 이름이 있으면 "-2", "-3" 을 붙인다.
pub fn unique_path(folder: &Path, file_name: &str) -> PathBuf {
    let name = Path::new(file_name);
    let base = name.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let ext = name.extension().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let mut path = folder.join(file_name);
    let mut number = 2;
    while path.exists() {
        path = folder.join(format!("{base}-{number}.{ext}"));
        number += 1;
    }
    path
}

/// "yyyy-MM-dd-HHmm-<앱>[-<주제>][-참석 a,b].wav". 못 쓰는 문자는 지우고 공백은 하나로.
/// "-N" 자리까지 200바이트를 넘으면 참석자 → 주제 → 앱 순으로 끝 글자부터 잘라 맞춘다.
pub fn file_name(started: &NaiveDateTime, app_name: &str, topic: &str, attendees: &str) -> String {
    let stamp = started.format(STAMP_FORMAT).to_string();
    let cleaned_app = clean(app_name);
    let mut app = if cleaned_app.is_empty() {
        GLOBAL_APP_NAME.to_string()
    } else {
        cleaned_app
    };
    let mut topic = clean(topic);
    let mut names = attendees
        .split(',')
        .map(clean)
        .filter(|name| !name.is_empty())
        .collect::<Vec<_>>()
        .join(",");

    let build = |app: &str, topic: &str, names: &str| -> String {
        let mut parts = vec![stamp.clone(), app.to_string()];
        if !topic.is_empty() {
            parts.push(topic.to_string());
        }
        if !names.is_empty() {
            parts.push(format!("{ATTENDEES_PREFIX} {names}"));
        }
        format!("{}.{WAV_EXT}", parts.join("-"))
    };
    let limit = MAX_NAME_BYTES - SUFFIX_RESERVE_BYTES;
    // String::len 은 UTF-8 바이트 수
    while build(&app, &topic, &names).len() > limit {
        if !names.is_empty() {
            names = trim_tail(drop_last(&names));
        } else if !topic.is_empty() {
            topic = trim_tail(drop_last(&topic));
        } else if app.chars().count() > 1 {
            app = trim_tail(drop_last(&app));
        } else {
            break;
        }
    }
    build(&app, &topic, &names)
}

fn clean(text: &str) -> String {
    let kept: String = text
        .chars()
        .filter(|c| !FORBIDDEN.contains(c) && !is_control(*c))
        .collect();
    kept.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Swift CharacterSet.controlCharacters(Cc+Cf) 근사. Cf 는 자주 섞이는 것만 넣었다.
fn is_control(c: char) -> bool {
    c.is_control()
        || matches!(c,
            '\u{00AD}' | '\u{061C}' | '\u{180E}' | '\u{FEFF}'
            | '\u{200B}'..='\u{200F}'
            | '\u{202A}'..='\u{202E}'
            | '\u{2060}'..='\u{2064}'
            | '\u{2066}'..='\u{206F}'
            | '\u{FFF9}'..='\u{FFFB}')
}

/// Swift dropLast 는 글자(grapheme) 단위, 여기는 char 단위다. 결합 문자에서만 다르다.
fn drop_last(text: &str) -> String {
    let mut text = text.to_string();
    text.pop();
    text
}

/// 자른 끝에 남은 공백·쉼표를 지운다.
fn trim_tail(text: String) -> String {
    text.trim_end_matches(|c: char| c.is_whitespace() || c == ',').to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at() -> NaiveDateTime {
        NaiveDateTime::parse_from_str("2026-11-20T14:05", INPUT_FORMAT).unwrap()
    }

    #[test]
    fn 기본_이름() {
        assert_eq!(
            file_name(&at(), GLOBAL_APP_NAME, " 주간  회의 ", "철수, 영희,,"),
            "2026-11-20-1405-시스템 전체-주간 회의-참석 철수,영희.wav"
        );
    }

    #[test]
    fn 못_쓰는_문자_제거() {
        assert_eq!(file_name(&at(), "", "a/b:c?", ""), "2026-11-20-1405-시스템 전체-abc.wav");
    }

    #[test]
    fn 길이_제한() {
        let long = "가".repeat(200);
        let name = file_name(&at(), GLOBAL_APP_NAME, &long, &long);
        assert!(name.len() <= MAX_NAME_BYTES - SUFFIX_RESERVE_BYTES);
        assert!(!name.contains(ATTENDEES_PREFIX));
    }
}
