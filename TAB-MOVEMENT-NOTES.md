# Windows Terminal 탭 이동 작업 노트

> 탭 이동 실험과 보류 결정을 남긴 작업 노트다. 당시 프로젝트 이름은 `clawd-notify`였고, 본문의 `clawd` 표기는 당시 이름이다. 일부 정책(grace time, stale handle 복구 방식 등)은 이후 바뀌었으므로 현재 기준은 [docs/feature-spec.md](docs/feature-spec.md)를 따른다. 전체 흐름은 [docs/how-it-was-solved.md](docs/how-it-was-solved.md)에 있다.

## 현재 결론

탭 선택(클릭으로 탭 전환)은 보류한다. 탭 식별(어떤 창에 어떤 세션이 있는지)은 tab_title 기반 best-effort 매칭으로 구현했다.

현재 claude-wt-pets는 Windows Terminal 창까지만 앞으로 가져온다. 특정 탭 선택은 지원하지 않는다. 탭 병합/분리 시 owner 창이 교차 배정되는 문제는 hook 시점에 캡처한 콘솔 타이틀을 window title과 매칭하여 완화한다.

## 현재 유지할 기능

- `claude` 직접 실행
- Windows Terminal PowerShell에서 실행한 Claude Code 세션 추적
- slot 1~4 멀티 pet
- 상태별 캐릭터 이미지 표시
- 캐릭터 변경
- 위치/크기 설정
- Windows Terminal 창 앞으로 가져오기
- stale owner window handle의 제한적 복구
- tab_title 기반 owner 창 매칭 (탭 병합/분리 대응)
- `session_pid`와 `owner_hwnd` 기반 pet 종료
- 최대 4개 slot 이후 세션 무시

## 현재 창 이동 정책

- pet은 Windows Terminal 창까지만 앞으로 가져온다.
- 특정 탭 선택은 지원하지 않는다.
- 여러 Claude 탭이 같은 Windows Terminal 창 안에 있으면 같은 `owner_hwnd`를 공유할 수 있고, 이 경우 각 pet은 같은 top-level 창을 앞으로 가져온다.
- `Notification`과 `Stop`은 사용자가 다른 창을 보고 있을 때도 발생할 수 있으므로 owner window handle을 덮어쓰지 않는다.
- `SessionStart`, `UserPromptSubmit`, `PreToolUse`는 사용자가 해당 터미널과 상호작용했을 가능성이 높으므로 owner capture를 허용한다.
- owner capture(hook 시점)는 session marker와 owner-map last-known-good만 확정 근거로 사용한다. foreground/screen-order/process 단독 근거는 오포커싱 위험으로 사용하지 않는다 — 최종 기준은 `docs/feature-spec.md` §7.1.
- pet은 owner를 상시 추적하지 않는다. 탭 분리/병합 후에도 pet 클릭(focus) 시점에 trusted 순서(session marker → owner-map → tab title)로 top-level 창을 다시 해석한다 — 2026-07 P2 (`docs/design-2026-07-07-p2-click-time-owner.md`).
- tab_title 매칭은 hook 시점에 캡처한 콘솔 타이틀(`[Console]::Title`)을 각 visible Windows Terminal 창의 window title(`GetWindowText`)과 비교한다. 유일하게 일치하는 미사용 창이 있으면 해당 창을 owner로 배정한다. 다른 slot의 tab_title과도 매칭되는 창은 제외하여 교차 배정을 방지한다.
- owner가 비어 있을 때 unused visible 창을 임의 owner로 집는 방식은 허용하지 않는다.
- slot은 생성 순서대로 비어 있는 가장 낮은 번호를 사용하고, 5번째 이후 세션은 무시한다.
- 창 앞으로 가져오기 복구 실패는 Claude Code 오류가 아니라 pet 외부 연결 문제이므로 `disconnected` 상태로 표시한다.
- owner PID는 Windows Terminal 창 handle 복구의 보조 근거로만 사용하고, 종료 판정의 단독 근거로 쓰지 않는다.
- Claude `session_pid`가 사라졌지만 owner 창이 살아 있으면 15초 grace time 동안 다음 hook을 기다린 뒤 pet을 종료한다.

## 탭 이동을 보류한 이유

Windows 일반 창 API는 top-level window handle까지만 안정적으로 다룬다.

```text
SetForegroundWindow = Windows Terminal 창을 앞으로 가져옴
Windows Terminal tab = 창 내부 UI 요소
```

따라서 "pet 클릭으로 해당 탭 선택"을 하려면 Windows Terminal 내부 TabItem을 별도로 식별하고 선택해야 한다. 이 과정은 기본 pet 기능보다 실패 지점이 많다.

