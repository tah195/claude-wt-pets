[한국어](README.md) | **English**

# claude-wt-pets

One pet per Claude Code session. Ctrl+click a pet and the Windows Terminal window running that session comes to the front. Even after you merge tabs into one window and split them apart again, each pet finds its own session's window.

> Detailed documents (spec, design notes, how-it-was-solved) are written in Korean. This README covers installation, usage, and the core ideas.

**Status: feature-complete, maintenance only.** Only bug fixes and compatibility updates for Windows Terminal / Claude Code changes. Features outside the supported scope will not be added ([Limitations](#limitations)).

A Windows tool that shows your Claude Code session state as a desktop pet, driven by Claude Code hooks. Without Alt+Tabbing to the terminal, you can tell at a glance whether Claude is working, has finished, or needs your attention.

<!-- TODO: screenshot/GIF -->

## Features

- One pet per Claude Code session, up to 4 at once
- 7 states: `idle`, `thinking`, `done`, `notification`, `sleeping`, `error`, `disconnected` ([STATES.md](STATES.md), Korean)
- Ctrl+click → bring that session's Windows Terminal window to the front (window level; selecting the tab inside is not supported)
- Double-click → back to `idle`, drag → move
- Right-click menu: reset state / bring terminal window to front / character / settings / exit
- Always on top, hidden from the taskbar and Alt+Tab
- Per-slot character, placement, and size (size and placement apply immediately without restart)

## Requirements

| Item | Requirement |
| --- | --- |
| OS | Windows 10/11 |
| Terminal | Windows Terminal |
| Shell | Windows PowerShell 5.1 or pwsh (run `claude` in a Windows Terminal tab) |
| Runtime | Node.js (`node` on PATH or `C:\Program Files\nodejs\node.exe`) |
| Target | Claude Code CLI |

Git Bash, the Claude Desktop built-in terminal, and other AI CLIs are not supported. In unsupported environments the hook runs but exits quietly without showing a pet. See [docs/support-scope.md](docs/support-scope.md) (Korean) for why.

## Install

```powershell
git clone https://github.com/<owner>/claude-wt-pets.git
cd claude-wt-pets
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\install-hooks.ps1 -Scope user
```

`install-hooks.ps1` adds 8 hooks (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `StopFailure`, `PostToolUseFailure`, `Notification`) to `%USERPROFILE%\.claude\settings.json`. It backs up the existing file to `%USERPROFILE%\.claude\backups\` first and leaves your other settings and hooks untouched. If `settings.json` is not valid JSON, it changes nothing and stops; fix the file and run it again.

The hooks contain the **absolute path** of the cloned folder. If you move the folder, run the install command again.

Check the installation:

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\install-hooks.ps1 -Scope user -Audit
```

After installing, start `claude` in Windows Terminal and the pet appears. The first appearance can take a few seconds because of PowerShell/WPF cold start.

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\install-hooks.ps1 -Uninstall
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\install-hooks.ps1 -Uninstall -Audit
```

This removes only this tool's hooks from both user and project settings. Then delete the folder.

## Characters

The sample character `happycat`, made by the author, is included. To add your own, see [characters/README.md](characters/README.md) (Korean). In short: one folder per character under `characters/`, containing `idle.png` plus optional PNGs named after the other states; missing states fall back to `idle.png`.

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\set-character.ps1 -List
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\set-character.ps1 -Slot 2 -Character happycat
```

## Settings

Change them from the pet's right-click → `설정` (Settings), or with the CLI below. Defaults live in `config.default.json`; your first change creates the user file `config.json`. `config.json` is git-ignored, so changing settings never conflicts with `git pull`. Do not edit `config.default.json`.

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\set-placement.ps1 -Show
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\set-placement.ps1 -Anchor bottom-right -Direction left
```

| Key | Meaning |
| --- | --- |
| `defaultCharacter` | Character used when a slot has none (default `happycat`) |
| `slotCharacters` | Character per slot (1–4) |
| `placement.anchor` | `bottom-left` / `bottom-right` / `top-left` / `top-right` |
| `placement.offsetX`, `offsetY`, `slotGap` | Screen-edge margins and gap between pets (px) |
| `placement.direction` | Direction pets line up: `left` / `right` |
| `petSize` | Pet size (px, shared by all pets, default 120) |

## How it works

```text
Claude Code hook -> hook-entry.ps1 -> notifier.js -> %TEMP% state/registry -> pet.ps1 (WPF)
```

Showing state is simple: on each hook, `notifier.js` writes a per-session state file, and the pet reads it and switches its image.

The hard part is **"which Windows Terminal window is this pet's session in?"** Windows Terminal offers no API that maps a process to its window, and merging or splitting tabs changes which window holds a session. This tool handles it with three principles:

- **Resolve only on click.** Tracking the window continuously creates races and tab-title flicker by itself. The owner window only has to be exact when you Ctrl+click, so it is resolved only then.
- **Read, don't write.** Reading each window's tab strip through UI Automation shows inactive tab names too, so the window holding the session can be found even in a merged window, without touching the console.
- **Never confirm by guessing.** A window is brought forward only when verifiable evidence yields exactly one candidate. If unknown, it reports `disconnected` instead of raising the wrong window.

What was tried and abandoned on the way to these principles is in [docs/how-it-was-solved.md](docs/how-it-was-solved.md) (Korean).

| File | Role |
| --- | --- |
| `hook-entry.ps1` | Hook entry point, environment check, owner window probe, pet launch |
| `notifier.js` | Hook payload parsing, slot assignment, state/registry writes |
| `pet.ps1` | WPF pet UI, state display, window focus, exit detection |
| `WtPets.Common.ps1` | Shared settings/character helpers |
| `install-hooks.ps1` | Hook install/audit/uninstall |
| `set-character.ps1`, `set-placement.ps1` | Settings CLI |
| `launch-pet.ps1`, `pet-debug.ps1` | Manual launch/debug |

Temporary files are created as `%TEMP%\claude-wt-pets-*`; state transitions are logged to `%TEMP%\claude-wt-pets-transition.log`.

## Development

```powershell
node --check .\notifier.js
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\test-notifier.ps1
```

The detailed spec is [docs/feature-spec.md](docs/feature-spec.md) and the manual QA checklist is [docs/qa-checklist-2026-07-08.md](docs/qa-checklist-2026-07-08.md) (both Korean). Rules for modifying this repo with AI tools are in [CLAUDE.md](CLAUDE.md).

## Limitations

- Tabs inside Windows Terminal are not selected. When several Claude tabs share one window, bringing that window to the front is the expected behavior ([TAB-MOVEMENT-NOTES.md](TAB-MOVEMENT-NOTES.md), Korean).
- Sessions beyond the 4th get no pet.
- This is not an official Anthropic tool.

## License

[MIT](LICENSE)
