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

  const pathRow = document.createElement("div");
  pathRow.className = "row-path";
  const folderIcon = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  folderIcon.setAttribute("width", "16");
  folderIcon.setAttribute("height", "16");
  folderIcon.setAttribute("viewBox", "0 0 16 16");
  folderIcon.setAttribute("aria-hidden", "true");
  const folderShape = document.createElementNS("http://www.w3.org/2000/svg", "path");
  folderShape.setAttribute("d", "M1.5 4.5A1 1 0 0 1 2.5 3.5h3.2l1.3 1.5h6.5a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1z");
  folderShape.setAttribute("fill", "none");
  folderShape.setAttribute("stroke", "currentColor");
  folderShape.setAttribute("stroke-width", "1.1");
  folderShape.setAttribute("stroke-linejoin", "round");
  folderIcon.append(folderShape);

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
  remove.className = "subtle icon danger";
  remove.title = "삭제";
  remove.setAttribute("aria-label", "삭제");
  remove.innerHTML =
    '<svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5M6.8 7v4M9.2 7v4" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  remove.disabled = categories.length <= MIN_CATEGORIES;
  remove.addEventListener("click", () => void commit(categories.filter((c) => c.id !== category.id)));

  const top = document.createElement("div");
  top.className = "row-top";
  top.append(name, choose, remove);
  pathRow.append(folderIcon, path);
  item.append(top, pathRow);
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
