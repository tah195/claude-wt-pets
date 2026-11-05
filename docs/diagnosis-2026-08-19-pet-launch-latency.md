# 펫 등장 지연 진단 (2026-08-19)



## 요약

`claude` 실행 후 펫이 화면에 처음 뜨기까지 콜드 기준 **약 6-7초**(첫 픽셀), 실제 상태가 반영되기까지 **약 10초**가 걸린다. 실 `%TEMP%\clawd-transition.log` 타임스탬프로 실측했다.

첫 픽셀까지의 지연은 거의 전부 **새 `powershell.exe` 프로세스 콜드 스타트 + WPF 어셈블리 콜드 로드**다. 현재의 "세션마다 펫을 콜드로 새로 띄우는" 구조에서는 이것이 바닥값이며, 코드 재배치로는 줄지 않는다. 등장 시점을 실제로 앞당기는 유일한 방법은 펫 프로세스를 죽이지 않고 웜으로 유지하는 것(웜 펫 구조)인데, 이는 아키텍처·수명주기 규칙 재설계가 필요하다.

**결정(2026-08-19): 진단만 남기고 코드 변경 보류.**

## 측정 방법

- 데이터 출처: `%TEMP%\clawd-transition.log`의 이벤트 타임스탬프(`ts`). `source=hook-entry`와 `source=pet` 이벤트를 시각순으로 정렬.
- "콜드" = 부팅/첫 세션 직후처럼 csc(C# 컴파일)·WPF NGEN·프로세스 이미지 캐시가 비어 있는 상태. "웜" = 그 직후 재실행.
- 아래 두 시퀀스는 펫 pid 소실로 relaunch되며 SessionStart와 동일한 콜드 기동 경로(`hook-launch-pet` → 새 powershell → pet.ps1 → WPF)를 탄다.

## 구간별 분해

콜드 시퀀스(02:51)와 직후 웜 시퀀스(02:52) 실측:

| 구간 | 콜드 | 웜 | 성격 | 줄이는 법 |
|---|---|---|---|---|
| `hook-launch-pet` → `shellexecute-hidden` | 0.73s | 0.18s | hook host의 COM ShellExecute 오버헤드 | — |
| `shellexecute` → `pet-start` | **4.13s** | 2.41s | 새 `powershell.exe` 엔진 콜드 스타트 + WPF(`PresentationFramework`/`Core`/`WindowsBase`) 로드 + 스크립트 파싱 | **웜 펫만** |
| `pet-start` → `hide-from-alt-tab`(첫 렌더/등장) | 2.11s | 0.83s | `$app.Run` 첫 렌더, `SourceInitialized` | **웜 펫만** |
| `hide-from-alt-tab` → `owner-map-updated` | 1.87s | 0.75s | `Loaded`의 owner 해석 (창은 이미 보이는 뒤단) | 비가시, 손댈 이유 적음 |
| `owner-map-updated` → `poll-state-change`(실제 상태) | 1.53s | 1.10s | `pollTimer` 첫 tick(Interval 1000ms)이 그때 state 파일을 읽음 | 초기 동기 read(안전) |
| **hook-launch → 실제 상태 총합** | **≈10.36s** | **≈5.27s** | | |

첫 픽셀(펫이 idle 이미지로 등장)은 `hide-from-alt-tab`/렌더 시점 ≈ 콜드 7초 / 웜 3초. 그 뒤 실제 상태(thinking 등)로 바뀌는 데 추가 ≈1.5초.

## 근본 원인 (기여도 순)

1. **펫이 세션마다 새 콜드 `powershell.exe -NoProfile -STA` + WPF다 (최대 병목).** `ShellExecute` 반환 → pet.ps1 첫 줄(`pet-start`, pet.ps1:2471)까지 혼자서 콜드 ~4.1초. 최상단 `Add-Type -AssemblyName PresentationFramework/PresentationCore/WindowsBase`(pet.ps1:3-5)의 WPF 콜드 초기화가 여기 들어간다. `pet-start` → 첫 렌더(`$app.Run`, pet.ps1:2883)까지 추가 ~2.1초.

2. **첫 프레임이 무조건 idle, 실제 상태는 1초 뒤.** pet.ps1:2491이 초기 이미지를 `Load-Image 'idle'`로 하드코딩. `pollTimer`(Interval 1000ms, pet.ps1:2606-2607)가 `Loaded`에서 시작(pet.ps1:2686)되며 DispatcherTimer 특성상 첫 tick이 1초 뒤에 발화 → 그제서야 실제 state 파일을 읽어 상태 반영(`poll-state-change`, pet.ps1:2679). 등장 시점을 늦추지는 않지만 "idle로 떴다가 1초 뒤 실제 상태로 바뀌는" 깜빡임을 만든다.

3. **펫 실행이 파이프라인 맨 끝, node 뒤에 직렬.** `Start-ClawdPetFallback`(hook-entry.ps1:575)은 node `notifier.js`를 `WaitForExit(10000)`로 다 기다린 뒤(hook-entry.ps1:564)에야 호출된다. slot 번호를 notifier가 registry에 써줘야 `-Slot`으로 띄울 수 있어 순서를 못 당긴다. 앞단엔 hook host의 콜드 `Add-Type` C# 컴파일 2회(`ProcessParent` hook-entry.ps1:334, `OwnerWindowProbe` hook-entry.ps1:35)와 SessionStart 전용 `Sleep(250)` 재프로브(hook-entry.ps1:538-542)가 직렬로 더 붙는다. 실측 표본에선 notifier→launch 간격이 ~0.8초로 작았지만, 진짜 콜드 SessionStart(부팅 후 첫 hook)에선 이 컴파일들이 추가된다.

4. **콜드 캐시가 배를 만든다.** 연속 표본이 10.36초 → 5.27초로 갈린다. 부팅/첫 세션이면 csc 컴파일 캐시·WPF NGEN 이미지·Defender의 새 powershell/node 프로세스 스캔이 전부 콜드다. 최근 커밋(P2/P3)은 focus 시점 owner 로직만 건드렸고 실행(launch) 경로는 안 바꿨으므로, "지금 늦다"는 체감은 코드 회귀보다 콜드 상태일 가능성이 크다.

## 개선 레버와 한계

- **웜 펫 구조 (등장 지연을 실제로 없애는 유일한 길).** 세션 종료 시 펫을 죽이고 다음에 콜드로 다시 띄우는 대신, 펫 프로세스를 살려두고 slot/session만 다시 물려 재사용한다. `powershell+WPF` 콜드 로드(~6-7초)를 건너뛰어 등장이 사실상 즉시가 된다. 단 `feature-spec §10` 종료 정책("session·owner 모두 소실 시 즉시 종료"), CLAUDE.md의 "notifier가 펫 종료 안 함 / session당 1개 / 범위 확장 금지", 상시 웜 프로세스의 메모리와 정면 충돌한다. 착수하려면 구현 전에 **설계안(충돌 지점·수명주기 재정의·slot 회수 규칙·웜 프로세스 관리 주체)부터** 써서 검토해야 한다.

- **초기 상태 동기 read (안전, 폴리시).** 시작 시 `clawd-state-{slot}.json`을 한 번 동기로 읽어 첫 프레임부터 실제 상태로 렌더(pet.ps1:2491 대체)하면 원인 2의 ~1.5초 지연과 idle 깜빡임이 사라진다. `§10`·상태 규칙 무영향, 저위험. **단 등장 시점 자체는 못 당긴다** — 정확도 개선일 뿐 등장 지연 해결이 아니다.

- **효과 없는/비추천 레버.** hook-entry의 `Add-Type` 2회는 환경판정·probe에 필수라 제거 불가. node `WaitForExit` 게이팅은 slot 의존이라 병렬화 이득이 작고 slot 경쟁 리스크. SessionStart 250ms 재프로브는 owner 정확도 대가라 제거 시 회귀. Win32 경량 창/.NET 컴파일 앱 재작성은 등장은 빨라지나 프로젝트 전면 재작성으로 범위 밖.

## 결정 / 다음 단계

- **2026-08-19: 진단만, 코드 변경 보류.** 콜드 스타트를 이 아키텍처의 바닥값으로 수용.
- 등장 지연이 향후 거슬리면 **웜 펫 구조 설계안**부터 착수(§10·notifier 종료금지·session당 1개와의 충돌 정리). 그 전까지는 이 문서가 근거.
