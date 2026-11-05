# claude-wt-pets — 핵심 규정

이 파일은 AI가 이 프로젝트를 수정할 때 반드시 먼저 읽고 따라야 하는 기준 문서다.
세부 기능 명세는 `docs/feature-spec.md`, 상태 정의는 `STATES.md`가 최종 기준이다.

---

## 1. 서비스 정의

**Claude Code hook 이벤트를 받아 Windows desktop pet으로 session 상태를 표시하는 도구다.**

- Claude Code hook → `hook-entry.ps1` → `notifier.js` → `%TEMP%` 파일 → `pet.ps1` → WPF 창
- pet은 session당 1개, **최대 4개를 동시에** 표시한다.
- 각 pet은 자신의 session 상태를 **독립적으로** 표시한다.
- pet을 선택(Ctrl+클릭)하면 해당 session의 **owner Windows Terminal 창을 앞으로 가져온다**.
- 지원 환경: **Windows Terminal + PowerShell/pwsh + Claude Code 교집합만** 지원한다.

---

## 2. 변경 불가 원칙

아래는 어떤 수정에서도 깨뜨리면 안 되는 동작이다.

**Pet UI**
- topmost overlay WPF 창이다. taskbar와 Alt+Tab에서 숨긴다.
- 마우스 드래그로 위치 이동이 가능하다.
- 더블클릭 → `idle` 복귀.
- Ctrl+클릭 → owner Windows Terminal 창을 foreground로 가져온다.
- 우클릭 → 컨텍스트 메뉴 (상태 초기화, 창 가져오기, 캐릭터 변경, 설정, 종료).
- 상태 이미지가 없으면 같은 캐릭터의 `idle.png`를 fallback으로 사용한다.

**상태 (7개 고정, 추가 금지)**
- `idle`, `thinking`, `done`, `notification`, `sleeping`, `error`, `disconnected`
- 상태 전환 규칙의 단일 진실 소스는 `STATES.md`와 `docs/feature-spec.md` §5다.
- `sleeping`은 `idle` 상태에서 300초 경과 시에만 발생한다. 다른 상태에서는 절대 발생하지 않는다.
- `done`은 자동으로 `idle`로 되돌아가지 않는다.
- `disconnected`는 `notifier.js`에서 만들지 않는다. pet에서 창 focus 실패 시에만 발생한다.

**Slot 관리**
- 1~4번 slot 고정. 5번째 이후 session은 무시한다 (transition log에만 기록).
- 같은 session은 기존 slot을 재사용한다.
- atomic write 방식으로 `%TEMP%` 파일을 갱신한다.

**Owner Window**
- top-level Windows Terminal 창만 대상이다. tab 내부 선택은 구현하지 않는다.
- `session marker`와 `tab title`은 tab 선택용이 아니라 top-level owner 창 식별 보조 근거로만 사용한다.
- `Notification` hook에서는 owner handle을 갱신하지 않는다.
- owner가 비어 있을 때 임의의 visible 창에 붙이지 않는다.
- owner 해석과 복구의 세부 전략은 `docs/feature-spec.md` §7이 기준이다 (변동 가능).

**탭 merge 시 동작**
- 탭이 한 창으로 합쳐져도 각 pet은 독립적으로 표시되어야 한다.
- pet을 숨기거나 하나로 합치지 않는다.
- 여러 pet이 같은 owner_hwnd를 공유할 수 있다 (shared owner).
- 병합 상태에서 pet 선택은 같은 top-level 창을 앞으로 가져오면 성공이다. 내부 tab 전환은 기대하지 않는다.
- 각 pet은 자기 session의 상태만 보여준다.
- 병합 상태에서 정확한 tab 내부 선택은 하지 않아도 된다. 대신 해당 session들이 들어 있는 top-level Windows Terminal 창은 반드시 foreground로 가져와야 한다.
- 탭 병합 자체만으로 pet 연결이 끊기거나 `disconnected`로 떨어지면 안 된다.
- 병합 상태에서 다시 별도 창으로 분리되면, 각 pet은 병합 전 자기 session에 해당하는 top-level Windows Terminal 창을 trusted 경로(session marker 우선)로 다시 찾아야 한다.
- 창 분리 후 pet 선택 시 병합 전 매핑에 맞는 session 창을 foreground해야 한다. 다른 session 창이나 임의의 visible Windows Terminal 창을 포커싱하면 안 된다.
- Windows Terminal 창이나 tab이 5개 이상 있어도 visible 창 개수만으로 owner를 확정하지 않는다.

---

## 3. 절대 하면 안 되는 것

**범위 확장 금지**
- Git Bash, Claude Desktop 내부 터미널, Codex/Gemini session 지원을 추가하지 않는다.
- Windows Terminal tab 내부 직접 선택/focus 기능을 구현하지 않는다.
- HUD 시스템, 알림 배지, 소리, 시스템 트레이 등 pet UI 외 별도 알림 채널을 추가하지 않는다.
- 지원 상태 7개 외의 새로운 상태를 임의로 추가하지 않는다.
- slot 4개 한도를 늘리지 않는다.

**코드 패턴 금지**
- `EncodedCommand` 방식 PowerShell 실행을 사용하지 않는다.
- `AttachConsole` / `SetConsoleTitle`을 session marker probe와 `Claude #slot` tab title 설정 외의 용도로 사용하지 않는다.
- `notifier.js`에서 pet process를 직접 시작하거나 종료하지 않는다. (pet 실행은 `hook-entry.ps1` 책임)

**파일 조작 금지**
- `%TEMP%\claude-wt-pets-transition.log`는 512KB 초과 시 마지막 1000줄 rotation 외에 임의 삭제하지 않는다.
- 사용자가 수동으로 변경한 `config.json` 값을 임의로 되돌리지 않는다. `config.json`은 git에서 제외된 사용자 설정이며, 저장소 기본값은 `config.default.json`이다.

---

## 4. 수정 전 반드시 확인할 것

1. `docs/feature-spec.md` — 기능 명세 최종 기준
2. `STATES.md` — 상태 전환 규칙
3. `docs/qa-checklist-2026-07-08.md` — 최신 QA 체크리스트

수정 후 최소 검증:
```powershell
node --check .\notifier.js
```
PowerShell 파일은 `[System.Management.Automation.Language.Parser]::ParseFile`로 문법 확인 후 커밋한다.

---

## 5. 환경 판정 기준

`hook-entry.ps1`은 아래 조건을 모두 만족해야 실행을 계속한다. 하나라도 실패하면 `skip-unsupported-environment` transition log를 남기고 종료한다.

- Claude session process 확인 가능
- PowerShell parent process 확인 가능
- visible Windows Terminal 창 존재

이 판정 로직을 약화하거나 우회하지 않는다.

---

## 6. Git 규칙

- 커밋 메시지는 `{타입}: {영어 명령형 제목}`(72자 이내) 형식이다. 본문은 선택이며 "왜" 바꿨는지를 쓴다.
- 타입: `feat`(기능), `fix`(버그), `refactor`(동작이 같은 구조 변경), `docs`(문서), `test`(테스트), `chore`(설정·스크립트).
- 한 커밋에는 논리적 변경 하나만 담는다. 서로 무관한 변경은 커밋을 나눈다.
- `git add -A` 대신 파일을 지정해 stage한다. 개인 설정 `config.json`은 커밋하지 않는다.
- `main`에 강제 push하지 않는다. 릴리스에는 `v{major}.{minor}.{patch}` 태그를 붙인다.
