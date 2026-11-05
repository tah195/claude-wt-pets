# claude-wt-pets 기능명세서

## 1. 목적

claude-wt-pets는 Claude Code hook 이벤트를 받아 Windows desktop pet으로 현재 session 상태를 표시한다. 사용자는 터미널을 직접 보지 않아도 Claude가 작업 중인지, 응답이 끝났는지, 사용자 확인이 필요한지, 창 연결이 끊겼는지를 확인할 수 있다.

## 2. 공식 지원 범위

- 지원 환경: Windows Terminal + PowerShell/pwsh + Claude Code의 교집합
- 지원 단위: Windows Terminal top-level window
- 최대 session 수: 4개 slot
- 미지원 환경: Git Bash, Claude Desktop 내부 터미널, Codex/Gemini session

미지원 환경에서 hook 일부가 실행될 수는 있지만, state/registry/pet을 만들지 않는다. `hook-entry.ps1`은 Claude session process, PowerShell parent process, visible Windows Terminal 창을 확인하지 못하면 `skip-unsupported-environment` transition log를 남기고 종료한다.

## 3. 전체 처리 구조

```text
Claude Code hook
  -> hook-entry.ps1
  -> notifier.js
  -> %TEMP% registry/state files
  -> pet.ps1
  -> Windows WPF pet
```

### 3.1 hook-entry.ps1

- Claude hook command의 단일 진입점이다.
- 지원 환경을 검사한다.
- Node 실행 파일을 찾는다.
- `SessionStart`, `UserPromptSubmit`, `PreToolUse`에서 owner probe 정보를 수집한다.
- stdin hook payload를 `notifier.js`에 전달한다.
- registry에서 slot을 확인하고 `pet.ps1`을 hidden 방식으로 실행한다.

### 3.2 notifier.js

- hook payload를 해석한다.
- session id 기준으로 slot을 배정한다.
- state file과 session registry를 atomic write 방식으로 갱신한다.
- owner window 정보를 해석하고 owner-map을 갱신한다.
- 죽은 session/state/pid를 정리한다.
- pet process를 직접 관리하지 않고, state/registry 기록을 책임진다.

### 3.3 pet.ps1

- slot별 WPF pet 창을 표시한다.
- state file을 polling해 이미지와 상태를 갱신한다.
- taskbar와 Alt+Tab에서 pet을 숨긴다.
- topmost overlay 상태를 유지한다.
- drag, double-click reset, Ctrl+click focus, context menu를 처리한다.
- session 종료와 owner 연결 실패를 감지한다.

### 3.4 주요 파일

| 파일 | 역할 |
| --- | --- |
| `hook-entry.ps1` | Claude hook 진입점, 환경 판정, owner probe 수집, notifier/pet 실행 |
| `notifier.js` | hook payload 해석, slot/registry/state 기록, owner 해석, stale cleanup |
| `pet.ps1` | WPF pet UI, state polling, focus/복구/종료 처리 |
| `WtPets.Common.ps1` | 공통 설정/파일/캐릭터 helper |
| `config.default.json` | 캐릭터, 배치, pet size 기본값 (저장소에 포함) |
| `config.json` | 사용자 설정 (git 제외). 없으면 `config.default.json`을 읽고, 설정 저장 시 생성된다 |
| `install-hooks.ps1` | Claude settings direct hook 설치/audit/제거(`-Uninstall`). 재설치 시 기존 claude-wt-pets hook 중복 제거. settings 파일이 JSON으로 읽히지 않으면 아무것도 바꾸지 않고 중단 |
| `set-character.ps1` | 캐릭터 설정 CLI |
| `set-placement.ps1` | 생성 위치 설정 CLI |
| `launch-pet.ps1` | 수동 확인/디버그용 launcher |
| `pet-debug.ps1` | slot별 pet 디버그 실행 (`%TEMP%\claude-wt-pets-pet-debug-{slot}.log`) |

## 4. Hook 이벤트 명세

| 이벤트 | 기대 동작 | owner probe |
| --- | --- | --- |
| `SessionStart` | session/slot 생성, 초기 state 기록, pet 실행 | 수집 |
| `UserPromptSubmit` | `thinking` 전환, owner 갱신 | 수집 |
| `PreToolUse` | `thinking` 유지, owner 갱신 | 수집 |
| `PostToolUse` | `thinking` 유지 | 미수집 |
| `Stop` | `done` 전환 | 미수집 |
| `Notification` | 사용자 조치 필요 알림을 `notification` 표시 | 미수집 |
| `PostToolUseFailure` | `error` 전환 | 미수집 |
| `StopFailure` | `error` 전환 | 미수집 |

