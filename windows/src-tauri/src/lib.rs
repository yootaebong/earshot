//! 트레이 · 전역 단축키 · 창 · 명령.

mod audio;
mod store;

use std::collections::VecDeque;
use std::sync::{Mutex, MutexGuard};
use std::thread;
use std::time::Duration;

use tauri::menu::{CheckMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, RunEvent, State, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};
use tauri_plugin_notification::NotificationExt;

use store::{Category, PendingItem};

const TRAY_ID: &str = "main";
const SAVE_LABEL: &str = "save";
const SETTINGS_LABEL: &str = "settings";
/// 저장 창이 이미 열려 있을 때 새 녹음을 다시 읽으라는 이벤트
const PENDING_EVENT: &str = "pending-changed";

const MENU_TOGGLE: &str = "toggle";
const MENU_PENDING: &str = "pending";
const MENU_STORAGE: &str = "storage";
const MENU_LOGIN: &str = "login";
const MENU_QUIT: &str = "quit";

const TICK: Duration = Duration::from_secs(1);
const TOO_SHORT_MESSAGE: &str = "30초보다 짧은 녹음이라 저장하지 않았어요";
const MIC_MISSING_MESSAGE: &str = "마이크를 열지 못해 시스템 소리만 녹음해요";
const SYSTEM_MISSING_MESSAGE: &str = "시스템 소리를 열지 못해 마이크만 녹음해요";
const WRITE_FAILED_MESSAGE: &str = "녹음 저장 실패 — 디스크 공간 확인";

#[derive(Default)]
struct AppState {
    recording: Mutex<Option<audio::Recording>>,
    /// 저장 창 상태
    save: Mutex<SaveQueue>,
}

/// 저장 창이 보여 주는 녹음과 그 뒤에 기다리는 녹음(맥 SaveWindow 의 waiting 과 같음)
#[derive(Default)]
struct SaveQueue {
    current: Option<String>,
    waiting: VecDeque<String>,
}

/// 독(poison)이 나도 안의 값을 그대로 쓴다.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn error_text(e: anyhow::Error) -> String {
    format!("{e:#}")
}

fn notify(app: &AppHandle, title: &str, body: &str) {
    if let Err(e) = app.notification().builder().title(title).body(body).show() {
        eprintln!("알림 실패: {e}");
    }
}

// MARK: - 녹음

fn toggle_recording(app: &AppHandle) {
    let state = app.state::<AppState>();
    let mut guard = lock(&state.recording);
    if let Some(recording) = guard.take() {
        drop(guard);
        refresh_tray(app);
        let app = app.clone();
        // 합치기가 길 수 있어 메인 스레드 밖에서 한다.
        thread::spawn(move || finish(&app, recording, true));
        return;
    }
    let alert_app = app.clone();
    let on_write_error = move || notify(&alert_app, store::APP_NAME, WRITE_FAILED_MESSAGE);
    match audio::Recording::start(on_write_error) {
        Ok(recording) => {
            for warning in recording.warnings() {
                eprintln!("한쪽 스트림만 녹음: {warning}");
            }
            let partial = if recording.missing_mic() {
                Some(MIC_MISSING_MESSAGE)
            } else if recording.missing_system() {
                Some(SYSTEM_MISSING_MESSAGE)
            } else {
                None
            };
            let id = recording.id().to_string();
            *guard = Some(recording);
            drop(guard);
            if let Some(message) = partial {
                notify(app, store::APP_NAME, message);
            }
            refresh_tray(app);
            spawn_ticker(app.clone(), id);
        }
        Err(e) => {
            drop(guard);
            notify(app, "녹음을 시작하지 못했어요", &error_text(e));
        }
    }
}

/// manual: 사용자가 직접 멈췄는지(짧은 녹음 알림 여부)
fn finish(app: &AppHandle, recording: audio::Recording, manual: bool) {
    match recording.stop() {
        Ok(audio::Outcome::Saved(id)) => {
            let handle = app.clone();
            let _ = app.run_on_main_thread(move || open_save(&handle, Some(id)));
        }
        Ok(audio::Outcome::TooShort) => {
            if manual {
                notify(app, store::APP_NAME, TOO_SHORT_MESSAGE);
            }
        }
        Err(e) => notify(app, "녹음을 저장하지 못했어요", &error_text(e)),
    }
    refresh_tray(app);
}

/// 녹음 중 1초마다 툴팁에 경과 시간을 쓴다. 같은 녹음이 끝나면 멈춘다.
fn spawn_ticker(app: AppHandle, id: String) {
    set_tooltip(&app, &recording_tooltip(Duration::ZERO));
    thread::spawn(move || loop {
        thread::sleep(TICK);
        let text = {
            let state = app.state::<AppState>();
            let guard = lock(&state.recording);
            match guard.as_ref() {
                Some(recording) if recording.id() == id => recording_tooltip(recording.elapsed()),
                _ => break,
            }
        };
        set_tooltip(&app, &text);
    });
}

