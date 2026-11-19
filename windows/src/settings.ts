import { invoke } from "@tauri-apps/api/core";
import { open } from "@tauri-apps/plugin-dialog";

interface Category {
  id: string;
  name: string;
  path: string;
}

const MIN_CATEGORIES = 1;
const MAX_CATEGORIES = 6;
const NEW_CATEGORY_NAME = "새 분류";

function byId<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (!node) throw new Error(`#${id} 가 없어요`);
  return node as T;
}

const list = byId<HTMLUListElement>("list");
const addButton = byId<HTMLButtonElement>("add");
const errorBox = byId<HTMLParagraphElement>("error");

let categories: Category[] = [];

function showError(error: unknown): void {
  errorBox.textContent = String(error);
  errorBox.hidden = false;
}

/** 목록 전체를 저장하고, Rust 가 정리한 값(빈 경로 → 기본 경로)으로 다시 그린다. */
async function commit(next: Category[]): Promise<void> {
  try {
    categories = await invoke<Category[]>("set_categories", { categories: next });
    errorBox.hidden = true;
  } catch (error) {
    showError(error);
  }
  render();
}

function update(id: string, change: Partial<Category>): Promise<void> {
  return commit(categories.map((category) => (category.id === id ? { ...category, ...change } : category)));
}

async function chooseFolder(category: Category): Promise<void> {
  try {
    const picked = await open({
      directory: true,
      multiple: false,
      defaultPath: category.path || undefined,
      title: `${category.name} 녹음을 보낼 폴더`,
    });
    if (typeof picked === "string") await update(category.id, { path: picked });
  } catch (error) {
    showError(error);
  }
}

function row(category: Category): HTMLLIElement {
  const item = document.createElement("li");
  item.className = "row";

  const name = document.createElement("input");
  name.type = "text";
  name.value = category.name;
  name.addEventListener("change", () => {
    const trimmed = name.value.trim();
    if (!trimmed || trimmed === category.name) {
      name.value = category.name;
      return;
    }
    void update(category.id, { name: trimmed });
  });

  const path = document.createElement("span");
  path.className = "path";
  path.textContent = category.path;
  path.title = category.path;

  const choose = document.createElement("button");
  choose.type = "button";
  choose.textContent = "폴더…";
  choose.addEventListener("click", () => void chooseFolder(category));

  const remove = document.createElement("button");
  remove.type = "button";
  remove.textContent = "삭제";
  remove.disabled = categories.length <= MIN_CATEGORIES;
  remove.addEventListener("click", () => void commit(categories.filter((c) => c.id !== category.id)));

  item.append(name, path, choose, remove);
  return item;
}

function render(): void {
  list.replaceChildren(...categories.map(row));
  const full = categories.length >= MAX_CATEGORIES;
  addButton.disabled = full;
  addButton.title = full ? `분류는 최대 ${MAX_CATEGORIES}개까지예요` : "";
}

addButton.addEventListener("click", () => {
  if (categories.length >= MAX_CATEGORIES) return;
  // 경로는 비워 보내면 Rust 가 Documents\EarShot\<이름> 으로 채운다.
  void commit([...categories, { id: crypto.randomUUID(), name: NEW_CATEGORY_NAME, path: "" }]);
});

async function load(): Promise<void> {
  try {
    categories = await invoke<Category[]>("get_categories");
  } catch (error) {
    showError(error);
  }
  render();
}

void load();