`Claude is waiting for your input` 메시지는 현재 상태가 `done`이 아닐 때만 `notification`으로 표시한다. `done` 상태에서는 동일 의미의 알림이므로 무시한다. 그 외 `Notification` hook 메시지는 상태와 무관하게 `notification`으로 전환한다.

## 5. 상태 모델

| 상태 | 의미 | 발생 조건 | 자동 해제 |
| --- | --- | --- | --- |
| `idle` | 기본 대기 | `SessionStart`, pet reset, 기본 상태 복귀 | 300초 후 `sleeping` 가능 |
| `thinking` | Claude 작업 중 | `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | 다음 hook에 따라 변경 |
| `done` | 응답 완료 | `Stop` | 자동 해제 없음 |
| `notification` | 사용자 조치 필요 | 표시 대상 `Notification` | 다음 prompt/tool hook |
| `sleeping` | idle 장기 대기 | `idle`에서 300초 경과 | 다음 hook 또는 reset |
| `error` | Claude/tool 실패 | `PostToolUseFailure`, `StopFailure` | reset 또는 다음 hook |
| `disconnected` | owner 창 연결 실패 | focus/복구 실패 | 새 hook에서 owner/state 확정 또는 reset |

상태 이미지가 없으면 같은 캐릭터의 `idle.png`를 fallback으로 사용한다.

## 6. Session/Slot 모델

- session은 Claude hook payload의 session 식별자를 기준으로 추적한다.
- slot은 1부터 4까지 사용한다.
- 빈 slot 중 가장 앞 번호를 배정한다.
- 같은 session은 기존 slot을 재사용한다.
- 4개 slot이 모두 사용 중이면 5번째 session은 무시한다.
- over-capacity session은 registry/state/pet을 만들지 않고 transition log에만 기록한다.

### 6.1 Slot별 파일

```text
%TEMP%\claude-wt-pets-state-{slot}.json
%TEMP%\claude-wt-pets-pet-{slot}.pid
```

### 6.2 전체 registry 파일

```text
%TEMP%\claude-wt-pets-registry.json
%TEMP%\claude-wt-pets-owner-map.json
```

registry는 활성 session/slot 정보를 보관한다. owner-map은 last-known-good owner handle을 보관한다.

## 7. Owner Window 모델

owner window는 pet이 어느 Windows Terminal 창과 연결되는지 나타낸다. claude-wt-pets는 특정 tab 내부 선택을 지원하지 않고 top-level Windows Terminal 창만 앞으로 가져온다.

tab 단위 owner 식별/선택은 지원 범위에서 제외한다. Windows Terminal tab은 안정적으로 저장하고 foreground 제어할 수 있는 top-level window handle이 아니며, 현재 보장 가능한 동작은 `SetForegroundWindow(owner_hwnd)`로 창을 앞으로 가져오는 것까지다. `session marker`와 `tab title`은 tab 선택 기능이 아니라 top-level owner window를 찾기 위한 보조 근거로만 사용한다.

### 7.1 Owner capture 우선순위 (hook-entry.ps1 → notifier.js)

hook 실행 시 `hook-entry.ps1`이 owner probe를 수집하고, `notifier.js`가 아래 순서로 해석한다.

1. **session marker** — `hook-entry.ps1`이 parent process에 `AttachConsole`/`SetConsoleTitle`로 마커를 심고, visible Windows Terminal 창 중 마커를 포함하는 창을 매칭한다. 복수 창이 있을 때 정확한 owner를 식별하는 핵심 경로다.
2. **owner-map last-known-good** — 이전 hook에서 저장한 owner-map 기록을 재사용한다. visible window 목록에 해당 hwnd가 있고, 저장된 window title과 현재 title이 호환되어야 한다.

foreground window와 단일 unused visible window는 현재 session의 owner라는 보장이 없으므로 owner 확정 근거로 사용하지 않는다.

### 7.2 Owner 복구 (pet.ps1) — 클릭 시점 해석

pet은 owner window를 상시 추적하지 않는다. owner 재해석(probe)은 **focus 요청 시점에만** 수행한다 — Ctrl+click 또는 우클릭 `터미널 창 앞으로 가져오기`. 그 외 시간에 pet은 hook이 state 파일에 기록한 owner를 passive하게 넘겨받기만 한다 (`Refresh-OwnerFromState`, probe 없음).

focus 시점 복구는 아래 trusted 순서로만 시도한다.

1. **tab strip (UIA)** — visible Windows Terminal 창들의 tab strip(TabItem 이름)을 UI Automation으로 읽기 전용 열거해, `Claude #slot` 정확 매칭 또는 저장된 tab title 호환 매칭되는 탭이 들어 있는 창을 찾는다. window title과 달리 **비활성 탭도 보이고** 제목을 쓰지 않으므로 깜빡임이 없다. 매칭 창이 정확히 1개일 때만 채택하며, 다른 slot이 사용 중인 창은 tab strip에 다른 slot 탭이 함께 보이거나 병합 상태일 때만 `tab-strip-shared`로 허용한다. 전체 열거 1.5초 예산 초과·UIA 실패 시 다음 단계로 넘어간다.
2. **session marker** — pet이 직접 parent console에 마커를 심어 owner를 재식별한다. tab strip이 유일 후보를 내지 못할 때(수동 개명, 중복 제목, UIA 실패)의 fallback이다.
3. **owner-map** — 저장된 last-known-good hwnd가 visible하고 다른 slot에서 사용 중이 아니면 복구한다.
4. **tab title** — window title(활성 탭) 일치로 찾는다.