fn recording_tooltip(elapsed: Duration) -> String {
    let total = elapsed.as_secs();
    let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60);
    let time = if hours > 0 {
        format!("{hours}:{minutes:02}:{seconds:02}")
    } else {
        format!("{minutes}:{seconds:02}")
    };
    format!("{} — 녹음 중 {time}", store::APP_NAME)
}

fn set_tooltip(app: &AppHandle, text: &str) {
    if let Some(tray) = app.tray_by_id(TRAY_ID) {
        let _ = tray.set_tooltip(Some(text));
    }
}

// MARK: - 트레이

fn build_menu(app: &AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    let recording = lock(&app.state::<AppState>().recording).is_some();
    let pending = store::pending_ids().map(|ids| ids.len()).unwrap_or(0);
    let login = app.autolaunch().is_enabled().unwrap_or(false);

    let menu = Menu::new(app)?;
    let toggle_text = if recording { "녹음 멈추기" } else { "녹음 시작" };
    menu.append(&MenuItem::with_id(app, MENU_TOGGLE, toggle_text, true, None::<&str>)?)?;
    if pending > 0 {
        let text = format!("분류 안 됨 {pending}개 저장…");
        menu.append(&MenuItem::with_id(app, MENU_PENDING, text, true, None::<&str>)?)?;
    }
    menu.append(&MenuItem::with_id(app, MENU_STORAGE, "저장 위치…", true, None::<&str>)?)?;
    menu.append(&CheckMenuItem::with_id(app, MENU_LOGIN, "로그인 시 실행", true, login, None::<&str>)?)?;
    menu.append(&PredefinedMenuItem::separator(app)?)?;
    menu.append(&MenuItem::with_id(app, MENU_QUIT, "종료", true, None::<&str>)?)?;
    Ok(menu)
}

/// 메뉴를 통째로 다시 만든다(항목이 생기고 없어지므로).
fn refresh_tray(app: &AppHandle) {
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        match build_menu(&handle) {
            Ok(menu) => {
                if let Some(tray) = handle.tray_by_id(TRAY_ID) {
                    let _ = tray.set_menu(Some(menu));
                }
            }
            Err(e) => eprintln!("메뉴 만들기 실패: {e}"),
        }
        if lock(&handle.state::<AppState>().recording).is_none() {
            set_tooltip(&handle, store::APP_NAME);
        }
    });
}

fn on_menu_event(app: &AppHandle, event: MenuEvent) {
    match event.id().0.as_str() {
        MENU_TOGGLE => toggle_recording(app),
        MENU_PENDING => open_save(app, None),
        MENU_STORAGE => open_window(app, SETTINGS_LABEL, "settings.html", "저장 위치", 560.0, 460.0),
        MENU_LOGIN => {
            let autolaunch = app.autolaunch();
            let result = if autolaunch.is_enabled().unwrap_or(false) {
                autolaunch.disable()
            } else {
                autolaunch.enable()
            };
            if let Err(e) = result {
                notify(app, "로그인 시 실행을 바꾸지 못했어요", &e.to_string());
            }
            refresh_tray(app);
        }
        MENU_QUIT => {
            // 녹음 중이면 마무리해 Pending 에 두고 끝낸다(창은 띄우지 않음). 합치는 동안 잠깐 멈춘다.
            let recording = lock(&app.state::<AppState>().recording).take();
            if let Some(recording) = recording {
                if let Err(e) = recording.stop() {
                    eprintln!("종료 중 녹음 마무리 실패: {e:#}");
                }
            }
            app.exit(0);
        }
        _ => {}
    }
}

// MARK: - 창

fn open_window(app: &AppHandle, label: &str, page: &str, title: &str, width: f64, height: f64) {
    if let Some(window) = app.get_webview_window(label) {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
        return;
    }
    let built = WebviewWindowBuilder::new(app, label, WebviewUrl::App(page.into()))
        .title(title)
        .inner_size(width, height)
        .resizable(false)
        .center()
        .focused(true)
        .build();
    if let Err(e) = built {
        eprintln!("{label} 창 열기 실패: {e}");
    }
}

fn show_save_window(app: &AppHandle) {
    open_window(app, SAVE_LABEL, "save.html", "녹음 저장", 480.0, 460.0);
}

/// id 가 없으면 가장 오래된 분류 안 된 녹음을 연다.
/// 창이 이미 무언가를 보여 주고 있으면 내용을 바꾸지 않는다 — 새 녹음은 대기열 뒤에 넣는다.
fn open_save(app: &AppHandle, id: Option<String>) {
    let window_open = app.get_webview_window(SAVE_LABEL).is_some();
    let state = app.state::<AppState>();
    let mut save = lock(&state.save);
    if window_open && save.current.is_some() {
        if let Some(id) = id {
            if save.current.as_deref() != Some(id.as_str()) && !save.waiting.contains(&id) {
                save.waiting.push_back(id);
            }
        } else {
            drop(save);
            show_save_window(app);
        }
        return;
    }
    let id = id.or_else(|| store::pending_ids().ok().and_then(|ids| ids.into_iter().next()));
    let Some(id) = id else {
        return;
    };
    save.waiting.retain(|waiting| *waiting != id);
    save.current = Some(id);
    drop(save);
    show_save_window(app);
    if window_open {
        let _ = app.emit_to(SAVE_LABEL, PENDING_EVENT, ());
    }
}

