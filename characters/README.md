# 캐릭터 추가하기

`characters/` 아래에 폴더 하나가 캐릭터 하나다. 폴더 이름이 캐릭터 이름이 된다.

```text
characters/
  내캐릭터/
    idle.png
    thinking.png
    done.png
    notification.png
    sleeping.png
    error.png
    disconnected.png
```

- 파일명은 위 7개 상태 이름과 정확히 같아야 한다 (상태 의미는 `../STATES.md`).
- 없는 상태 파일은 같은 캐릭터의 `idle.png`로 대신 표시한다. 최소 `idle.png` 하나는 있어야 한다.
- `.`으로 시작하는 폴더는 캐릭터 목록에서 제외된다.
- 권장 규격: 투명 배경 PNG, 256×256 전후, 장당 수백 KB 이하. 기본 표시 크기는 120px이다.
- 7장을 같은 구도로 맞추고 표정·소품만 바꾸면 상태 전환이 자연스럽다.

적용 방법:

```powershell
# 목록 확인
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\set-character.ps1 -List
# 기본 캐릭터 지정
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\set-character.ps1 -Default 내캐릭터
# slot별 지정
powershell -NoProfile -ExecutionPolicy RemoteSigned -File .\set-character.ps1 -Slot 2 -Character 내캐릭터
```

또는 pet 우클릭 → `캐릭터` 메뉴에서 바로 바꿀 수 있다 (해당 slot 기본값으로 저장됨).

저작권이 있는 캐릭터 이미지를 이 저장소에 올리지 말 것. 개인 PC의 `characters/`에만 두면 된다.

`happycat`은 작성자가 직접 만든 샘플 캐릭터다.