복구 중 저장된 window title과 현재 title이 호환되지 않으면 해당 후보를 건너뛴다 (title conflict guard). `__claude_wt_pets_` probe marker와 다른 slot의 `Claude #N` title은 owner-map/state에 저장하지 않고, 기존 state에 남아 있던 오염 title도 다음 state 저장 때 보존하지 않는다. pet 시작 시에도 현재 state를 기준으로 owner-map을 한 번 동기화해 이전 버전이 남긴 오염 title을 정리한다. session marker probe가 console title을 복원할 때 기존 제목이 이미 `__claude_wt_pets_`로 오염되어 있으면 `tab_title`, `window_title`, `Claude #slot`, `Claude Code` 순서로 안전한 제목을 복원한다. 방금 session marker probe로 찾은 동일 hwnd가 Windows Terminal title 반영 지연 때문에 `__claude_wt_pets_` marker를 잠깐 보여주는 경우에는 5초까지만 transient 상태로 보고 저장 없이 허용한다. shared owner source는 focus 시점에 재증명하며(병합 유지 또는 다른 slot과의 실제 공유 확인), 창 분리 후에는 `IsWindow`가 살아 있어도 trusted 재확인에 실패하면 `disconnected`로 남긴다. 복구 실패 시 `disconnected`로 전환한다 — `disconnected`는 focus 실패 시에만 발생한다.

ownerTimer는 **생명주기 전용**이다: session process 소실 감지와 grace/종료 판정, owner hwnd/pid의 생존 확인(`IsWindow`/`Get-Process`)만 수행한다. owner 재해석·owner-map 감시·window-set 감시·주기적 marker probe를 하지 않으며, `disconnected` 표시를 만들지 않는다. owner 창이 사라지면 내부적으로 stale 처리 후 session 생존 여부에 따라 대기(wait-anchor)하거나 종료한다.

foreground/process/screen-order 복구는 병합/분리 후 오포커싱을 만들 수 있으므로 사용하지 않는다 (해당 코드는 제거됨). 이전 상태가 정확하다고 보장할 수 없으면 pet/state/pid를 유지하고 `disconnected`를 유지한다.

복구 실패 자체는 Claude 오류가 아니므로 `error`가 아니라 `disconnected`를 사용한다.

### 7.3 Focus 동작

- Ctrl+click 또는 우클릭 `터미널 창 앞으로 가져오기`로 owner Windows Terminal 창을 foreground로 가져온다.
- 같은 Windows Terminal 창 안에 여러 Claude tab이 있으면 모두 같은 top-level 창을 focus한다.
- tab 내부 직접 선택은 지원하지 않으며, tab 미전환은 정상 동작이다.

## 8. 캐릭터 모델

캐릭터는 `characters/` 하위 폴더로 관리한다.

```text
characters/
  happycat/
    idle.png
    thinking.png
    done.png
    notification.png
    sleeping.png
    error.png
    disconnected.png
```

