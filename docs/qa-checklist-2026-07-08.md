# QA 체크리스트 — 2026-07-08 (P2 클릭 시점 owner 해석)

이 문서는 클릭 시점 owner 해석(P2, `docs/design-2026-07-07-p2-click-time-owner.md`)과 UIA tab strip 해석(P3, `docs/design-2026-07-08-p3-uia-tab-strip.md`) 반영 후의 기준 체크리스트다. 분리/병합 후 owner 확정은 상시 추적이 아니라 클릭 시점에 일어나는 것이 정상이다.

## 판정 기준 요약 (P2 이후)

- 안정 상태에서 pet은 owner 관련 로그를 만들지 않는다. 탭 제목 `__claude_wt_pets_` 깜빡임도 없어야 한다.
- 탭 분리/병합 직후 pet이 아무 반응을 하지 않는 것은 **정상**이다. Ctrl+클릭하는 순간 올바른 top-level 창이 foreground 되면 통과다.
- `disconnected`는 focus 시도(Ctrl+클릭, 우클릭 메뉴) 실패 시에만 발생해야 한다. 다른 경로로 발생하면 실패다.
- 병합/분리 자체로 pet이 사라지거나 `disconnected`가 되면 실패다.

## 1. 자동 검증 — 2026-07-08 수행 완료

- [x] `pet.ps1` `[System.Management.Automation.Language.Parser]::ParseFile` 통과 (excision 468줄 후).
- [x] `node --check notifier.js` 통과.
- [x] 삭제 함수·변수 잔여 참조 0건 (`Show-OwnerLinkMissingWithGrace`, `Get-TerminalWindowSetInfo`, `Revalidate-SharedOwnerAfterWindowSetChange`, `Test-CurrentSharedOwnerStableInMerged`, 금지 resolver 4종, 추적용 script 변수 9종).
- [x] **S1 안정 상태 침묵**: 합성 session-marker-shared 환경(실제 WT hwnd, 실제 claude session pid) 단일 pet 5분 — 로그 5줄(시작 3줄 + 정확히 300초에 sleep-timer 전환 2줄). owner 관련 발화 0. 비교: P2 이전 동일 환경은 10.2초마다 5줄(marker probe 사이클).
- [x] **S3 window-set 변화 무반응**: 새 WT 창 생성 후 35초 — 로그 증가 0줄 (이전: `shared-owner-window-set-change-revalidate` 발화).
- [x] sleeping 정책 회귀 없음: idle 300초 → sleeping 전환 확인 (S1 로그).

## 1.5 자동 검증 (P3 UIA tab strip) — 2026-07-08 수행 완료

- [x] feasibility: 실제 WT 2개 창에서 UIA TabItem 이름 열거 성공 (창당 8~26ms).
- [x] parser check 통과 (tab strip resolver 추가 후).
- [x] **E2E**: 탭 2개 테스트 창(`Claude` 비활성 + `qa-other` 활성, window title=`qa-other`) + owner 없는 합성 state → 실제 Ctrl+클릭(SendInput) → `owner-window-recovered-from-tab-strip`(source=tab-strip, 창 3개 열거 252ms) + `focus-owner-window` + **marker probe 로그 0건**(`__claude_wt_pets_` 무발생). 이 배치는 window title 매칭으로는 불가능한 구성 — UIA 우위 입증.
- [x] 클릭 전 4분 방치 구간 로그 0줄 (P2 침묵 유지 확인).

## 2. 수동 검증 — 실환경 (hook 설치 필요)

> 2026-07-08 실환경 자동화 QA 수행: user scope hook 설치(audit ok) 후 실제 claude 세션 2개(이 세션 slot 1 + 신규 세션 slot 2)로 검증. 입력은 SendInput/SendKeys 실입력. `[x]` 항목은 transition log 증거 확보. 탭 병합/분리처럼 드래그가 필요한 항목만 사람 수행으로 남김.

### 기본 상태 전환

- [x] Claude 세션 시작 → pet 자동 생성, `idle`. — 2026-07-08 확인 (slot 2: `hook-launch-pet-shellexecute-hidden` → `pet-start idle`)
  실패 시 볼 로그: `%TEMP%\claude-wt-pets-transition.log`, hook-entry `skip-*` 항목
- [x] 프롬프트 입력 → `thinking`, 응답 종료 → `done`, `done`은 자동 `idle` 복귀 없음. — 2026-07-08 확인 (실프롬프트로 thinking→done, 이후 `skip-notification-over-done`으로 done 보존 정책까지 확인)
- [x] 권한 확인 발생 → `notification`. — 2026-07-08 확인 (slot 1, `Claude needs your permission`)
- [x] 더블클릭 → `idle` 복귀. — 2026-07-08 확인 (done→idle). 우클릭 `기본 상태로 돌리기`는 미검증. 참고: 합성 입력에서 클릭 간격이 벌어지면 `DragMove()` 모달 루프와 간섭해 더블클릭이 씹힐 수 있음 — 자동화 아티팩트, 실마우스 무관
- [ ] `idle` 300초 → `sleeping`. 다른 상태에서는 sleeping 미발생. (합성 환경에서는 확인됨 — §1. 실환경 장시간 방치는 미수행. `sleep-skip-active-state done` 로그로 done 보호는 확인)

