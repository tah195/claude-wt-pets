# pet 상태 정의

pet은 캐릭터별로 같은 7개 상태 파일명을 사용한다.

```text
characters/
  캐릭터명/
    idle.png
    thinking.png
    done.png
    notification.png
    sleeping.png
    error.png
    disconnected.png
```

특정 상태 파일이 없으면 같은 캐릭터의 `idle.png`를 fallback으로 사용한다.

## 사용 상태

| 상태 | 트리거 | 파일명 | 전환 정책 |
| --- | --- | --- | --- |
| `idle` | `SessionStart`, 더블클릭, 우클릭 `기본 상태로 돌리기` | `idle.png` | 기본 대기 상태 |
| `thinking` | `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | `thinking.png` | 다음 hook 상태로 갱신 |
| `done` | `Stop` | `done.png` | 자동 `idle` 복귀 없음 |
| `notification` | 표시할 필요가 있는 `Notification` | `notification.png` | 자동 `idle` 복귀 없음 |
| `sleeping` | `idle` 상태가 300초 지속됨 | `sleeping.png` | 새 hook, 더블클릭, 우클릭 메뉴로 해제 |
| `error` | `PostToolUseFailure`, `StopFailure` | `error.png` | 자동 `idle` 복귀 없음 |
| `disconnected` | 창 앞으로 가져오기 시 owner window를 찾지 못함 | `disconnected.png` | 새 hook에서 owner가 다시 확정되거나 더블클릭, 우클릭 메뉴로 해제 |

## error / disconnected 구분

`error`는 Claude Code 내부 작업 실패를 나타낸다.

- `PostToolUseFailure`
- `StopFailure`
- tool/API 실행 실패처럼 Claude Code 응답 흐름 안에서 발생한 오류

`disconnected`는 Claude Code 내부 상태가 아니라 claude-wt-pets 외부 연결 상태를 나타낸다.

- pet이 owner Windows Terminal window handle을 찾지 못함
- 저장된 `owner_hwnd`가 stale이고 복구할 수 없음
- exact owner를 trusted 근거(tab strip, session marker, owner-map, tab title)로 확정하지 못함

`disconnected`는 `notifier.js` hook 상태로 만들지 않는다. pet에서 사용자가 창 앞으로 가져오기(Ctrl+클릭, 우클릭 메뉴)를 시도했지만 exact/trusted owner를 확정하지 못한 경우에만 표시한다. pet은 owner를 상시 추적하지 않으므로 focus 시도 외의 경로로는 `disconnected`가 발생하지 않는다. 진입 시 실패 전 상태를 `previous_state`로 저장해도 이 값은 진단용이다. owner 복구나 focus 성공만으로 이전 상태로 자동 복귀하지 않는다.

owner가 비어 있거나 shared owner를 해소하는 중에는 아무 visible 창으로 붙이지 않는다. 이 경로에서는 foreground/process/screen-order fallback을 owner 확정 근거로 사용하지 않는다. 확신이 없으면 pet/state/pid를 유지하고 `disconnected` 상태로 남긴다.

## Notification 정책

`Notification` hook은 Claude가 사용자에게 알려야 한다고 판단한 시점에 들어오는 별도 이벤트로 본다.

- `Claude is waiting for your input`은 현재 상태가 `done`이 아닐 때만 `notification`으로 전환한다.
- 현재 상태가 `done`이면 `Claude is waiting for your input` Notification은 무시한다. `done`은 이미 "응답 완료, 다음 입력 대기"를 뜻하므로 같은 의미의 알림으로 덮어쓰지 않는다.
- 일반 권한 확인이나 명시적 사용자 확인처럼 사용자가 알아야 하는 알림을 `notification`으로 표시한다.
- `Notification`은 사용자가 다른 창을 보고 있을 때도 발생할 수 있으므로 owner window handle을 갱신하지 않는다.

## done 정책

`done`은 Claude `Stop` hook 이후 유지한다.

창을 확인했다는 사용자 행동은 Claude hook으로 들어오지 않으므로 자동으로 `idle`로 돌아가지 않는다. 다음 중 하나가 발생해야 다른 상태로 바뀐다.

- 새 입력으로 `UserPromptSubmit` 발생
- tool hook으로 `PreToolUse` 또는 `PostToolUse` 발생
- `Claude is waiting for your input` 외의 `Notification` hook 발행
- pet 더블클릭
- 우클릭 `기본 상태로 돌리기`

## sleeping 정책

`sleeping`은 `idle` 상태에서만 발생한다.

- `idle` 상태가 300초 지속되면 `sleeping`으로 전환한다.
- `thinking`, `done`, `notification`, `error`, `disconnected` 상태에서는 sleep timer가 돌아도 `sleeping`으로 전환하지 않는다.
- 긴 tool 실행 중에는 `thinking` 상태를 유지한다.
- sleep timer는 완료 상태를 `done`에서 바꾸지 않는다.
- 확인 필요 상태에서는 `notification`을 유지한다.
- 오류 상태에서는 `error`를 유지한다.
- 창 연결 끊김 상태에서는 `disconnected`를 유지한다. owner가 복구되거나 창 앞으로 가져오기가 성공해도 실패 전 상태로 자동 복귀하지 않는다.

## 상태 전환

```text
SessionStart
  |
  v
idle
  |
  +-- UserPromptSubmit / PreToolUse / PostToolUse --> thinking
  |
  +-- Stop ----------------------------------------> done
  |
  +-- 표시 대상 Notification ----------------------> notification
  |
  +-- PostToolUseFailure / StopFailure ------------> error
  |
  +-- 창 앞으로 가져오기 실패 ---------------------> disconnected
  |
  +-- idle 300초 지속 ------------------------------> sleeping

Claude is waiting for your input (현재 상태가 done이 아닐 때)
  |
  +-- notification

더블클릭 또는 우클릭 `기본 상태로 돌리기`
  |
  +-- idle

새 Claude hook에서 owner와 상태가 다시 확정됨
  |
  +-- hook이 기록한 상태
```

## 표시 정책

pet은 작업 전환 대상이 아니라 overlay 보조 UI다.

- taskbar와 Alt+Tab 목록에는 표시하지 않는다.
- window handle 생성 직후 `WS_EX_TOOLWINDOW`을 적용하고 `WS_EX_APPWINDOW`을 제거한다.
- Alt+Tab 숨김은 topmost, 드래그, 우클릭 메뉴, Ctrl+클릭 창 앞으로 가져오기 동작을 바꾸지 않는다.
