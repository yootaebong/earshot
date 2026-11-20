# EarShot for Windows (1단계)

맥 메뉴바 앱 EarShot 의 윈도우판 뼈대. Tauri 2 트레이 앱이다.

## 빌드

Windows 10 이상, Rust(MSVC)·Node·pnpm 이 필요하다.

```
pnpm install
pnpm tauri build
```

설치 파일(NSIS)은 `src-tauri/target/release/bundle/nsis/` 에 나온다.

## 1단계 범위

- 트레이 메뉴: 녹음 시작/멈추기, 분류 안 됨 N개 저장…, 저장 위치…, 로그인 시 실행, 종료
- 전역 단축키 Ctrl+Alt+R 로 녹음 토글
- 마이크 + 기본 출력 장치 loopback(WASAPI)을 함께 녹음 → 스테레오 48kHz 16비트 wav(왼쪽 마이크, 오른쪽 시스템)
- 30초 미만은 버림, 저장 창에서 날짜·주제·참석자를 적고 분류 폴더로 보냄
- 앱이 죽었다 다시 켜지면 남은 녹음을 Pending 으로 복구

데이터 위치: 녹음 `%LOCALAPPDATA%\EarShot\Recording`·`Pending`, 설정 `%APPDATA%\EarShot\settings.json`

다음 단계: 앱별 캡처, 받아쓰기, m4a 인코딩.

## 제한사항

- 녹음 중 기본 입력·출력 장치가 바뀌면 따라가지 않는다. 시작할 때 열린 장치로 계속 녹음한다.
- 마이크와 시스템 소리는 각 장치의 캡처 시각으로 맞춘다. 장치 클럭이 조금씩 어긋나는 것(드리프트)은 보정하지 않아 긴 녹음에서는 두 채널이 조금씩 벌어질 수 있다.
- wav(헤더 4GB 한도) 때문에 한 녹음은 약 6시간이 상한이다.
- 분류 폴더로 옮기기에 실패하면 Pending 에 남을 뿐, 자동으로 다시 보내지(재시도) 않는다.
- 분류 폴더 경로와 파일 이름을 합쳐 260자를 넘을 수 있다(긴 경로를 켜지 않은 윈도우에서는 저장 실패).

## 아이콘

`src-tauri/icons/` 는 맥 앱 아이콘(`app-icon.png`)에서 `pnpm tauri icon app-icon.png` 로 만든다.