### Focus (클릭 시점 해석) — P2 핵심

- [x] 단일 창: Ctrl+클릭 → owner Windows Terminal 창 foreground. — 2026-07-08 확인 (foreground 329122 → pet 클릭 → 2229950 전환, `focus-owner-window`)
- [ ] 탭 병합 (2개 세션을 한 창으로): 병합 직후 pet 2개 모두 유지, `disconnected` 미발생. 각 pet Ctrl+클릭 → 같은 top-level 창 foreground (내부 tab 전환은 기대하지 않음).
- [ ] 병합 → 창 분리: 분리 직후 pet 무반응이 정상. 각 pet Ctrl+클릭 → **자기 세션이 들어 있는 창** foreground (session marker 우선). 다른 세션 창이나 무관한 창을 포커싱하면 실패.
- [ ] 무관한 WT 창을 여러 개 열어둔 상태에서 위 항목 반복 — visible 창 개수에 흔들리지 않아야 함.
- [ ] owner 창을 닫고(세션 프로세스는 다른 창에서 유지) Ctrl+클릭 → `disconnected` 표시. 이후 새 hook(프롬프트 입력)에서 owner 재확정 → 클릭 정상화.
- [ ] 클릭 시 marker probe 동안(수백 ms~1.5초) pet UI가 잠시 응답하지 않는 것은 기존과 동일한 알려진 동작. P3 이후 tab strip이 먼저 성공하면 probe 없이 즉시 focus되며 탭 제목 깜빡임도 없어야 한다.
- [ ] (P3) 병합 창에서 내 세션 탭이 **비활성**인 상태로 Ctrl+클릭 → tab strip으로 창 특정, `__claude_wt_pets_` 깜빡임 없음 (transition log에 `owner-window-recovered-from-tab-strip` 또는 `shared-owner-resolved-tab-strip`).
- [ ] (P3) 탭을 수동 개명해 매칭 불가로 만든 뒤 Ctrl+클릭 → marker probe fallback으로 정상 focus (동작 저하 없음).

### 안정 상태 무소음 — P2 핵심

- [ ] 세션 4개를 띄우고 조작 없이 5분 방치 → `%TEMP%\claude-wt-pets-transition.log` 증가 없음 (sleep 전환 제외).
- [ ] 위 5분 동안 어떤 WT 탭 제목에도 `__claude_wt_pets_` 깜빡임이 없어야 함.

### 종료/생명주기

- [x] 세션 종료(claude 프로세스 종료) + 창 유지 → grace 후 pet 소멸 (`done`/`idle`/`sleeping` ~3초, shared ~6초, 기타 ~8초). — 2026-07-08 확인 (`/exit` 후 `session-process-gone-wait-owner-window` → `grace_seconds=3` 만료 → `pet-closed` + state/pid 정리)
- [ ] 세션 종료 + 창 닫힘 → pet 즉시 소멸.
- [ ] owner 창만 닫힘 + 세션 유지 → pet 유지 (`owner-window-gone-wait-anchor`), 사라지면 실패.
- [x] 멀티 세션 독립 표시: pet 2개가 동시에 각자 세션 상태만 반영. — 2026-07-08 확인 (slot 1 = 이 세션 thinking/notification, slot 2 = QA 세션 idle/thinking/done, 상호 간섭 없음)

### 설정/캐릭터

- [x] 우클릭 설정 → 크기/위치 저장 시 재시작 없이 즉시 반영 (`layout-applied`), pet process/상태 유지. — 2026-11-04 확인 (저장 pet은 `settings-saved` 후 ~0.02초 내 `layout-applied`, 재시작 없음)
- [x] pet 2개 이상 실행 중 한 pet에서 크기 변경 → 약 1초 내 모든 pet이 같은 크기로 바뀌고 기본 위치로 재정렬, 겹침 없음. — 2026-11-04 확인 (slot 1/2, 190→80→200→160 세 번 변경, 다른 pet 0.1~0.6초 내 반영)
- [x] 드래그로 옮긴 pet이 있는 상태에서 크기 변경 → 해당 pet도 기본 위치로 복귀. — 2026-11-04 확인 (사용자 육안 확인)
- [x] 우클릭 캐릭터 변경 → 다른 pet 위치/크기 변화 없음 (`layout-applied` 미발생). — 2026-11-04 확인 (`character-change` 4회 동안 `layout-applied` 0건)
- [ ] 우클릭 캐릭터 변경(이번 세션만) → 즉시 반영, config.json 미변경.
- [ ] 일부 상태 이미지가 없는 캐릭터 → `idle.png` fallback.

## 3. 검증 명령

```powershell
node --check .\notifier.js
```

```powershell
$files = @('hook-entry.ps1','pet.ps1','install-hooks.ps1','launch-pet.ps1','set-character.ps1','set-placement.ps1','pet-debug.ps1','WtPets.Common.ps1','scripts\test-notifier.ps1')
foreach ($file in $files) {
  $tokens=$null; $errors=$null
  [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Get-Location) $file),[ref]$tokens,[ref]$errors) | Out-Null
  if ($errors) { $errors | ForEach-Object { "$file: $($_.Message)" } }
}
```
