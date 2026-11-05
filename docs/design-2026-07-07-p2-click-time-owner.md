# P2 설계 확정 — 상시 owner 추적 폐기, 클릭 시점 해석

> 설계 당시(2026-07-07)의 기록이다. 당시 프로젝트 이름은 `clawd-notify`였고, 본문의 `clawd` 표기(예: `__clawd_pet_` marker)와 함수 위치·줄 번호는 당시 코드 기준이다. 현재 이름은 `claude-wt-pets`다. 전체 흐름은 [how-it-was-solved.md](how-it-was-solved.md)에 정리했다.

---

## 1. 목표 / 비목표

**목표** — owner 정밀도가 실제로 필요한 유일한 순간(Ctrl+클릭, 우클릭 창 가져오기)에만 trusted 해석을 수행하고, ownerTimer의 상시 owner 재검증 기계를 제거한다. 추적 자체가 만들던 경합·churn·marker 탭 제목 깜빡임의 구조적 원인을 소멸시킨다.

**비목표** — hook 경로 변경 없음(`hook-entry.ps1`/`notifier.js` 무변경). 상태 모델 변경 없음(7상태 고정). tab 내부 선택 없음(금지 유지). marker probe의 UIA 교체는 P3 별도.

## 2. 설계를 단순화하는 세 가지 사실 (코드 확인 완료)

1. **클릭 시점 해석은 이미 구현되어 있다.** `Focus-OwnerWindow`(pet.ps1:2404)가 클릭 순간에 Refresh-OwnerFromState → shared 재증명(`Test-SharedOwnerStillPlausible`) → `Resolve-SharedOwnerHwnd` / `Resolve-OwnerHwndInVerifiedOrder` → `SetForegroundWindow`, 실패 시 `Show-OwnerLinkMissing`(disconnected)을 전부 수행한다. P2는 신규 구현이 아니라 **timer 절제 수술**이다.
2. **`Resolve-OwnerHwndInVerifiedOrder`(2373)는 이미 trusted 3순위만 수행한다** (session marker → owner-map → tab title) — 스펙 §7.2 그대로. 금지된 resolver 4개(`FromOwnerProcess`/`FromForegroundWindow`/`FromScreenOrder`/`FromExactScreenOrder`, 합계 약 262줄)는 **호출처 0의 죽은 코드**다.
3. **ownerTimer의 나머지 절반은 추적이 아니라 생명주기다** — session process 소실 감지·grace·pet 종료(3057-3107, 3156-3189)는 owner 추적과 무관하며 그대로 유지한다.

## 3. 확정 설계

### 3.1 ownerTimer — 생명주기 전용으로 축소

**유지** (기존 코드 그대로):
- `settingsOpen` guard
- `Refresh-OwnerFromState` — passive state 파일 재읽기. probe가 아니며, hook이 갱신한 owner를 pet이 넘겨받는 경로
- session pid liveness + grace + close (현행 3057-3107)
- owner hwnd `IsWindow` 생존 검사 — 단, 실패 시 **재해석 없이** stale 처리 후 생명주기 판정(wait-anchor / close)만
- owner pid liveness + close/wait (현행 3156-3189)

**제거**:
| 대상 | 현행 위치 | 성격 |
| --- | --- | --- |
| window-set signature 감시 + `Revalidate-SharedOwnerAfterWindowSetChange` | 2968-2984 | 추적 |
| owner-map mtime 감시 + reverify (P1 fix 포함 — 가교 역할 종료) | 2986-3021 | 추적 |
| owner 안정성 카운터/게이트 (`ownerStableCount`, `OWNER_STABLE_THRESHOLD`) | 3023-3039 | 추적 스로틀. 생명주기 검사는 매 tick 수행 (Get-Process 1회/2초, 부하 무시 가능) |
| timer 내 owner 재해석 (`Resolve-OwnerHwndInVerifiedOrder` 3회) | 3050-3056, 3108-3118, 3126-3134 | 추적 |
| shared plausibility 주기 재증명 + `Resolve-SharedOwnerHwnd` 주기 호출 | 3108, 3153-3155 | 추적 — 7/7 관찰된 10.2초 marker 사이클(탭 제목 깜빡임)의 발원지 |
| title conflict 감시 | 3144-3147 | 추적 |

### 3.2 disconnected — 클릭 실패 시로 한정

- STATES.md 원문 정의("창 앞으로 가져오기 시 owner window를 찾지 못함")와 정합. timer 유래 disconnected 진입(`Show-OwnerLinkMissingWithGrace`)을 제거한다.
- owner 소실은 내부적으로 hwnd=0 stale 처리만 하고, 사용자 표시는 클릭 시점에 확정한다.
- 근거: 6/12 설계 노트 — "disconnected도 규정상 focus 실패 시에만 발생 — 전환 공백 개념 자체가 소멸".
- CLAUDE.md §2 "탭 병합 자체만으로 disconnected로 떨어지면 안 된다"를 자동 충족한다 (병합을 아예 감시하지 않으므로).

### 3.3 hook 경로 — 무변경

