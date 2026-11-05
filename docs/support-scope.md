# claude-wt-pets 지원 범위

작성일: 2026-05-06

## 결정

`claude-wt-pets`는 **Windows Terminal의 PowerShell 탭에서 실행한 Claude Code**만 공식 지원한다.

이 범위는 단순한 실행 환경 제한이 아니라, pet이 각 Claude Code 세션의 실제 터미널 창을 정확히 따라가기 위한 전제다.

## 용어 구분

터미널과 PowerShell은 동일하지 않다.

- **Windows Terminal**: pet이 붙을 top-level window, 즉 `owner_hwnd`를 찾고 앞으로 가져오는 대상이다.
- **PowerShell**: Windows Terminal 안에서 Claude Code를 실행하는 shell이며, console 연결과 title probe의 기준이 된다.
- **Claude Code**: hook을 발생시키는 session process다.

따라서 "터미널 지원" 또는 "PowerShell 지원"이라고만 쓰면 범위가 부정확하다. 정확한 표현은 **Windows Terminal + PowerShell + Claude Code**다.

## 지원 대상

- Windows 환경
- Windows Terminal
- Windows Terminal 안의 PowerShell 탭
- 해당 PowerShell에서 `claude` 명령으로 실행한 Claude Code

## 지원하지 않는 대상

다음 환경은 현재 공식 지원 대상으로 보지 않는다.

- Claude Desktop에서 실행되는 Claude Code
- Git Bash
- WSL
- VSCode integrated terminal
- cmd
- Windows Terminal이 아닌 일반 console host
- 기타 terminal host에서 실행한 Claude Code

미지원 환경에서도 Claude hook 이벤트 일부가 발생할 수는 있지만, `claude-wt-pets`가 요구하는 owner window 식별 조건을 만족한다고 보장할 수 없다.

## 좁게 잡는 이유

이 프로젝트의 핵심 가치는 단순한 상태 표시가 아니라, **각 pet이 자기 Claude Code 세션의 Windows Terminal 창을 정확히 따라가는 것**이다.

현재 구현은 다음 정보에 강하게 의존한다.

- Claude Code session id
- Claude Code session process id
- PowerShell parent process id
- Windows Terminal의 visible window 목록
- `owner_hwnd`
- `AttachConsole` 기반 title probe
- Windows Terminal 창 앞으로 가져오기

Claude Desktop, WSL, Git Bash, VSCode integrated terminal은 이 연결 구조가 다르다. 같은 로직에 억지로 포함하면 잘못된 창에 붙거나, stale `owner_hwnd`를 복구하는 과정에서 다른 세션 창을 가져올 위험이 커진다.

## 운영 원칙

지원 범위 밖의 환경에서는 hook 이벤트를 처리하지 않는다. pet을 띄우지 않고, 상태도 표시하지 않고, 관련 파일도 만들지 않는다.

구체적인 동작은 다음과 같다.

1. 지원 환경을 만족하지 않으면 `notifier.js`를 호출하지 않는다.
2. `%TEMP%\claude-wt-pets-state-{slot}.json` 상태 파일을 만들지 않는다.
3. `%TEMP%\claude-wt-pets-registry.json` session registry를 만들거나 갱신하지 않는다.
4. `%TEMP%\claude-wt-pets-pet-{slot}.pid` pet pid 파일을 만들지 않는다.
5. transition log에도 별도 기록을 남기지 않고 조용히 종료한다.
6. 이미 떠 있는 pet이 미지원 환경의 session에 잘못 연결되지 않도록 한다.

## 향후 확장 조건

나중에 Claude Desktop이나 다른 terminal host를 지원하려면 현재 로직에 조건문을 추가하는 방식이 아니라 adapter를 분리해야 한다.

예상 분리 단위는 다음과 같다.

- `PowerShellTerminalProvider`: Windows Terminal + PowerShell 전용 owner 탐지와 focus 처리
- `ClaudeDesktopProvider`: Claude Desktop 실행 구조에 맞는 별도 session/window 처리
- 공통 session state writer
- 공통 pet UI

이 분리가 되기 전까지는 공식 지원 범위를 **Windows Terminal + PowerShell + Claude Code**로 유지한다.
