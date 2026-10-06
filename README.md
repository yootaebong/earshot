<p align="center"><img src="docs/icon.png" width="128" alt="EarShot icon"></p>

# EarShot 👂

> A macOS menu bar app that records your meetings with one shortcut and files them into folders you choose.

**English** · [한국어](README.ko.md)

<p align="center"><img src="docs/demo.gif" width="720" alt="EarShot demo: menu, save window and category settings"></p>

EarShot records meetings you join on your Mac — Slack huddles, Zoom, Google Meet and so on — capturing **both the other people (app audio) and you (microphone)**.
When you stop, it converts the recording (with a progress readout in the menu bar) and sends a notification. Click it whenever you are ready to add a topic and attendees, and EarShot moves the recording into one of your categories (for example a work folder or a NAS share), where you can transcribe or archive it however you like.

```
⌃⌥R  ──▶  recording  ──▶  ⌃⌥R  ──▶  converting 37%  ──▶  notification  ──▶  save window (date · topic · attendees)  ──▶  [Work] / [Personal] / …  ──▶  your folder
```

> [!IMPORTANT]
> **Get consent before you record.** Recording a conversation without the other participants' permission may be illegal where you or they live.
> Tell everyone in the meeting that you are recording, and follow your local laws and your organization's policies. You are responsible for how you use this app.

## Features