- dot으로 시작하는 폴더는 후보에서 제외한다.
- slot 기본 캐릭터는 `config.json`의 `slotCharacters`를 따른다.
- 우클릭 `캐릭터` 메뉴에서 바꾼 값은 즉시 현재 pet에 반영되고 `config.json`의 해당 slot `slotCharacters`에 영구 저장된다 (2026-04-27 결정: 설정 창의 캐릭터 항목을 우클릭 메뉴로 이관).
- 일부 상태 이미지가 없는 캐릭터는 같은 캐릭터의 `idle.png` fallback으로 표시한다.
- 저장소에는 직접 만든 샘플 캐릭터 `happycat`(7상태 이미지 전부 포함)만 들어 있다. 다른 캐릭터는 같은 구조의 폴더를 `characters/`에 추가하면 메뉴에 나타난다.

## 9. 설정 모델

### 9.1 config.json

설정 파일은 두 개다.

- `config.default.json`: 저장소에 포함된 기본값. 직접 고치지 않는다.
- `config.json`: 사용자 설정. git에서 제외된다(`.gitignore`). 우클릭 캐릭터 메뉴, 설정 창, CLI로 저장할 때 생성·갱신된다.

읽기 규칙: `config.json`이 있으면 그 파일만 읽고, 없으면 `config.default.json`을 읽는다(`WtPets.Common.ps1` `Get-WtPetsConfigReadPath`, `notifier.js` `loadConfig`). 저장은 항상 `config.json`에 한다. 읽은 파일에 없는 항목은 코드 기본값으로 채운다.

아래는 구조 예시다. 실제 값은 사용자 설정(우클릭 캐릭터 메뉴, 설정 창, CLI)에 따라 달라진다. `slotCharacters`에 없는 slot은 `defaultCharacter`를 쓴다. `mycat`은 사용자가 `characters/`에 직접 추가한 캐릭터 폴더의 예시다.

```json
{
  "defaultCharacter": "happycat",
  "slotCharacters": {
    "2": "mycat"
  },
  "placement": {
    "anchor": "bottom-left",
    "offsetX": 10,
    "offsetY": 10,
    "slotGap": 10,
    "direction": "right"
  },
  "petSize": 120
}
```

### 9.2 CLI 설정

- `set-character.ps1 -List`: 사용 가능한 캐릭터 목록 확인
- `set-character.ps1 -Slot <n> -Character <name>`: slot별 캐릭터 저장
- `set-character.ps1 -Slot <n> -ClearSlot`: slot override 제거
- `set-character.ps1 -Default <name>`: `defaultCharacter` 저장
- `set-placement.ps1 -Show`: 현재 배치 설정 확인
- `set-placement.ps1`: anchor, offset, gap, direction 저장

### 9.3 Settings UI

pet 우클릭 `설정` 메뉴로 설정 창을 연다. 저장 항목은 펫 크기(전체 slot 공통), 위치 기준점(anchor), 배치 방향, 가로/세로 여백, 슬롯 간격이다. 캐릭터는 설정 창이 아니라 우클릭 `캐릭터` 메뉴에서 바꾼다. 저장 버튼은 하나이며 재시작 없이 즉시 반영한다.

크기/배치 실시간 반영 규칙:
- 각 pet은 약 1초 주기로 `config.json`(없으면 `config.default.json`)을 확인하고, 크기·anchor·direction·offset·slotGap 중 하나라도 바뀌면 창 크기를 바꾸고 자기 slot의 기본 위치로 재배치한다 (`layout-applied` transition log).
- 설정을 저장한 pet뿐 아니라 실행 중인 모든 slot pet이 같은 값으로 맞춰진다. `set-placement.ps1`로 바꾼 값도 같은 경로로 반영된다.
- 드래그로 옮긴 위치는 유지하지 않고 기본 위치로 되돌린다. 크기가 달라진 상태에서 사용자 위치를 유지하면 pet끼리 겹칠 수 있기 때문이다.
- 캐릭터 변경처럼 크기/배치와 무관한 config 저장은 재배치를 일으키지 않는다.
- config 파싱에 실패하면(다른 process가 쓰는 중 등) 기본값으로 떨어지지 않고 다음 주기에 다시 읽는다.
- pet process, 상태, sleep timer, owner 정보는 그대로 유지된다.

