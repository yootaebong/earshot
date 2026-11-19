import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";

// @ts-expect-error process 는 node 전역(이 파일은 tsc 검사 대상이 아니다)
const host = process.env.TAURI_DEV_HOST;

// 창 두 개(save·settings)를 각각 html 입구로 묶는다.
export default defineConfig({
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    host: host || false,
    hmr: host ? { protocol: "ws", host, port: 1421 } : undefined,
    watch: { ignored: ["**/src-tauri/**"] },
  },
  build: {
    target: "es2021",
    rollupOptions: {
      input: {
        save: fileURLToPath(new URL("./save.html", import.meta.url)),
        settings: fileURLToPath(new URL("./settings.html", import.meta.url)),
      },
    },
  },
});
