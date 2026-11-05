# P3 설계 — UIA tab strip 열거를 trusted 1순위로, marker probe는 fallback

> 설계 당시(2026-07-08)의 기록이다. 당시 프로젝트 이름은 `clawd-notify`였고, 본문의 `clawd` 표기(예: `__clawd_pet_` marker)와 함수 위치·줄 번호는 당시 코드 기준이다. 현재 이름은 `claude-wt-pets`다. 전체 흐름은 [how-it-was-solved.md](how-it-was-solved.md)에 정리했다.

## 1. 문제와 목표

AttachConsole/SetConsoleTitle 기반 session marker probe는 owner 콘솔의 제목을 잠깐 `__clawd_pet_XXXX`로 바꿔 탭 제목 깜빡임을 만들고, retry 대기 때문에 클릭 시 최대 ~1.5초 pet UI를 블로킹한다. P2로 probe가 클릭 시점에만 실행되도록 줄었으므로, P3는 그 클릭 시점 자체를 비침습으로 만든다.

**목표**: UI Automation으로 각 visible Windows Terminal 창의 tab strip(TabItem 이름들)을 읽어 owner를 식별한다. 쓰기 없음(깜빡임 0), 실측 창당 8~26ms. marker probe는 tab strip이 유일 후보를 내지 못할 때(수동 개명, 중복 제목, UIA 실패)의 fallback으로 유지한다.

**비목표**: tab 내부 선택/focus 없음(금지 유지 — 읽기 전용 열거만). hook 경로 무변경. AttachConsole 용도 제한(CLAUDE.md §3) 변경 없음 — probe 사용이 줄어들 뿐이다.

## 2. 왜 tab strip이 기존 tab title 매칭보다 강한가

기존 `Resolve-OwnerHwndFromTabTitle`은 창의 window title(`GetWindowText`)을 비교하는데, 이는 **활성 탭의 제목만** 반영한다. 병합 창에서 내 세션 탭이 비활성이면 매칭이 불가능했다 — 그래서 marker probe가 필요했다. UIA tab strip은 비활성 탭까지 전부 보이므로, 병합 창에서도 probe 없이 내 탭이 들어 있는 top-level 창을 특정할 수 있다. feasibility 실측(2026-07-08): 실제 WT 2개 창에서 TabItem 이름 열거 성공, 8~26ms.

## 3. 확정 설계

### 3.1 신규 함수

- `Get-TerminalTabTitles([Int64]$Hwnd)` — UIA(`UIAutomationClient`)로 해당 top-level 창의 TabItem 이름 배열을 반환. 실패/미지원 시 빈 배열 (fallback 유도). assembly 로드는 1회 플래그로 캐시.
- `Resolve-OwnerHwndFromTabStrip([switch]$LogMiss)` — trusted 해석 1순위.
  - 매칭 대상: ① slot marker `Claude #$Slot` — `Get-ExplicitSlotFromWindowTitle`로 **정확 매칭**, ② state의 `tab_title` — `Test-WindowTitleCompatible`(spinner 허용 포함).
  - 제외: `__clawd_pet_` probe 제목, 다른 slot의 `Claude #N`, strip 후 빈 제목.
  - 판정: 매칭 탭을 포함한 창이 **정확히 1개**일 때만 성공. 0개/복수면 실패 → 다음 단계(marker)로.
  - shared 판정: 후보 창이 다른 slot의 owner_hwnd로 사용 중이면, (a) 그 창의 tab strip에 다른 slot 탭이 함께 보이거나(병합의 직접 증거) (b) `Test-TerminalWindowsMerged`일 때만 `tab-strip-shared`로 허용. 아니면 실패.
  - 시간 방어: 전체 열거 1.5초 예산 초과 시 중단하고 실패 반환 (marker fallback).
  - 성공 시 기존 관례대로 `Save-RecoveredOwnerState` / `Clear-DisconnectedState` / transition log.

### 3.2 owner source 추가

- `tab-strip` — persistable (`session-marker`/`tab-title`과 동급).
- `tab-strip-shared` — persistable + untrusted + focus recheck 필요 + shared source (`session-marker-shared`와 동일 분류).

### 3.3 해석 순서 변경

- `Resolve-OwnerHwndInVerifiedOrder`: **tab strip → session marker → owner-map → tab title(window title)**.
- `Resolve-SharedOwnerHwnd`의 재해석 체인: **tab strip → session marker → owner-map → tab title**.
- marker probe는 코드 삭제 없이 2순위로 유지 — 수동 개명·중복 제목·UIA 실패 환경의 fallback.

### 3.4 문서 반영

- feature-spec §7.2 trusted 순서에 tab strip 추가, STATES.md trusted 근거 목록 갱신.
- `docs/qa-checklist-2026-07-08.md`에 P3 검증 항목 append.

## 4. 리스크

| 리스크 | 판단 |
| --- | --- |
| 사용자가 임의 창의 탭을 `Claude #1`로 개명 | 기존 tab title 매칭과 동일한 위험 계열. 유일 후보 요구 + 다른 slot 사용 창 제외 + spec상 tab title은 보조 근거 |
| WT 버전에 따른 UIA 트리 차이 | 실패 시 빈 배열 → marker fallback. 기능 저하 없음 (P3 이전과 동일 동작) |
| UIA 지연/행 | 1.5초 예산 초과 시 중단. 실측 창당 8~26ms |
| WPF STA 스레드에서 UIA 호출 | UIA client는 STA 지원. feasibility에서 동일 조건 확인 |

## 5. 검증 계획

- 문법: parser + `node --check`.
- feasibility(완료): 실제 WT 2개 창 TabItem 열거 성공, 8~26ms.
- **E2E**: 테스트 WT 창을 탭 2개로 구성 — `Claude #1`(비활성) + 다른 제목(활성). window title은 활성 탭이므로 기존 tab title 매칭으로는 불가능한 배치다. 합성 state(slot 1, 실제 claude session pid, owner_hwnd=0) → pet 기동 → SendInput으로 Ctrl+클릭 → `owner-window-recovered-from-tab-strip` 로그 + 테스트 창 foreground + marker probe 로그 부재(`__clawd_pet_` 무발생) 확인.
- 실환경 수동 QA: qa-checklist-2026-07-08.md에 항목 추가.