## 10. 종료/정리 정책

- session process와 owner window가 모두 사라지면 해당 pet을 즉시 종료한다 (grace period 없음).
- session process는 사라졌지만 owner window가 살아 있으면 grace period를 둔다:
  - `done`, `idle`, `sleeping` 상태: 약 3초 (안정 상태에서의 정상 종료)
  - shared owner source: 약 6초 (다른 세션이 동일 창 사용 중, 병합 과도기 지연 대응). 상태와 무관하게 위 3초 규칙보다 우선한다.
  - 기타 상태 (`thinking`, `error`, `notification`, `disconnected`): 약 8초
- owner process만으로 session 종료를 판정하지 않는다.
- pet process가 살아 있는데 pid file이 없어지면 pid file을 복구한다.
- 죽은 session registry/state/pid는 다음 hook 또는 cleanup 흐름에서 정리한다.

## 11. 로그/진단

### 11.1 주요 로그/파일

```text
%TEMP%\claude-wt-pets-transition.log
%TEMP%\claude-wt-pets-state-{slot}.json
%TEMP%\claude-wt-pets-pet-{slot}.pid
%TEMP%\claude-wt-pets-registry.json
%TEMP%\claude-wt-pets-owner-map.json
```

`claude-wt-pets-transition.log`는 상태 전환, owner 복구, pet 종료, 설정 저장 같은 주요 이벤트를 기록한다. 512KB를 넘으면 마지막 1000줄 중심으로 rotation한다.

### 11.2 보안/운영 메모

세션 이동용 wrapper와 `EncodedCommand` 방식은 사용하지 않는다. 남아 있는 민감 동작은 다음 목적에 한정한다.

```text
ShellExecute / WindowStyle Hidden: pet 실행 시 PowerShell host console 창 숨김
Add-Type / DllImport: WPF 창 표시, foreground/visible window probe 수집
AttachConsole / SetConsoleTitle: session marker probe에 사용. parent console에 마커를 심어 multi-window 환경에서 정확한 owner를 식별
CreateToolhelp32Snapshot: hook 실행 PowerShell에서 부모 claude.exe process 탐색
UI Automation (UIAutomationClient): focus 시점 Windows Terminal tab strip(TabItem 이름) 읽기 전용 열거. 탭 선택/조작은 하지 않음
settings.json 쓰기: install-hooks.ps1 실행 시 direct hook 설치/복구
%TEMP% 파일 쓰기/삭제: slot별 state/pid/registry/owner-map 관리
```

### 11.3 기본 검증 명령

```powershell
node --check .\notifier.js
```

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\install-hooks.ps1 -Scope user -Audit
```

```powershell
$files = @(
  'hook-entry.ps1',
  'pet.ps1',
  'install-hooks.ps1',
  'launch-pet.ps1',
  'set-character.ps1',
  'set-placement.ps1',
  'pet-debug.ps1',
  'WtPets.Common.ps1',
  'scripts\test-notifier.ps1'
)

foreach ($file in $files) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Get-Location) $file),
    [ref]$tokens,
    [ref]$errors
  ) | Out-Null
  if ($errors) {
    $errors | ForEach-Object { "$file: $($_.Message)" }
  }
}
```

## 12. 설치/Hook 운영

현재 운영 기준은 user scope direct hook이다.

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\install-hooks.ps1 -Scope user
```

확인은 audit로 한다.

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\install-hooks.ps1 -Scope user -Audit
```

제거는 `-Uninstall`로 한다. user/project 양쪽 settings에서 claude-wt-pets hook만 지우고 다른 설정은 유지한다. 수정 전 백업을 만든다.

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\install-hooks.ps1 -Uninstall
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\install-hooks.ps1 -Uninstall -Audit
```

settings 파일이 JSON으로 읽히지 않으면 설치·제거 모두 파일을 바꾸지 않고 오류로 중단한다. 한쪽 파일만 바뀌는 일을 막기 위해 수정 전에 user/project 두 파일을 모두 먼저 읽어 본다.

## 13. 제한사항

- Git Bash는 공식 지원하지 않는다.
- Windows Terminal tab 내부 직접 선택은 지원하지 않는다.
- top-level Windows Terminal 창 focus만 지원한다.
- Codex/Gemini session은 현재 pet 지원 대상이 아니다.
- 5번째 이후 Claude session은 pet을 만들지 않는다.
