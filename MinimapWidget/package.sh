#!/usr/bin/env bash
# package.sh — MinimapWidget 배포 산출물(GitHub 드롭인 zip + 매니저 자동업데이트 배선) 빌드.
#
# 배포 = GitHub 단일 모드 레포(h-taek/PalworldMod)에서 여러 모드를 폴더로 나눠 배포.
#   - zip 애셋 = GitHub Releases (모드별 태그).
#   - 매니저 자동업데이트(2단 홉):
#       모드 manifest.json 의 updateURL → 원격 update.json {"version","url"} → url 의 zip.
#   - manifest.json / enabled.txt 는 게임 스테이징에서 제외(매니저 classify 규칙).
#
# zip 내부(매니저 임포트·수동 드롭인 둘 다 호환):
#   manifest.json          매니저용(id/version/type/updateURL). 게임엔 안 감.
#   README.txt             설치 안내.
#   Pal/                   게임 프로젝트 폴더 미러 → Palworld.app/Contents/UE/Pal/ 에 병합.
#     Binaries/Win64/Mods/MinimapWidget/   Lua 모드
#     Content/Paks/LogicMods/MinimapFrame_P.*   콘텐츠 pak
#
# 경로는 전부 스크립트 위치 기준 상대(로컬 절대경로 없음). URL은 아래 변수로 단일화.
set -euo pipefail

VERSION="1.3.0"

# --- 배포 좌표(레포/브랜치/태그 스킴) — 레포 구조 바뀌면 여기만 고친다 ---
MOD_ID="MinimapWidget"               # 매니저 라이브러리 id (게임 내 모드 폴더명과 일치)
MOD_NAME="Minimap Widget"            # 매니저 UI 표시명
REPO="h-taek/PalworldMod"            # 단일 모드 레포 (매니저 MOD_REPOSITORY_URL)
BRANCH="main"                        # update.json 을 두는 브랜치
MOD_DIR_IN_REPO="MinimapWidget"      # 레포 안 이 모드의 폴더
TAG="minimapwidget-v${VERSION}"      # 릴리즈 태그
ZIPNAME="MinimapWidget-v${VERSION}-macOS.zip"

UPDATE_JSON_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/${MOD_DIR_IN_REPO}/update.json"
ZIP_DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${ZIPNAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_MOD="$SCRIPT_DIR/MinimapWidget"
SRC_PAK="$SCRIPT_DIR/pak"
DIST="$SCRIPT_DIR/dist"
BUILD="$DIST/build"
ZIP="$DIST/$ZIPNAME"

# 사전조건 확인
[ -f "$SRC_MOD/Scripts/main.lua" ] || { echo "!! 소스 Lua 없음: $SRC_MOD/Scripts/main.lua"; exit 1; }
for ext in pak ucas utoc; do
    [ -f "$SRC_PAK/MinimapFrame_P.$ext" ] || { echo "!! 소스 pak 없음: MinimapFrame_P.$ext"; exit 1; }
done

echo "=== [1/5] 스테이징 트리 조립 (Pal/ 미러) ==="
rm -rf "$BUILD"
MODDST="$BUILD/Pal/Binaries/Win64/Mods/$MOD_ID"
PAKDST="$BUILD/Pal/Content/Paks/LogicMods"
mkdir -p "$MODDST/Scripts" "$PAKDST"
cp "$SRC_MOD/Scripts/"*.lua                           "$MODDST/Scripts/"   # main + 분리 모듈(maps/config/util)
cp "$SRC_MOD/MinimapWidget.modconfig.json"           "$MODDST/"
cp "$SRC_MOD/enabled.txt"                            "$MODDST/"
cp "$SRC_PAK/MinimapFrame_P.pak"  "$SRC_PAK/MinimapFrame_P.ucas" "$SRC_PAK/MinimapFrame_P.utoc" "$PAKDST/"

echo "=== [2/5] manifest.json (매니저 자동업데이트 배선) ==="
cat > "$BUILD/manifest.json" <<EOF
{
  "id": "${MOD_ID}",
  "name": "${MOD_NAME}",
  "version": "${VERSION}",
  "type": "hybrid",
  "updateURL": "${UPDATE_JSON_URL}"
}
EOF

echo "=== [3/5] README.txt ==="
cat > "$BUILD/README.txt" <<EOF
${MOD_NAME} v${VERSION} (macOS)
=================================

팔월드 macOS 네이티브용 자체제작 미니맵 모드다. 정적 전체지도를 원형으로 크롭해
화면 구석에 띄우고, 크기/줌/위치를 인게임 Mod Config 메뉴에서 실시간 조정한다.

권장 설치 = 모드 매니저 앱
--------------------------
매니저(PalworldModManager)로 이 zip 을 가져오면 설치·활성·자동업데이트가 처리된다.
manifest.json 의 updateURL 로 새 버전을 자동 감지한다.

수동 설치(드롭인)
----------------
zip 안의 Pal/ 폴더를 게임 프로젝트 폴더에 병합한다:
  Pal/  →  Palworld.app/Contents/UE/Pal/
  (manifest.json·README.txt 는 게임에 넣지 않는다 — 매니저/안내용)

선행 요구(필수)
--------------
- UE4SS-Palworld-macOS 로더 (이 모드 구동의 전제)
- ModConfigMenu  (크기/줌/위치 설정 UI. 별도)
- BPModLoaderMod (인게임 Mod Config 메뉴 스폰)

설정 저장(중요)
--------------
macOS 샌드박스라 읽기전용 .app 번들에 저장 쓰기가 막힌다. 크기/줌/위치 저장이 반영되려면
설정 파일을 컨테이너로 우회시키는 심링크가 필요하고, 이 처리는 매니저 앱이 담당한다.

플랫폼: macOS(Apple Silicon)에서 테스트됨. 윈도우는 검증되지 않았다(동작 가능성 있음).
EOF

echo "=== [4/5] zip 패키징 ==="
rm -f "$ZIP"
( cd "$BUILD" && zip -r -q -X "$ZIP" manifest.json README.txt Pal )

echo "=== [5/5] update.json (레포 ${MOD_DIR_IN_REPO}/update.json 로 커밋할 것) ==="
cat > "$DIST/update.json" <<EOF
{
  "version": "${VERSION}",
  "url": "${ZIP_DOWNLOAD_URL}"
}
EOF

echo ""
echo "=== 완료 ==="
echo "zip 산출물:   $ZIP"
echo "update.json:  $DIST/update.json  → 레포 ${REPO} 의 ${MOD_DIR_IN_REPO}/update.json 로 커밋"
echo "릴리즈 태그:  ${TAG} (애셋으로 위 zip 업로드)"
echo ""
unzip -l "$ZIP"