| | |
|---|---|
| 🎙️ **Manual recording** | `⌃⌥R` (control + option + R) or "Start Recording" in the menu. Works whichever app is in front |
| 🔊 **Two sources, one file** | Meeting-app audio via a Core Audio process tap, your voice via the microphone. Mixed into a single m4a at the end |
| 🧭 **Meeting app detection** | If a meeting app (Zoom, Slack, Chrome, Safari, Arc, Edge) is using the microphone, only that app is recorded; otherwise the whole Mac |
| ↔️ **You left, others right** | The saved file puts your microphone on the left channel and the meeting audio on the right, so a transcription tool can tell who spoke. Turn it off under "Audio Source" to get a normal mix. "Microphone only" recordings are not split. Without headphones, the other side leaks into your microphone a little |
| 🎚️ **Device choice** | "Microphone" menu (system default or a specific device) and "Audio Source" menu (meeting app / entire Mac / microphone only) |
| 📊 **Level meters** | Mac audio and microphone levels in the menu while recording. Notifies you if one side stays silent for 15 seconds |
| 🔌 **Survives device changes** | Switching earphones or Bluetooth splits the recording into pieces and joins them at the end |
| 🛟 **Crash recovery** | If the app dies mid-recording, the leftover pieces are saved on the next launch |
| ⏳ **Conversion progress** | After you stop, the menu bar shows the conversion progress (a two-hour meeting takes about 40 seconds) |
| 🗂️ **Save when you are ready** | No window pops up over your screen after a meeting — you get a notification instead. Click it (or pick the recording from the "Unsorted" menu) to open the save window: date and time (prefilled with the start time), topic, attendees → pick a category. "Later" keeps it in "Unsorted" |
| 🏷️ **Your own categories** | Rename, add (up to 6) or remove categories and choose a folder for each in Settings |
| 📤 **Reliable delivery** | If a folder is unavailable (e.g. a NAS volume isn't mounted), files wait in an outbox and are retried every 60 seconds and whenever a volume mounts. A file that fails 5 times for the same reason is moved aside to "Failed to Send" |
| 🚀 **Launch at login** | Starts with your Mac and restarts if it crashes (quitting from the menu keeps it off) |
| 🌐 **English and Korean** | Follows your macOS language |

Recordings shorter than 30 seconds are discarded.

## File names

```
2026-10-02-1249-Zoom-Weekly sync-with Alice,Bob.m4a
└── start time ─┘ └app┘ └ topic ─┘ └─ attendees ─┘
```

Characters such as `/ : \ * ? " < > |` are removed, and names longer than 200 bytes are shortened. If the name already exists, `-2`, `-3`, … is appended.
The attendee list is part of the name so that downstream tools (for example a transcription script) can pick it up.

## Where files go

| Location | What |
|---|---|
| `~/Documents/EarShot/<category>` | Default destination for each category. Change it in Settings (menu "Save Locations…") — any folder works, including a mounted NAS share |
| `~/Library/Application Support/EarShot/Recording/` | Pieces being recorded (.caf) |
| `~/Library/Application Support/EarShot/Pending/` | Finished m4a files waiting to be sorted |
| `~/Library/Application Support/EarShot/Outbox/<category>/` | Files waiting to be delivered (menu "Waiting to Send") |
| `~/Library/Application Support/EarShot/Outbox/실패/` | Files that could not be delivered (menu "Failed to Send") |
| `~/Library/Logs/EarShot/detect.log` | App log (menu "Open Detection Log") |

Missing destination folders inside your home folder are created automatically. Folders on external or network volumes (`/Volumes/…`) and cloud-synced folders (`~/Library/CloudStorage/…`) are not — EarShot waits until they are available.

## Install

EarShot is distributed as source only — there is no notarized download. Build it yourself:

Requirements: macOS 14.2+, Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

```sh
git clone https://github.com/yootaebong/earshot.git
cd earshot
xcodegen generate
xcodebuild -project EarShot.xcodeproj -scheme EarShot -configuration Release -derivedDataPath build build
cp -R build/Build/Products/Release/EarShot.app /Applications/
open /Applications/EarShot.app
```

### Code signing

`project.yml` signs the app with a self-signed certificate named **`EarShot Local Signing`** in your login keychain.
With ad-hoc signing, macOS forgets the microphone and system-audio permissions on every rebuild, so a stable local certificate saves you from re-granting them. Create it once per Mac:

```sh
cat > /tmp/c.cnf <<'CNF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=EarShot Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/k.pem -out /tmp/c.pem -days 3650 -config /tmp/c.cnf
openssl pkcs12 -export -legacy -inkey /tmp/k.pem -in /tmp/c.pem -out /tmp/c.p12 -passout pass:earshot
security import /tmp/c.p12 -k ~/Library/Keychains/login.keychain-db -P earshot -T /usr/bin/codesign
rm /tmp/c.cnf /tmp/k.pem /tmp/c.pem /tmp/c.p12
```

To build without the certificate, pass `CODE_SIGN_IDENTITY="-"` to `xcodebuild` (you will need to re-grant permissions after each rebuild).

## Permissions

macOS asks twice the first time you record. Allow both:

- **Microphone** — your voice
- **System Audio Recording** — the meeting app's audio. Without it, EarShot records silence with no error

## Troubleshooting

| Symptom | Check |
|---|---|
| Other people aren't recorded | System Settings → Privacy & Security → Screen & System Audio Recording → allow EarShot |
| Your voice isn't recorded | Pick the right device in the "Microphone" menu and watch the microphone meter while recording |
| File doesn't show up in the folder | Is the destination volume mounted? Check "Waiting to Send" and "Failed to Send" in the menu |
| Shortcut does nothing | Another app may be using `⌃⌥R`. "Start Recording" in the menu always works |
| Anything else | Menu "Open Detection Log" |

## Project layout

| File | Role |
|---|---|
| `App/EarShotApp.swift` | Menu bar UI, single-instance lock |
| `App/RecordingController.swift` | Start/stop, splitting into pieces, recovery, mixing to m4a |
| `App/AppAudioTap.swift` | App / Mac audio via Core Audio process taps |
| `App/MicRecorder.swift` | Microphone via AVAudioEngine |
| `App/MicMonitor.swift` | Detects which app is using the microphone, logging |
| `App/SaveWindow.swift` | Save window and the unsorted queue |
| `App/Delivery.swift` | Delivery, retries, file names |
| `App/Settings.swift` | Categories and folders, microphone, capture source |
| `App/LoginItem.swift` | LaunchAgent for launch at login and auto-restart |
| `App/GlobalHotKey.swift` | Global shortcut |
| `App/AudioCapturePermission.swift` | System audio recording permission |
| `App/Localizable.xcstrings` | English / Korean strings |

## License

[MIT](LICENSE)
