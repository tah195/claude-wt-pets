**한국어** | [English](README.en.md)

# claude-wt-pets

Claude Code 세션마다 펫 하나. 펫을 Ctrl+클릭하면 그 세션이 실행 중인 Windows Terminal 창이 앞으로 온다. 탭을 한 창으로 합쳤다가 다시 나눠도 각 펫은 자기 세션의 창을 다시 찾는다.

**상태: 기능 완성, 유지보수 모드.** 버그 수정과 Windows Terminal·Claude Code 변경에 따른 호환성 대응만 한다. 지원 범위 밖의 기능은 추가하지 않는다 ([제한사항](#제한사항)). 개발 과정은 [연표](docs/how-it-was-solved.md#8-연표) 참고.

Claude Code hook 이벤트를 받아 화면 위 데스크톱 펫으로 session 상태를 보여주는 Windows 도구다. 터미널을 Alt+Tab으로 확인하지 않아도, 펫만 보면 Claude가 작업 중인지·답변을 끝냈는지·확인이 필요한지 알 수 있다.

<!-- TODO: 스크린샷/GIF -->

## 기능

- Claude Code session마다 펫 1개, 최대 4개 동시 표시
- 상태 7개: `idle`, `thinking`, `done`, `notification`, `sleeping`, `error`, `disconnected` ([STATES.md](STATES.md))
- Ctrl+클릭 → 해당 session의 Windows Terminal 창을 앞으로 가져옴 (창 단위. 탭 내부 선택은 하지 않음)
- 더블클릭 → `idle` 복귀, 드래그 → 위치 이동
- 우클릭 메뉴: 기본 상태로 돌리기 / 터미널 창 앞으로 가져오기 / 캐릭터 / 설정 / 종료
- 항상 위(topmost), 작업 표시줄·Alt+Tab에 나타나지 않음
- slot별 캐릭터, 배치, 크기 설정 (크기·배치는 재시작 없이 바로 반영)

## 지원 환경

| 항목 | 조건 |
| --- | --- |
| OS | Windows 10/11 |
| 터미널 | Windows Terminal |
| 셸 | Windows PowerShell 5.1 또는 pwsh (Windows Terminal 탭에서 `claude` 실행) |
| 런타임 | Node.js (`node`가 PATH에 있거나 `C:\Program Files\nodejs\node.exe`) |
| 대상 | Claude Code CLI |

Git Bash, Claude Desktop 내부 터미널, 다른 AI CLI는 지원하지 않는다. 지원하지 않는 환경에서는 hook이 실행돼도 펫을 띄우지 않고 조용히 종료한다. 이유는 [docs/support-scope.md](docs/support-scope.md).

## 설치

```powershell
git clone https://github.com/<owner>/claude-wt-pets.git
cd claude-wt-pets
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\install-hooks.ps1 -Scope user
```

`install-hooks.ps1`은 `%USERPROFILE%\.claude\settings.json`에 hook 8개(`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `StopFailure`, `PostToolUseFailure`, `Notification`)를 추가한다. 쓰기 전에 `%USERPROFILE%\.claude\backups\`에 기존 파일을 백업하고, 다른 설정과 다른 hook은 그대로 둔다. `settings.json`이 JSON으로 읽히지 않으면 아무것도 바꾸지 않고 중단한다. 파일을 고친 뒤 다시 실행하면 된다.

hook에는 clone한 폴더의 **절대 경로**가 들어간다. 폴더를 옮기면 설치 명령을 다시 실행한다.

설치 확인:

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\install-hooks.ps1 -Scope user -Audit
```

설치 후 Windows Terminal에서 새로 `claude`를 실행하면 펫이 나타난다. 첫 등장은 PowerShell·WPF 콜드 스타트 때문에 수 초 걸릴 수 있다 ([측정 기록](docs/diagnosis-2026-08-19-pet-launch-latency.md)).

## 제거

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\install-hooks.ps1 -Uninstall
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\install-hooks.ps1 -Uninstall -Audit
```

user/project 양쪽 settings에서 이 도구의 hook만 지운다. 그 뒤 폴더를 삭제하면 된다.

## 캐릭터

기본으로 직접 만든 샘플 캐릭터 `happycat`이 들어 있다. 직접 캐릭터를 추가하는 방법은 [characters/README.md](characters/README.md).

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\set-character.ps1 -List
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\set-character.ps1 -Slot 2 -Character happycat
```

## 설정

펫 우클릭 → `설정`, 또는 아래 CLI로 바꾼다. 기본값은 `config.default.json`에 있고, 설정을 처음 바꾸면 사용자 설정 파일 `config.json`이 생긴다. `config.json`은 git에서 제외되므로 설정을 바꿔도 `git pull`과 충돌하지 않는다. `config.default.json`은 직접 고치지 않는다.

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\set-placement.ps1 -Show
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\set-placement.ps1 -Anchor bottom-right -Direction left
```

| 키 | 의미 |
| --- | --- |
| `defaultCharacter` | slot 지정이 없을 때 쓰는 캐릭터 (기본 `happycat`) |
| `slotCharacters` | slot(1~4)별 캐릭터 |
| `placement.anchor` | `bottom-left` / `bottom-right` / `top-left` / `top-right` |
| `placement.offsetX`, `offsetY`, `slotGap` | 화면 가장자리 여백, 펫 간격 (px) |
| `placement.direction` | 펫이 늘어서는 방향 `left` / `right` |
| `petSize` | 펫 크기 (px, 전체 공통, 기본 120) |

## 동작 원리

```text
Claude Code hook -> hook-entry.ps1 -> notifier.js -> %TEMP% state/registry -> pet.ps1 (WPF)
```

상태 표시는 단순하다. hook이 오면 `notifier.js`가 세션별 상태 파일을 쓰고, 펫은 그 파일을 읽어 그림을 바꾼다.

어려운 부분은 **"이 펫의 세션이 어느 Windows Terminal 창에 있는가"**다. Windows Terminal은 프로세스와 창을 잇는 API를 제공하지 않고, 사용자가 탭을 합치거나 떼어내면 세션이 들어 있는 창이 바뀐다. 이 도구는 다음 원칙으로 이 문제를 다룬다.

- **클릭할 때만 찾는다.** 창을 상시 추적하면 추적 자체가 경합과 탭 제목 깜빡임을 만든다. owner 창이 정확해야 하는 순간은 Ctrl+클릭뿐이므로, 그때만 해석한다.
- **읽기만 한다.** UI Automation으로 각 창의 tab strip을 읽으면 비활성 탭 이름까지 보이므로, 탭이 합쳐진 창에서도 콘솔을 건드리지 않고 세션이 든 창을 찾을 수 있다.
- **추정으로 확정하지 않는다.** 검증 가능한 근거로 후보가 정확히 1개일 때만 창을 가져온다. 모르면 엉뚱한 창을 띄우지 않고 `disconnected`로 알린다.

이 원칙에 이르기까지 무엇을 시도했고 왜 버렸는지는 [docs/how-it-was-solved.md](docs/how-it-was-solved.md)에 정리했다.

| 파일 | 역할 |
| --- | --- |
| `hook-entry.ps1` | hook 진입점, 지원 환경 판정, owner 창 probe, 펫 실행 |
| `notifier.js` | hook payload 해석, slot 배정, state/registry 기록 |
| `pet.ps1` | WPF 펫 UI, 상태 표시, 창 포커스, 종료 감지 |
| `WtPets.Common.ps1` | 공통 설정·캐릭터 helper |
| `install-hooks.ps1` | hook 설치/audit/제거 |
| `set-character.ps1`, `set-placement.ps1` | 설정 CLI |
| `launch-pet.ps1`, `pet-debug.ps1` | 수동 실행/디버그 |

임시 파일은 `%TEMP%\claude-wt-pets-*`에 생기며, 상태 전환 기록은 `%TEMP%\claude-wt-pets-transition.log`에서 볼 수 있다.

## 개발

```powershell
node --check .\notifier.js
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\scripts\test-notifier.ps1
```

상세 명세는 [docs/feature-spec.md](docs/feature-spec.md), 수동 QA는 [docs/qa-checklist-2026-07-08.md](docs/qa-checklist-2026-07-08.md). 설계 기록은 [P2 클릭 시점 해석](docs/design-2026-07-07-p2-click-time-owner.md), [P3 UIA tab strip](docs/design-2026-07-08-p3-uia-tab-strip.md). AI 도구로 수정할 때의 기준은 [CLAUDE.md](CLAUDE.md).

## 제한사항

- Windows Terminal 탭 내부 선택은 하지 않는다. 여러 Claude 탭이 한 창에 있으면 그 창을 앞으로 가져오는 것까지가 정상 동작이다 ([TAB-MOVEMENT-NOTES.md](TAB-MOVEMENT-NOTES.md)).
- 5번째 이후 session은 펫을 만들지 않는다.
- 이 프로젝트는 Anthropic의 공식 도구가 아니다.

## License

[MIT](LICENSE)
