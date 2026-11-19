import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { confirm } from "@tauri-apps/plugin-dialog";

interface PendingItem {
  id: string;
  appName: string;
  duration: number;
  localInput: string;
}

interface Category {
  id: string;
  name: string;
  path: string;
}

const PENDING_EVENT = "pending-changed";
const SECONDS_PER_MINUTE = 60;

function byId<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (!node) throw new Error(`#${id} 가 없어요`);
  return node as T;
}

const summary = byId<HTMLParagraphElement>("summary");
const form = byId<HTMLFormElement>("form");
const dateInput = byId<HTMLInputElement>("date");
const topicInput = byId<HTMLInputElement>("topic");
const attendeesInput = byId<HTMLInputElement>("attendees");
const laterButton = byId<HTMLButtonElement>("later");
const trashButton = byId<HTMLButtonElement>("trash");
const categoriesBox = byId<HTMLDivElement>("categories");
const errorBox = byId<HTMLParagraphElement>("error");

let current: PendingItem | null = null;
let busy = false;

function durationText(seconds: number): string {
  const minutes = Math.floor(seconds / SECONDS_PER_MINUTE);
  const rest = seconds % SECONDS_PER_MINUTE;
  return minutes > 0 ? `${minutes}분 ${rest}초` : `${rest}초`;
}

function showError(error: unknown): void {
  errorBox.textContent = String(error);
  errorBox.hidden = false;
}

function setDisabled(disabled: boolean): void {
  document.querySelectorAll("button").forEach((button) => {
    button.disabled = disabled;
  });
}

function categoryButton(category: Category): HTMLButtonElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "primary";
  button.textContent = category.name;
  button.title = category.path;
  button.addEventListener("click", () => void save(category.id));
  return button;
}

async function load(): Promise<void> {
  errorBox.hidden = true;
  try {
    const [item, categories] = await Promise.all([
      invoke<PendingItem | null>("current_pending"),
      invoke<Category[]>("get_categories"),
    ]);
    // 같은 녹음을 다시 읽으면 입력 중인 주제·참석자를 지우지 않는다.
    const same = current !== null && item !== null && current.id === item.id;
    current = item;
    if (!item) {
      summary.textContent = "저장할 녹음이 없어요";
      categoriesBox.replaceChildren();
      return;
    }
    summary.textContent = `${item.appName} · ${durationText(item.duration)}`;
    categoriesBox.replaceChildren(...categories.map(categoryButton));
    if (same) return;
    dateInput.value = item.localInput;
    topicInput.value = "";
    attendeesInput.value = "";
    topicInput.focus();
  } catch (error) {
    // 이전 녹음의 분류 버튼으로 잘못 저장하지 않게 비운다.
    current = null;
    categoriesBox.replaceChildren();
    showError(error);
  }
}

/** 버튼을 잠그고 한 번만 실행한다. 성공하면 Rust 쪽이 창을 닫는다. */
async function run(action: () => Promise<unknown>): Promise<void> {
  if (busy) return;
  busy = true;
  setDisabled(true);
  errorBox.hidden = true;
  try {
    await action();
  } catch (error) {
    showError(error);
  } finally {
    busy = false;
    setDisabled(false);
  }
}

async function save(categoryId: string): Promise<void> {
  const item = current;
  if (!item) return;
  if (!dateInput.value) {
    showError("날짜·시간을 넣어 주세요");
    return;
  }
  await run(() =>
    invoke("save_pending", {
      id: item.id,
      categoryId,
      date: dateInput.value,
      topic: topicInput.value,
      attendees: attendeesInput.value,
    }),
  );
}

async function later(): Promise<void> {
  await run(() => invoke("later_pending"));
}

async function trash(): Promise<void> {
  const item = current;
  if (!item || busy) return;
  // 확인 창을 기다리는 동안 잠가 두 번 뜨지 않게 한다.
  busy = true;
  setDisabled(true);
  let ok = false;
  try {
    ok = await confirm("Pending\\Trash 폴더로 옮겨요. 거기서 되살릴 수 있어요.", {
      title: "이 녹음을 삭제할까요?",
      kind: "warning",
      okLabel: "삭제",
      cancelLabel: "취소",
    });
  } catch (error) {
    showError(error);
  } finally {
    busy = false;
    setDisabled(false);
  }
  if (!ok || current?.id !== item.id) return;
  await run(() => invoke("trash_pending", { id: item.id }));
}

form.addEventListener("submit", (event) => event.preventDefault());
laterButton.addEventListener("click", () => void later());
trashButton.addEventListener("click", () => void trash());
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") void later();
});

void listen(PENDING_EVENT, () => void load());
void load();
