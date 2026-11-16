# NotchMusic

맥북 노치에 지금 재생 중인 음악을 보여 주는 작은 앱입니다.

- 평소에는 노치 양옆에 **앨범 커버**와 **움직이는 막대**만 작게 보입니다.
- 노치에 마우스를 올리면 아래로 펼쳐지면서 **곡 제목, 진행 바, 재생 버튼**이 나옵니다.
  설정에서 **클릭해야 펼쳐지고, 다시 클릭할 때까지 유지**되게 바꿀 수 있습니다.
- 곡이 바뀌면 2초쯤 펼쳐졌다가 다시 접힙니다.
- 막대와 진행 바 색은 **앨범 커버 색에 맞춰** 바뀝니다.
- Apple Music뿐 아니라 **제어 센터의 "지금 재생 중"에 뜨는 것은 다 됩니다** (Spotify, Safari·Chrome의 유튜브 등).

노치가 없는 맥에서는 화면 맨 위 가운데에 같은 모양으로 나옵니다.

## 설치

### 방법 1. 터미널에 한 줄 붙여 넣기 (가장 쉬움)

1. `Command + Space`를 누르고 **터미널**을 입력해 엽니다.
2. 아래 줄을 복사해서 터미널에 붙여 넣고 `Enter`를 누릅니다.

```bash
curl -fsSL https://raw.githubusercontent.com/dnjswldnd-3513/notch-music/main/install.sh | bash
```

3. "설치 완료"가 나오면 끝입니다. 음악을 틀어 보세요.

이 방법은 보안 경고 없이 바로 열립니다. 새 버전이 나왔을 때도 같은 줄을 다시 붙여 넣으면 업데이트됩니다.

### 방법 2. 직접 내려받기

1. [최신 버전 페이지](https://github.com/dnjswldnd-3513/notch-music/releases/latest)에서 `NotchMusic.dmg`를 내려받습니다.
2. 내려받은 파일을 열고, **NotchMusic**을 옆의 **Applications** 폴더로 끌어다 놓습니다.
3. 응용 프로그램 폴더에서 NotchMusic을 엽니다.
4. "Apple에서 확인할 수 없습니다"라는 경고가 뜨면 **완료**를 누릅니다.
   - Apple 유료 인증을 받지 않은 앱이라 뜨는 경고입니다.
5. **시스템 설정 → 개인정보 보호 및 보안**으로 가서 아래쪽의 **그래도 열기**를 누릅니다.
6. 한 번 더 묻는 창에서 **열기**를 누르면 끝입니다. 다음부터는 바로 열립니다.

## 사용법

| 하고 싶은 것 | 방법 |
|---|---|
| 재생, 일시정지, 이전/다음 곡 | 노치에 마우스를 올리고 버튼 누르기 |
| 마우스를 올려도 펼쳐지지 않게 하기 | 노치를 **오른쪽 클릭** → 펼치는 방법 → **클릭하면**. 이제 노치를 누르면 펼쳐지고, 다시 누를 때까지 그대로 유지됩니다 |
| 원하는 위치로 이동 | 진행 바를 누르거나 끌기 |
| 재생 중인 앱 열기 | 펼친 화면의 앨범 커버 누르기 |
| 맥을 켤 때 자동으로 켜기 | 노치를 **오른쪽 클릭** → 로그인 시 자동 실행 켜기 |
| 끄기 | 노치를 **오른쪽 클릭** → NotchMusic 종료 |

아무것도 재생하지 않으면 노치에 아무것도 보이지 않습니다. 앱이 꺼진 게 아닙니다.

## 지우기

1. 노치를 오른쪽 클릭 → **NotchMusic 종료**
2. 응용 프로그램 폴더에서 NotchMusic을 휴지통으로 옮깁니다.

## 지원 환경

- macOS 14 (Sonoma) 이상
- Apple Silicon, Intel 맥 모두 지원

## 직접 빌드하기

Xcode 명령줄 도구(Command Line Tools)만 있으면 됩니다.

```bash
./build.sh            # build/NotchMusic.app 만들기
./build.sh --install  # 만든 뒤 ~/Applications에 설치하고 실행
./build.sh --release  # 배포용 zip, dmg까지 만들기
```

### 동작 원리

macOS 15.4부터 일반 앱은 제어 센터의 재생 정보(MediaRemote)를 읽을 수 없습니다.
그래서 Apple이 서명한 `/usr/bin/perl` 안에서 작은 라이브러리(`Adapter/adapter.m`)를 불러 재생 정보를 읽고,
앱은 그 결과를 한 줄씩 JSON으로 받습니다. 이 우회 방법은
[ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)에서 아이디어를 얻었습니다.

```
NotchMusic.app ──stdin(명령)──▶ /usr/bin/perl run.pl adapter.dylib ──▶ MediaRemote
               ◀──stdout(JSON)──
```

| 파일 | 역할 |
|---|---|
| `Adapter/adapter.m` | 재생 정보 읽기, 재생 명령 보내기 |
| `Sources/NotchMusic/NowPlaying.swift` | 어댑터 실행, 정보 받기 |
| `Sources/NotchMusic/NotchController.swift` | 노치 위 창 위치, 마우스 올림 감지 |
| `Sources/NotchMusic/NotchView.swift` | 노치 모양과 화면 |
| `Sources/NotchMusic/ArtworkColor.swift` | 앨범 커버에서 대표 색 뽑기 |

## 라이선스

MIT
