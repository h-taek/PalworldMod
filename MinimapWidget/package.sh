#!/usr/bin/env bash
# package.sh — MinimapWidget 배포 산출물 빌드 (macOS zip + Windows zip 두 개).
#
# 배포 = GitHub 단일 모드 레포(h-taek/PalworldMod)에서 여러 모드를 폴더로 나눠 배포.
#   - zip 애셋 = GitHub Releases (모드별 태그). macOS/Windows 두 zip 을 애셋으로 올린다.
#   - 매니저 자동업데이트(2단 홉, 매니저는 macOS 전용):
#       모드 manifest.json 의 updateURL → 원격 update.json {"version","url"} → url 의 macOS zip.
#   - manifest.json / enabled.txt 는 게임 스테이징에서 제외(매니저 classify 규칙).
#
# 하이브리드 모드(Lua 본체 + 콘텐츠 pak). Lua 는 양 플랫폼 동일(UE4SS 는 mac 도 Binaries/Win64 미러).
# macOS 와 Windows 의 유일한 차이는 pak 포맷이다:
#   - macOS  = IoStore 트리오(.pak 스텁 + .ucas + .utoc)  ← 맥 게임이 로드하는 유일 포맷. 소스: pak/
#   - Windows = 단일 legacy pak(.pak 하나)               ← Nexus 표준. 소스: pak-win/
# 두 소스 pak 모두 커밋된 배포물이라 이 스크립트는 순수 조립만 한다(외부 도구 불필요).
# pak-win/ 재생성은 tools/build-win-paks.sh 참조.
#
# zip 내부(매니저 임포트·수동 드롭인 둘 다 호환):
#   manifest.json          매니저용(id/version/type=hybrid/updateURL). 게임엔 안 감.
#   README.txt             설치 안내(플랫폼별).
#   Pal/                   게임 프로젝트 폴더 미러.
#     Binaries/Win64/Mods/MinimapWidget/          Lua 모드 (양 플랫폼 동일)
#     Content/Paks/LogicMods/MinimapFrame_P.*      콘텐츠 pak (macOS=3종 / Windows=단일)
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
PAK_BASENAME="MinimapFrame_P"        # 콘텐츠 pak basename
TAG="minimapwidget-v${VERSION}"      # 릴리즈 태그

ZIPNAME_MAC="MinimapWidget-v${VERSION}-macOS.zip"
ZIPNAME_WIN="MinimapWidget-v${VERSION}-Windows.zip"

