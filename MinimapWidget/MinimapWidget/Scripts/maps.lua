-- maps.lua — 맵 레지스트리(멀티맵) + 좌표 판정/변환. main 이 require("maps") 로 쓴다.
-- 팰월드 1.0 은 본섬(MainMap) 사각형 밖에 별도 맵을 추가했다(월드트리='Tree').
-- 각 맵은 자기 (경계 사각형 + 전용 지도 텍스처)를 가진다. 플레이어가 어느 맵에 서 있는지는 좌표를
-- 경계에 넣어 판정(at)하고, 그 맵의 (텍스처 + 경계 + 줌)으로 통째 스왑한다(스왑은 main 루프가 담당).
--   변환(SWAP+세로뒤집기): u(가로)=(worldY-minY)/spanY,  v(세로)=1-(worldX-minX)/spanX.
--
-- 경계·텍스처 출처 = probe/MapBoundsProbe 실측(→ docs/research/01_newzone-survey.md, 2026-07-12).
--   게임의 GetMapNameByWorldLocation(FVector)->FName 이 'MainMap'/'Tree'/'None' 로 갈리는 지점을
--   네 변마다 이분탐색해 ±0.5 로 복원(값을 읽는 게 아니라 게임 자신의 포함 판정을 잰 것 — TMap
--   WorldMapDataMap 은 UE4SS_mac Lua 로 못 읽는다). 텍스처는 그 맵에 서면 로드되는 .T_WorldMap(본섬)·
--   .T_TreeMap(월드트리), 둘 다 8192². 재측량은 probe/MapBoundsProbe 를 mods.txt 에 넣고 인게임 M 한 번.
--   centerOff = 플레이어를 원 중심에 맞추는 가로 미세보정(경계 오차 아니라 지도 텍스처 여백 메움).
--     MainMap 은 옛 경계 때부터 필요했던 구조적 값. Tree 는 초기 0 → 인게임서 가로 정렬 보고 튜닝.
-- ⚠️ 각 엔트리의 mapRender·viewFrac·tex 는 여기서 안 채운다 — 크기·줌 의존이라 main 의 applyConfig 가
--    런타임에 채워넣고(mapRender/viewFrac), pickTexFor 가 캐시한다(tex). 여기 반환하는 건 같은 테이블
--    참조라, main 이 그 필드를 써도 이 모듈 안에서 그대로 보인다.
local MAPS = {
    { name = "MainMap",
      minX = -1099400.0, maxX = 349400.0, minY = -724400.0, maxY =  724400.0,
      texMatch = "%.t_worldmap$", centerOff = -0.0013,
      pkgPath = "/Game/Pal/Texture/UI/Map/T_WorldMap",
      objPath = "/Game/Pal/Texture/UI/Map/T_WorldMap.T_WorldMap", assetName = "T_WorldMap" },
    { name = "Tree",
      minX =   347352.0, maxX = 689148.0, minY = -818197.0, maxY = -476400.0,
      texMatch = "%.t_treemap$", centerOff = 0.0,
      pkgPath = "/Game/Pal/Texture/UI/Map/T_TreeMap",
      objPath = "/Game/Pal/Texture/UI/Map/T_TreeMap.T_TreeMap", assetName = "T_TreeMap" },
}
for _, m in ipairs(MAPS) do m.spanX = m.maxX - m.minX; m.spanY = m.maxY - m.minY end

-- 플레이어가 선 맵 판정: 좌표를 포함하는 맵. 얇게 겹치는 모서리에선 더 작은(전용) 맵을 우선한다.
-- 어느 맵에도 안 들면 nil('None' = 던전/보스탑처럼 지상지도 무의미 → 미니맵 숨김).
local function mapAt(x, y)
    if not x then return nil end
    local best = nil
    for _, m in ipairs(MAPS) do
        if x >= m.minX and x <= m.maxX and y >= m.minY and y <= m.maxY then
            if not best or m.spanX < best.spanX then best = m end
        end
    end
    return best
end

-- 월드좌표 → 그 맵 텍스처의 픽셀좌표(mapRender 기준). SWAP+세로뒤집기.
local function worldToPix(m, x, y)
    local u =       (y - m.minY) / m.spanY
    local v = 1.0 - (x - m.minX) / m.spanX
    return u * m.mapRender, v * m.mapRender
end

return { list = MAPS, at = mapAt, worldToPix = worldToPix }
