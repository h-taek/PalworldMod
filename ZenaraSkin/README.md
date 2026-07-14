# ZenaraSkin — 제나라 자립 외형 모드 (macOS)

팰월드 여성 플레이어 외형을 **제나라(게임 내 최종 탑 보스, 코드명 `WorldTreeBoss`)**로 바꾸는 스킨. **게임 원본 자산을 빌려 쓰는 방식**(사야 모드와 동일) — 색·텍스처를 게임에서 참조하므로 자립 동작하고, 외부 머리숨김 모드가 필요 없다. 인게임 검증 완료(외형·색·머리·머리카락·크래시 OK, 2026-07-15).

## 디스크 구조

```
ZenaraSkin/
  pak/                      배포물(게임에 바로 넣는 3종)
    TreeGirl_P.pak  (347B 스텁) / TreeGirl_P.ucas / TreeGirl_P.utoc
  src/                      모드 소스(언팩 트리, 69 자산) — 재포장용
    Pal/Content/Pal/Model/Character/Player/
      Outfit/SK_Player_Female_Outfit_{Ancient,Bronze,Cloth,Hunter,Iron,OldCloth}001/…  (의상 6)
      Head/Head{001..026}/SK_Player_Female_Head###   (빈 머리 스텁 26)
      Hair/Hair{001..037}/SK_Player_Hair###          (빈 머리카락 스텁 37)
  README.md
```

## 설치 (최소 구성 = 3파일)

게임 `~mods`에 3종만 복사(콘텐츠는 `.ucas`/`.utoc`, `.pak`은 스텁 마커):
```
M=/Applications/Palworld.app/Contents/UE/Pal/Content/Paks/~mods
cp ZenaraSkin/pak/TreeGirl_P.{pak,ucas,utoc} "$M"/
```

**⚠️ 사야 등 다른 전신 스킨과 충돌** — 둘 다 같은 플레이어 의상 경로를 덮어쓴다. **한 번에 하나만** 활성.

**이 PC 현재 상태(2026-07-15):** `~mods`에 제나라 활성, 사야는 `reference/SkinMod/_saya_disabled_backup/`에 빼둠. 사야로 복귀:
```
M=/Applications/Palworld.app/Contents/UE/Pal/Content/Paks/~mods
B=reference/SkinMod/_saya_disabled_backup
rm -f "$M"/TreeGirl_P.{pak,ucas,utoc}; mv "$B"/ZFrancisLouis_PlayableSaya_P.* "$M"/
```

## 동작 방식 (핵심)

1. **의상 6벌** = 게임 `SK_NPC_WorldTreeBoss001` 메시를 6개 플레이어 의상 슬롯으로 재배치. 메시 "자기 이름"만 플레이어 경로로 바꾸고, **재질 8개(`MI_NPC_WorldTreeBoss*`)·골격(`SK_PalHuman_Skeleton`)·피직스는 게임 것 그대로 참조** → 게임 텍스처로 렌더.
2. **머리/머리카락 겹침 제거** = 제나라 머리·머리카락은 보스 메시에 내장. 바닐라 머리 26·머리카락 37 프리셋을 **빈 껍데기 메시**로 전부 덮어 숨김.

## 제약 (실측)

- **여성 캐릭터 전용** (메시 `SK_Player_Female_*` + 여성 보스).
- **Mac arm64 전용** (IoStore Mac 쿡 → 윈도우 불가).
- **게임 버전 종속** — `MI_NPC_WorldTreeBoss*`·`SK_PalHuman_Skeleton` 경로 참조. 팰월드 업데이트로 경로 변경 시 회색/투명 → 재빌드 필요.

## 재빌드

도구: **repak**(`~/.cargo/git/checkouts/repak-*/*/`에서 `cargo build --release -p repak_cli`), **retoc**(`03_PalworldModManager/src-tauri/resources/retoc`).

소스만 수정 시 → `src/` 재포장:
```
repak pack --version V11 ZenaraSkin/src TreeGirl_P.pak
retoc to-zen --version UE5_1 TreeGirl_P.pak TreeGirl_P.utoc      # .ucas/.utoc 생성
# .pak 은 빈 디렉토리를 repak pack 한 0엔트리 스텁으로 교체 → pak/ 에 3종 배치
```
게임 패치로 경로가 바뀌면(전체 재추출): `retoc to-legacy -f WorldTreeBoss --no-shaders --version UE5_1 <global+Pal-Mac.utoc 폴더> <out>` 로 재추출 후, 메시 self-path를 **헤더 `folder_name`(오프셋 36)와 네임맵 self 엔트리 두 곳 모두** 플레이어 의상 경로로 치환(`unreal_asset` crate). 상세 함정 → 메모리 `palworld-skin-mod-pipeline`.

## 저작권

배포물엔 Pocketpair의 보스 메시 지오메트리(6벌)가 담긴다(텍스처는 미포함, 게임 참조). 모든 스킨 모드와 동일 상황 — 통상 **무료·비상업·출처표기** 선에서 공유.
