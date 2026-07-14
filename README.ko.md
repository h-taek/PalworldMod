# PalworldMod

English: [README.md](README.md)

팰월드(Palworld) **macOS 네이티브**용 자체제작 QoL 모드 모음.
[UE4SS-Palworld-macOS](https://github.com/h-taek/UE4SS-Palworld-macOS) 로더 위에서 동작하며,
[PalworldModManager](https://github.com/h-taek/PalworldModManager) 앱으로 설치·활성화·자동
업데이트가 처리된다(수동 드롭인도 호환).

> 플랫폼: **macOS (Apple Silicon)** 에서만 테스트 됨.

## 모드

| 모드 | 설명 | 버전 |
|---|---|---|
| [**MinimapWidget**](MinimapWidget/) | 정적 전체지도를 원형으로 크롭한 자체제작 미니맵. 크기/줌/위치를 인게임 ModConfigMenu에서 실시간 조정. 던전·보스타워 진입 시 자동으로 숨김. | `1.3.0` |
| [**ZenaraSkin**](ZenaraSkin/) | 플레이어 외형을 게임 내 최종 탑 보스 **제나라**(`WorldTreeBoss`)로 바꾸는 스킨. 게임 원본 재질·텍스처를 그대로 빌려 자립 동작. | `1.0.0` |

## 설치

**권장 — 모드 매니저 앱**: 릴리즈 zip 을 PalworldModManager 로 가져오면 설치·활성·자동
업데이트가 처리된다.

**수동 드롭인**: 릴리즈 zip 안의 `Pal/` 폴더를 게임 프로젝트 폴더에 병합한다.
자세한 경로·선행 요구는 각 모드 폴더의 README 를 참고.

## 릴리즈 구조 (매니저 자동 업데이트 배선)

단일 레포 안에 모드별 폴더로 나눠 담는다. 배포 산출물 zip 은 **GitHub Releases 애셋**
(모드별 태그, 예: `minimapwidget-v1.0.0`)으로 올리고, 각 모드 폴더의 `update.json` 만
레포에 커밋한다.

자동 업데이트는 2단 홉이다:

```
모드 manifest.json 의 updateURL
  → 원격 update.json  {"version", "url"}          (레포: <모드>/update.json)
    → url 의 릴리즈 zip                             (GitHub Releases 애셋)
```

매니저는 `updateURL` 이 있는 모드만 버전 비교·교체한다.

## 라이선스

[MIT](LICENSE) © h-taek