### 1. wrapper 입력 안정성

`clawd` wrapper 실험에서는 Claude interactive 입력이 불안정했다.

가능성이 있던 원인:

- PowerShell wrapper가 Claude interactive TTY 흐름을 방해
- `[Console]::Title` 유지 timer가 interactive rendering과 충돌
- `--session-id` 전달 방식이 Claude interactive 모드와 맞지 않음
- 중첩 PowerShell 실행 구조가 terminal input/output forwarding을 불안정하게 만듦

정확한 원인은 확정하지 않았다. 입력 안정성이 먼저라 해당 실험은 중단했다.

### 2. 탭 식별 문제

초기 실험은 탭 title을 `clawd:<session-id-prefix>` 형태로 고정하고 UIAutomation으로 TabItem을 찾는 방식이었다.

```text
AutomationElement.FromHandle(windowHandle)
→ Descendants 중 ControlType.TabItem 검색
→ Name에 terminal_title이 포함된 항목 찾기
→ SelectionItemPattern.Select()
```

이 방식은 다음 문제가 있다.

- tab title이 Claude나 shell에 의해 바뀔 수 있음
- title 유지 timer가 interactive UI와 충돌할 수 있음
- UIAutomation tree가 환경과 Windows Terminal 버전에 따라 달라질 수 있음
- 탭이 여러 창으로 분리/병합될 때 mapping이 깨질 수 있음

### 3. stale handle 문제

`focus_hwnd` 또는 `owner_hwnd`가 Windows Terminal 창 재구성 뒤 stale handle로 남는 케이스가 있었다.

현재 구현은 창 앞으로 가져오기 안정화를 위해 제한적 복구만 한다. stale `owner_hwnd`가 있고 같은 owner process 안에 visible `CASCADIA_HOSTING_WINDOW_CLASS` 창이 정확히 1개일 때는 process 기준으로 새 handle을 복구한다. owner가 비어 있을 때는 visible Windows Terminal 창이 4개 이하이고 기본 left-to-right 배치가 맞는 경우에만 같은 slot 화면 순서 fallback을 사용한다. 이 정책은 top-level Windows Terminal 창만 다루며 탭 선택 문제를 해결하지 않는다.

## 제거한 실험 항목

- `clawd.cmd`
- `start-clawd-session.ps1`
- `run-clawd-terminal.ps1`
- `notifier.js`의 `TerminalStart`
- `notifier.js`의 `TerminalEnd`
- `terminal_title`, `wt_session`, `wt_profile_id`, focus payload 저장
- `pet.ps1`의 `UIAutomationClient`
- `pet.ps1`의 `UIAutomationTypes`
- `Select-TerminalTabByTitle`
- `Focus-OwnerSession`
- Ctrl+좌클릭 세션 이동
- 우클릭 메뉴의 `이 세션으로 이동`

## 다시 검토할 조건

탭 이동을 다시 검토하려면 기본 pet 기능과 분리된 실험 명령으로 시작한다.

권장 이름:

```text
claude-pet-tab
```

검증 순서:

1. pet 없이 Claude interactive 입력만 검증한다.
2. 일반 텍스트 입력, Enter, slash command, Ctrl+C, 종료가 정상인지 확인한다.
3. 입력이 안정되면 TerminalStart/TerminalEnd를 붙인다.
4. 탭 title 저장을 붙인다. title 강제 유지 timer는 먼저 쓰지 않는다.
5. UIAutomation으로 TabItem 목록만 로그에 기록한다.
6. 목록이 안정적으로 잡힐 때만 실제 Select를 수행한다.

## 필요한 실패 피드백

탭 이동을 재시도한다면 실패를 사용자가 알 수 있어야 한다.

필요한 피드백:

- 탭을 찾지 못함
- 창 handle이 유효하지 않음
- UIAutomation에서 TabItem을 찾지 못함
- wrapper input이 비정상
- 같은 process 안의 visible Windows Terminal 창이 2개 이상이라 자동 선택 불가

디버그 로그 후보:

```text
%TEMP%\clawd-tab-debug.log
```

기록할 값:

- session id
- slot
- terminal title
- owner pid
- owner hwnd
- owner hwnd 유효 여부
- focus pid
- focus hwnd
- 찾은 top-level window list
- visible `CASCADIA_HOSTING_WINDOW_CLASS` count
- UIAutomation TabItem names
- 선택 성공/실패 결과

## 보류할 기능

- pet 클릭으로 Windows Terminal 탭 이동
- `clawd` wrapper
- terminal title 강제 유지
- UIAutomation 탭 선택