UPDATE_JSON_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/${MOD_DIR_IN_REPO}/update.json"
# 자동업데이트(매니저=macOS)는 macOS zip 을 가리킨다.
ZIP_DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${ZIPNAME_MAC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_MOD="$SCRIPT_DIR/MinimapWidget"  # Lua 소스
SRC_PAK_MAC="$SCRIPT_DIR/pak"        # IoStore 트리오 (macOS)
SRC_PAK_WIN="$SCRIPT_DIR/pak-win"    # 단일 legacy pak (Windows)
DIST="$SCRIPT_DIR/dist"

# 사전조건 확인 — Lua + macOS 트리오 3종 + Windows 단일 pak
[ -f "$SRC_MOD/Scripts/main.lua" ] || { echo "!! 소스 Lua 없음: $SRC_MOD/Scripts/main.lua"; exit 1; }
for ext in pak ucas utoc; do
    [ -f "$SRC_PAK_MAC/${PAK_BASENAME}.$ext" ] || { echo "!! macOS 소스 pak 없음: pak/${PAK_BASENAME}.$ext"; exit 1; }
done
[ -f "$SRC_PAK_WIN/${PAK_BASENAME}.pak" ] || { echo "!! Windows 소스 pak 없음: pak-win/${PAK_BASENAME}.pak (tools/build-win-paks.sh 로 생성)"; exit 1; }

# Lua 모드 스테이징 (양 플랫폼 동일) — $1=build dir
stage_lua() {
    local moddst="$1/Pal/Binaries/Win64/Mods/$MOD_ID"
    mkdir -p "$moddst/Scripts"
    cp "$SRC_MOD/Scripts/"*.lua                "$moddst/Scripts/"   # main + 분리 모듈(maps/config/util)
    cp "$SRC_MOD/MinimapWidget.modconfig.json" "$moddst/"
    cp "$SRC_MOD/enabled.txt"                  "$moddst/"
}

# manifest.json — 매니저 자동업데이트 배선 ($1=build dir)
write_manifest() {
cat > "$1/manifest.json" <<EOF
{
  "id": "${MOD_ID}",
  "name": "${MOD_NAME}",
  "version": "${VERSION}",
  "type": "hybrid",
  "updateURL": "${UPDATE_JSON_URL}"
}
EOF
}

# README.txt ($1=build dir, $2=플랫폼 라벨, $3=설치 대상 경로 안내, $4=플랫폼 주석)
write_readme() {
cat > "$1/README.txt" <<EOF
${MOD_NAME} v${VERSION} ($2)
=================================

팔월드용 자체제작 미니맵 모드다. 정적 전체지도를 원형으로 크롭해
화면 구석에 띄우고, 크기/줌/위치를 인게임 Mod Config 메뉴에서 실시간 조정한다.

권장 설치 = 모드 매니저 앱 (macOS)
--------------------------------
매니저(PalworldModManager)로 이 zip 을 가져오면 설치·활성·자동업데이트가 처리된다.
manifest.json 의 updateURL 로 새 버전을 자동 감지한다. (매니저는 macOS 전용)

수동 설치(드롭인)
----------------
zip 안의 Pal/ 폴더를 게임 프로젝트 폴더에 병합한다:
  $3
  (manifest.json·README.txt 는 게임에 넣지 않는다 — 매니저/안내용)

선행 요구(필수)
--------------
- UE4SS 로더 (이 모드 구동의 전제)
- ModConfigMenu  (크기/줌/위치 설정 UI. 별도)
- BPModLoaderMod (인게임 Mod Config 메뉴 스폰)

$4
EOF
}

# 한 플랫폼 zip 조립 ($1=platform: macos|windows)
build_platform() {
    local platform="$1" build zip pakdst
    case "$platform" in
      macos)   build="$DIST/build-macos";   zip="$DIST/$ZIPNAME_MAC" ;;
      windows) build="$DIST/build-windows"; zip="$DIST/$ZIPNAME_WIN" ;;
    esac

    rm -rf "$build"
    stage_lua "$build"
    pakdst="$build/Pal/Content/Paks/LogicMods"
    mkdir -p "$pakdst"
    write_manifest "$build"

    if [ "$platform" = "macos" ]; then
        cp "$SRC_PAK_MAC/${PAK_BASENAME}.pak" "$SRC_PAK_MAC/${PAK_BASENAME}.ucas" "$SRC_PAK_MAC/${PAK_BASENAME}.utoc" "$pakdst/"
        write_readme "$build" "macOS" \
          "Pal/  →  Palworld.app/Contents/UE/Pal/" \
          "설정 저장: macOS 샌드박스라 읽기전용 .app 번들에 저장 쓰기가 막힌다. 크기/줌/위치 저장 반영에는
설정 파일을 컨테이너로 우회시키는 심링크가 필요하고, 이 처리는 매니저 앱이 담당한다.

플랫폼: macOS(Apple Silicon)에서 인게임 테스트됨."
    else
        cp "$SRC_PAK_WIN/${PAK_BASENAME}.pak" "$pakdst/"
        write_readme "$build" "Windows" \
          "Pal/  →  ...\\steamapps\\common\\Palworld\\Pal\\" \
          "플랫폼: Windows(UE4SS). 콘텐츠 pak 은 검증된 Nexus 모드와 동일한 단일 legacy pak 포맷이나,
인게임 실측은 macOS 에서 수행됨. 설정은 Win64 하위 config 파일에 직접 저장된다(심링크 불필요)."
    fi

    rm -f "$zip"
    ( cd "$build" && zip -r -q -X "$zip" manifest.json README.txt Pal )
    echo "  → $zip"
}

echo "=== [1/3] macOS zip (Lua + IoStore 트리오) ==="
build_platform macos

echo "=== [2/3] Windows zip (Lua + 단일 legacy pak) ==="
build_platform windows

echo "=== [3/3] update.json (레포 ${MOD_DIR_IN_REPO}/update.json 로 커밋할 것 — macOS zip 가리킴) ==="
cat > "$DIST/update.json" <<EOF
{
  "version": "${VERSION}",
  "url": "${ZIP_DOWNLOAD_URL}"
}
EOF

echo ""
echo "=== 완료 ==="
echo "macOS zip:    $DIST/$ZIPNAME_MAC   (릴리즈 애셋 + update.json 이 가리키는 대상)"
echo "Windows zip:  $DIST/$ZIPNAME_WIN   (릴리즈 애셋)"
echo "update.json:  $DIST/update.json  → 레포 ${REPO} 의 ${MOD_DIR_IN_REPO}/update.json 로 커밋"
echo "릴리즈 태그:  ${TAG} (위 두 zip 을 애셋으로 업로드)"
echo ""
echo "--- macOS zip 내용 ---"; unzip -l "$DIST/$ZIPNAME_MAC"
echo "--- Windows zip 내용 ---"; unzip -l "$DIST/$ZIPNAME_WIN"