`SessionStart`/`UserPromptSubmit`/`PreToolUse`의 owner probe 수집과 notifier.js의 owner-map 갱신은 event-driven이므로 그대로 둔다. pet 시작 시 1회 owner-map 동기화(오염 title 정리, 스펙 §7.2)도 유지.

### 3.4 삭제 함수 / 유지 함수

**삭제** (모두 timer 전용 또는 죽은 코드, 호출 관계 grep 확인 완료):
- `Resolve-OwnerHwndFromOwnerProcess` (1165), `Resolve-OwnerHwndFromForegroundWindow` (1589), `Resolve-OwnerHwndFromScreenOrder` (1712), `Resolve-OwnerHwndFromExactScreenOrder` (1766) — 죽은 코드
- `Revalidate-SharedOwnerAfterWindowSetChange` (1129), `Test-CurrentSharedOwnerStableInMerged` (1111), `Get-TerminalWindowSetInfo` (1041), `Show-OwnerLinkMissingWithGrace` (2000)
- 고아 변수: `ownerMapLastTicks`, `terminalWindowSignature`, `terminalWindowCount`, `ownerStableCount`, `prevOwnerHwnd`, `OWNER_STABLE_THRESHOLD`, `lastSharedOwnerWindowSetRevalidateMs`, `lastMergedSharedReverifySkipMs`, `ownerLinkMissingGraceTicks`

**유지** (클릭 경로 사용): `Test-SharedOwnerStillPlausible`, `Resolve-SharedOwnerHwnd`, `Resolve-OwnerHwndInVerifiedOrder`, `Resolve-OwnerHwndFromSessionMarker`/`FromOwnerMap`/`FromTabTitle`, `Show-OwnerLinkMissing`, `Get-TerminalMergeInfo`, `Test-TerminalWindowsMerged`, `Sync-OwnerMapFromCurrentOwner`, `Save-RecoveredOwnerState`.

### 3.5 문서 반영 (구현과 동일 커밋)

- `docs/feature-spec.md` §7.2: ownerTimer 상시 복구 서술 → 클릭 시점 해석 + 생명주기 전용 timer로 재기술
- `STATES.md`: disconnected 항목의 "ownerTimer가 복구를 시도했지만" 문구 제거 (클릭 시도 실패로 한정)
- 초기 기획서(비공개): "탭 분리/병합 자동 추적"(ownerTimer 주기 감지) → 클릭 시점 자동 해석으로 재기술
- QA 체크리스트 신규: `docs/qa-checklist-2026-07-08.md`

### 3.6 사용자 체감 변화

- **동일**: Ctrl+클릭 정확도. 클릭 순간 trusted 해석이므로 항상 최신 창 배치 기준.
- **개선**: 안정 상태 소음 0 — 10.2초 marker 사이클과 탭 제목 `__clawd_pet_` 깜빡임 소멸. 병합/분리 과도기의 자기 유발 재검증·오포커싱 원천 차단.
- **변화**: owner 창이 사라져도 다음 클릭/hook 전까지 pet이 마지막 상태를 유지한다 (선제 disconnected 표시 없음). STATES.md 정의와 정합이며, 세션이 함께 죽은 경우는 생명주기 종료가 그대로 처리한다.

## 4. 리스크와 판단

| 리스크 | 판단 |
| --- | --- |
| 생명주기 판정이 stale hwnd에 의존 | 기존과 동일 (`IsWindow` 검사 유지). 변화 없음 |
| 클릭 시 marker probe 수백 ms 지연 | 기존 Focus 경로도 동일하게 probe했음. 변화 없음 |
| timer 선제 복구로 이득 보던 시나리오 | 스펙이 보장한 적 없는 동작. 클릭 시 동일 결과에 도달. 회귀 아님 |
| 삭제 규모(~400줄)로 인한 파손 | parser check + S1/S3 런타임 검증으로 확인. 클릭 경로는 무변경 |

## 5. 검증 계획

- 문법: `Parser::ParseFile(pet.ps1)`, `node --check notifier.js`
- **S1 (핵심)**: 7/7 P1 검증과 동일한 합성 shared 환경(단일 pet, marker 해석 성공) 2분 — 안정 상태에서 transition log 증가 0줄. P1 검증 시 동일 환경에서 10.2초마다 5줄씩 발생했으므로 대조 명확
- **S3**: 새 WT 창 열기(window-set 변화) → 재검증 미발화 확인
- S2(실클릭 focus)·S4(session 종료 grace): 코드 무변경 경로이므로 QA 체크리스트의 실환경 수동 항목으로 이관
- 사후: hook 설치 환경에서의 실사용 확인은 사용자 QA

## 6. 구현 순서

1. 브랜치 `feat/p2-click-time-owner`
2. 죽은 resolver 4개 삭제
3. ownerTimer tick 재작성 (생명주기 전용)
4. timer 전용 함수·고아 변수 삭제, P1 mtime 감시 코드 제거
5. parser check → S1/S3 런타임 검증
6. 문서 반영(스펙/STATES/proposal) + QA 체크리스트 신규
7. 커밋 → main 병합 → push
