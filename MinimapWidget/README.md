# MinimapWidget — 팔월드 자체제작 미니맵 모드 (macOS)

정적 전체지도를 원형으로 크롭해 화면 구석에 띄우는 자체제작 미니맵이다. 크기·줌·위치를
인게임 ModConfigMenu에서 실시간 조정하며, 타이틀↔월드 왕복만으로 반영된다(재시작 불필요).
던전·보스타워 등 지하 인스턴스(플레이어 Z < -15000) 진입 시 지상 지도가 무의미하므로
미니맵을 자동으로 숨긴다. UE4SS 릴리즈에는 동봉하지 않고 별도 배포한다.

## 구성

```
MinimapWidget/
├── MinimapWidget/                       UE4SS Lua 모드 (배포 소스)
│   ├── Scripts/main.lua                 미니맵 위젯 조립·마커·config 적용
│   ├── MinimapWidget.modconfig.json     ModConfigMenu 설정 스키마(크기/줌/위치)
│   └── enabled.txt                      활성화 마커(내용 무시)
├── pak/                                 커스텀 콘텐츠 pak(빌드 산출물)
│   ├── MinimapFrame_P.pak
│   ├── MinimapFrame_P.ucas              T_MinimapFrame 텍스처 + M_MinimapMap 머티리얼
│   └── MinimapFrame_P.utoc
├── package.sh                           배포 zip 빌드(Nexus 드롭인)
└── dist/                                산출물 (package.sh 결과, git 미추적 권장)
    └── MinimapWidget-v1.1.0-macOS.zip
```

## 배포 패키징 (GitHub + 매니저 자동업데이트)

`bash package.sh` 실행 → 산출:
- `dist/MinimapWidget-v1.1.0-macOS.zip` — 배포 zip(릴리즈 애셋으로 업로드)
- `dist/update.json` — 원격 버전 매니페스트(레포에 커밋)

**zip 내부(매니저 임포트·수동 드롭인 둘 다 호환):**
```
manifest.json   매니저용(id/name/version/type/updateURL). 게임엔 안 감(classify 제외)
README.txt      설치 안내
Pal/            게임 프로젝트 폴더 미러 → Palworld.app/Contents/UE/Pal/ 에 병합
```
매니저 classify가 `Pal/Binaries/Win64/Mods/<name>` 는 마지막 `Mods` 세그먼트로 평탄화,
`Content/Paks/LogicMods/*` 는 LogicMods 로 라우팅한다 → 같은 zip 이 매니저 임포트에도, 수동
드롭인에도 맞는다.

**자동업데이트 배선(2단 홉):** manifest.json 의 `updateURL` → 원격 `update.json`
`{"version","url"}` → `url` 의 릴리즈 zip. 매니저가 updateURL 있는 모드만 버전 비교·교체한다.

**단일 레포 다중 모드:** `github.com/h-taek/PalworldMod` 안에 모드별 폴더(`MinimapWidget/update.json`)
로 나눠 담고, zip 은 GitHub Releases 애셋(모드별 태그 `minimapwidget-v1.0.0`)으로 올린다.

**배포 좌표(레포/브랜치/태그)는 `package.sh` 상단 변수로 단일화** — 레포 구조 바뀌면 거기만
고친다. 버전도 `VERSION` 한 곳. 경로는 전부 스크립트 위치 기준 상대(로컬 절대경로 없음).

## 배포(설치) 레이아웃

- `MinimapWidget/` → 컨테이너 `.../Data/UE4SS/Mods/MinimapWidget/`
- `pak/MinimapFrame_P.*` → 게임 번들 `.../Content/Paks/LogicMods/`
- `.modconfig.json` 저장은 샌드박스 쓰기벽 때문에 **컨테이너 심링크가 있어야** 저장된다.
  설치 단계에서 `02_UE4SS_mac/tools/link-modconfigs.sh` 로직(매니저 대역)을 반영해야 한다.

## 의존 모드

- **ModConfigMenu** — 설정 UI 프레임워크(별도). 미니맵 크기/줌/위치 패널을 여기에 등록한다.
- **BPModLoaderMod** — 인게임 메뉴 스폰에 필요(켜져 있어야 Mod Config 메뉴가 뜬다).

## 산출물(pak) 빌드 방법

pak 소스와 빌드 파이프라인은 `02_UE4SS_mac`에 남아 있다(경로가 그쪽 UE 쿡 환경에
하드코딩되어 있어 함께 옮기지 않았다).

- 툴: `02_UE4SS_mac/tools/{gen_minimap_frame.py, ue_import_texture.py, build-texture-pak.sh}`
- 쿡 워크스페이스: `02_UE4SS_mac/fixtures.nosync/ue51-modtest/`
- 재빌드: `02_UE4SS_mac/tools/build-texture-pak.sh` 실행 →
  `pakchunk1001-Mac.*`가 `MinimapFrame_P.*`로 LogicMods에 드롭된다.
  드롭된 결과를 이 폴더 `pak/`로 복사해 산출물 아카이브를 갱신한다.
- 핵심 함정: `bShareMaterialShaderCode=False`가 없으면 셰이더가 우리 청크에 안 담겨 투명 렌더된다.

## 좌표·레이아웃 메모

- 지도 = 커스텀 머티리얼 `M_MinimapMap`(UV패닝 + 원형 알파마스크)의 MID로 그려 모서리 투명.
- 프레임 = 커스텀 텍스처 `T_MinimapFrame`(흰 링 + 시안 글로우).
- 마커 = 액터 직접 열거 + 나침반 POI 실아이콘(워프/타워/던전/여신상/기지, 화살표는 ZOrder 최상단).
- 크기/줌/위치는 config로 결정(진입마다 재계산). 기본값 288 / 줌 1 / 9%·15%.
- world→텍스처 변환식은 SWAP + 세로뒤집기(u=worldY, v=1-worldX). 상세 이력은 02 문서 참조.