/// 지금 녹음을 끝냈으니(저장·나중에·삭제) 대기열의 다음 녹음을 보인다. 없으면 창을 닫는다.
fn advance_save(app: &AppHandle) {
    let pending = store::pending_ids().unwrap_or_default();
    let next = {
        let state = app.state::<AppState>();
        let mut save = lock(&state.save);
        let done = save.current.take();
        let mut next = None;
        while let Some(id) = save.waiting.pop_front() {
            // 그사이 다른 곳에서 옮겨졌으면 건너뛴다.
            if Some(&id) != done.as_ref() && pending.contains(&id) {
                next = Some(id);
                break;
            }
        }
        save.current = next.clone();
        next
    };
    if next.is_some() {
        let _ = app.emit_to(SAVE_LABEL, PENDING_EVENT, ());
    } else if let Some(window) = app.get_webview_window(SAVE_LABEL) {
        let _ = window.close();
    }
}

// MARK: - 명령

#[tauri::command]
fn current_pending(state: State<'_, AppState>) -> Result<Option<PendingItem>, String> {
    let id = lock(&state.save).current.clone();
    match id {
        Some(id) => store::pending_item(&id).map(Some).map_err(error_text),
        None => Ok(None),
    }
}

#[tauri::command]
fn get_categories() -> Result<Vec<Category>, String> {
    store::load_categories().map_err(error_text)
}

#[tauri::command]
fn set_categories(categories: Vec<Category>) -> Result<Vec<Category>, String> {
    store::save_categories(categories).map_err(error_text)
}

// 창을 닫는 명령은 async 로 둔다(윈도우에서 동기 명령 안의 창 조작이 막히는 일을 피함).
#[tauri::command]
async fn save_pending(
    app: AppHandle,
    id: String,
    category_id: String,
    date: String,
    topic: String,
    attendees: String,
) -> Result<String, String> {
    let target = store::classify(&id, &category_id, &date, &topic, &attendees).map_err(error_text)?;
    advance_save(&app);
    refresh_tray(&app);
    Ok(target.to_string_lossy().into_owned())
}

#[tauri::command]
async fn later_pending(app: AppHandle) -> Result<(), String> {
    advance_save(&app);
    refresh_tray(&app);
    Ok(())
}

#[tauri::command]
async fn trash_pending(app: AppHandle, id: String) -> Result<(), String> {
    store::trash(&id).map_err(error_text)?;
    advance_save(&app);
    refresh_tray(&app);
    Ok(())
}

// MARK: - 시작

pub fn run() {
    let app = tauri::Builder::default()
        // single-instance 는 가장 먼저 붙인다.
        .plugin(tauri_plugin_single_instance::init(|_app, _args, _cwd| {}))
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _shortcut, event| {
                    if event.state() == ShortcutState::Pressed {
                        toggle_recording(app);
                    }
                })
                .build(),
        )
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, None))
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            current_pending,
            get_categories,
            set_categories,
            save_pending,
            later_pending,
            trash_pending
        ])
        .setup(|app| {
            // 녹음을 시작할 수 있게 되기(단축키·메뉴) 전에 지난번 녹음 폴더를 먼저 모은다.
            let leftovers = audio::leftover_dirs();
            let handle = app.handle().clone();
            let icon = app.default_window_icon().cloned().ok_or("기본 아이콘이 없어요")?;
            let menu = build_menu(&handle)?;
            TrayIconBuilder::with_id(TRAY_ID)
                .icon(icon)
                .tooltip(store::APP_NAME)
                .menu(&menu)
                .show_menu_on_left_click(true)
                .on_menu_event(on_menu_event)
                .build(app)?;

            // Ctrl+Alt+R — 다른 앱이 이미 쓰면 등록이 실패해도 앱은 뜬다.
            let shortcut = Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::KeyR);
            if let Err(e) = app.global_shortcut().register(shortcut) {
                eprintln!("단축키 등록 실패: {e}");
            }

            // 지난번에 끝내지 못한 녹음을 Pending 으로 보낸다(창은 띄우지 않음).
            thread::spawn(move || {
                let recovered = audio::recover(leftovers, |id| {
                    let state = handle.state::<AppState>();
                    let guard = lock(&state.recording);
                    let same = guard.as_ref().is_some_and(|recording| recording.id() == id);
                    same
                });
                if !recovered.is_empty() {
                    eprintln!("복구한 녹음 {}개", recovered.len());
                }
                refresh_tray(&handle);
            });
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("EarShot 을 시작하지 못했어요");

    // 창이 모두 닫혀도 트레이 앱은 남는다. "종료"(exit(0))만 끝낸다.
    app.run(|_app, event| {
        if let RunEvent::ExitRequested { code, api, .. } = event {
            if code.is_none() {
                api.prevent_exit();
            }
        }
    });
}
