#!/usr/bin/env bash
# package.sh — ZenaraSkin 배포 산출물(GitHub 드롭인 zip + 매니저 자동업데이트 배선) 빌드.
#
# 배포 = GitHub 단일 모드 레포(h-taek/PalworldMod)에서 여러 모드를 폴더로 나눠 배포.
#   - zip 애셋 = GitHub Releases (모드별 태그).
#   - 매니저 자동업데이트(2단 홉):
#       모드 manifest.json 의 updateURL → 원격 update.json {"version","url"} → url 의 zip.
#   - manifest.json 은 게임 스테이징에서 제외(매니저 classify 규칙).
#
# 이 모드는 pak 전용 스킨(Lua 없음). 콘텐츠 pak 3종은 ~mods 에 평평하게 배치된다.
#
# zip 내부(매니저 임포트·수동 드롭인 둘 다 호환):
#   manifest.json          매니저용(id/version/type=pak/updateURL). 게임엔 안 감.
#   README.txt             설치 안내.
#   Pal/                   게임 프로젝트 폴더 미러 → Palworld.app/Contents/UE/Pal/ 에 병합.
#     Content/Paks/~mods/TreeGirl_P.{pak,ucas,utoc}   콘텐츠 스킨 pak(3종)
#
# 경로는 전부 스크립트 위치 기준 상대(로컬 절대경로 없음). URL은 아래 변수로 단일화.
set -euo pipefail

VERSION="1.0.0"

# --- 배포 좌표(레포/브랜치/태그 스킴) — 레포 구조 바뀌면 여기만 고친다 ---
MOD_ID="ZenaraSkin"                   # 매니저 라이브러리 id (게임 내 모드 폴더명과 일치)
MOD_NAME="Zenara Skin"                # 매니저 UI 표시명
REPO="h-taek/PalworldMod"             # 단일 모드 레포 (매니저 MOD_REPOSITORY_URL)
BRANCH="main"                         # update.json 을 두는 브랜치
MOD_DIR_IN_REPO="ZenaraSkin"          # 레포 안 이 모드의 폴더
PAK_BASENAME="TreeGirl_P"             # 콘텐츠 pak 3종의 basename
TAG="zenaraskin-v${VERSION}"          # 릴리즈 태그
ZIPNAME="ZenaraSkin-v${VERSION}-macOS.zip"

UPDATE_JSON_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/${MOD_DIR_IN_REPO}/update.json"
ZIP_DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/${ZIPNAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_PAK="$SCRIPT_DIR/pak"
DIST="$SCRIPT_DIR/dist"
BUILD="$DIST/build"
ZIP="$DIST/$ZIPNAME"

# 사전조건 확인 — pak 3종
for ext in pak ucas utoc; do
    [ -f "$SRC_PAK/${PAK_BASENAME}.$ext" ] || { echo "!! 소스 pak 없음: ${PAK_BASENAME}.$ext"; exit 1; }
done

echo "=== [1/5] 스테이징 트리 조립 (Pal/ 미러, 스킨은 ~mods 평평) ==="
rm -rf "$BUILD"
PAKDST="$BUILD/Pal/Content/Paks/~mods"
mkdir -p "$PAKDST"
cp "$SRC_PAK/${PAK_BASENAME}.pak" "$SRC_PAK/${PAK_BASENAME}.ucas" "$SRC_PAK/${PAK_BASENAME}.utoc" "$PAKDST/"

echo "=== [2/5] manifest.json (매니저 자동업데이트 배선) ==="
cat > "$BUILD/manifest.json" <<EOF
{
  "id": "${MOD_ID}",
  "name": "${MOD_NAME}",
  "version": "${VERSION}",
  "type": "pak",
  "updateURL": "${UPDATE_JSON_URL}"
}
EOF

echo "=== [3/5] README.txt ==="
cat > "$BUILD/README.txt" <<EOF
${MOD_NAME} v${VERSION} (macOS)
=================================

팔월드 플레이어 외형 스킨. 플레이어 외형을 게임 내 최종 탑 보스
'제나라(WorldTreeBoss)'로 바꾼다. 색·텍스처는 게임 원본을 참조하므로 자립 동작하고,
외부 머리숨김 모드가 필요 없다.

권장 설치 = 모드 매니저 앱
--------------------------
매니저(PalworldModManager)로 이 zip 을 가져오면 설치·활성·자동업데이트가 처리된다.
manifest.json 의 updateURL 로 새 버전을 자동 감지한다.

수동 설치(드롭인)
----------------
zip 안의 Pal/ 폴더를 게임 프로젝트 폴더에 병합한다:
  Pal/  →  Palworld.app/Contents/UE/Pal/
  (manifest.json·README.txt 는 게임에 넣지 않는다 — 매니저/안내용)

주의
----
- 다른 전신 스킨(예: 사야)과 동시 사용 불가 — 같은 의상 슬롯을 덮어쓴다. 하나만 활성.
- 플랫폼: macOS(Apple Silicon)에서 테스트됨. 윈도우는 검증되지 않았다(동작 가능성 있음).
- 게임 대규모 업데이트로 원본 보스 자산 경로가 바뀌면 외형이 깨질 수 있다(재빌드 필요).
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
cp "$DIST/update.json" "$SCRIPT_DIR/update.json"

echo ""
echo "=== 완료 ==="
echo "zip 산출물:   $ZIP"
echo "update.json:  $DIST/update.json  → 레포 ${REPO} 의 ${MOD_DIR_IN_REPO}/update.json 로 커밋"
echo "릴리즈 태그:  ${TAG} (애셋으로 위 zip 업로드)"
echo ""
unzip -l "$ZIP"
