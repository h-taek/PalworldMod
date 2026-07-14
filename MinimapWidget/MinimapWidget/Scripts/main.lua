-- MinimapWidget — 팔월드 macOS용 자체제작 미니맵.
-- 정적 전체지도를 원형으로 크롭해 화면 구석에 띄우고, 워프/타워/던전/여신상/기지 마커를 얹는다.
-- 마커는 맵 전역에 로드된 액터라 build 때 FindAllOf("Actor") 1회로 분류·좌표 캐시한다.
-- 크기·줌·위치는 ModConfigMenu 설정(modconfig.json)에서 읽어 월드 진입마다 적용한다.
--
-- 맵 레지스트리·좌표(maps), 설정 로드(config), 순수 헬퍼(util)는 형제 모듈로 분리(같은 Scripts 폴더).
--   경계 실측·변환 근거는 maps.lua 헤더 참조. UE4SS 는 모드 자기 Scripts/<name>.lua 를 require 로 찾는다.
local UEHelpers = require("UEHelpers")
local maps   = require("maps")
local config = require("config")
local util   = require("util")
local MAPS       = maps.list         -- 맵 레지스트리(엔트리에 mapRender/viewFrac/tex 를 런타임에 채움)
local mapAt      = maps.at           -- 좌표 → 소속 맵(없으면 nil)
local worldToPix = maps.worldToPix   -- 월드좌표 → 그 맵 텍스처 픽셀
local isv        = util.isv
local full       = util.full
local classify   = util.classify
local posKey     = util.posKey

-- 특수지역(던전/보스타워/보스탑) 진입 시 미니맵 숨김 임계 높이.
--   실측: 지상 Z ≈ -2,000~+6,800 인데, 던전/탑은 입구 지하의 별도 인스턴스라 Z 가 뚝 떨어진다
--   (일반던전 ≈-26,900 · 테라리아던전 ≈-41,800 · 보스탑 ≈-64,900). 그 사이(-8k~-26k)는 데이터가
--   없어, -15000 을 경계로 삼으면 지상/특수지역이 여유롭게 갈린다. 지상 지도가 무의미한 곳이라 숨긴다.
local HIDE_BELOW_Z = -15000.0

-- ── 설정 적용 ────────────────────────────────────────────────────────────────
-- 설정 원값(size/zoom/posX/posY) 로드는 config 모듈. 여기선 그 값을 기하(FRAME/HOLE_R/VIEW_WORLD·
-- 맵별 mapRender/viewFrac)로 변환해 렌더에 쓴다. 월드 진입(build)마다 재적용 → 메뉴 변경이 재접속 시 반영.
-- 크기=원(포트홀)만 바꾸고 내부 지도 스케일은 고정 → 작은 원 = 좁은 시야.
-- 줌=별도 px/월드 배율(줌↑ = 시야 좁아짐 = 확대). 아이콘 크기는 아래 MARK 계열 고정값(불변).
local BASE_FRAME  = 288        -- 기준 크기(이 스케일에서 px/월드가 기준값)
local BASE_VIEW_M = 400        -- 기준 시야 반경(m), 기준 크기·줌1 기준
local UNITS_PER_M = 100
-- ↓ config 로 결정되는 값들. 월드 진입(build)마다 applyConfig()로 재계산 → 메뉴에서 바꾼 값이
--   타이틀 나갔다 재접속하면 반영된다(부팅 시 1회 고정 아님). 아이콘 크기(MARK)는 여기 없음=불변.
local FRAME, ZOOM, POSX_FRAC, POSY_FRAC
local VIEW_M, VIEW_WORLD, HOLE_R
-- mapRender·viewFrac 는 스팬 의존이라 맵마다 다르다 → 각 MAPS 엔트리에 저장(applyConfig 에서 계산).

local function applyConfig()
    local ok, cfg = pcall(config.load)
    if not ok or not cfg then cfg = config.DEFAULT end
    FRAME     = cfg.size
    ZOOM      = cfg.zoom
    POSX_FRAC = math.max(0, math.min(100, cfg.posX)) / 100   -- 화면폭 대비(중앙 기준)
    POSY_FRAC = math.max(0, math.min(100, cfg.posY)) / 100   -- 화면높이 대비(중앙 기준)
    -- 시야 월드폭: 크기에 비례(px/월드 고정) → 줌으로 나눔(줌↑=시야 좁아짐). 맵 무관(실세계 m).
    VIEW_M     = BASE_VIEW_M * FRAME / (BASE_FRAME * ZOOM)
    VIEW_WORLD = VIEW_M * UNITS_PER_M
    HOLE_R     = math.floor(0.45 * FRAME)   -- 원형 반경 = 프레임의 0.45배(밖 마커 컬링, 크기 따라감)
    -- 맵별 렌더 스케일·머티리얼 줌: 같은 실세계 시야라도 스팬이 작은 맵(Tree)은 텍스처의 더 큰
    --   비율을 보여줘야 하므로 viewFrac 이 커진다. 마커 픽셀좌표(mpx/mpy)도 mapRender 기준.
    for _, m in ipairs(MAPS) do
        m.mapRender = math.floor(FRAME * m.spanX / VIEW_WORLD + 0.5)
        m.viewFrac  = VIEW_WORLD / m.spanX
    end
end

applyConfig()   -- 로드 시 1회(초기값 확보). 이후 월드 진입마다 재호출(configApplied 게이트).
local MARK      = 44            -- 플레이어 화살표 크기
local MARK_S    = 56            -- 마커 아이콘 기본 크기
-- 던전은 더 작게. 보스 3겹(월드맵식): boss=바깥 흰 테두리(가장 큼), bossDisc=검은 원반 배경,
--   bossFace=팰 얼굴. disc=face 로 두면 팰이 링 안쪽 끝까지 채워져 링과 팰 사이 검은 여백이 안 생긴다.
local MARK_SIZE = { dungeon = 22, obs = 56, boss = 40, bossDisc = 37, bossFace = 37, wanted = 46 }
local function markSize(kind) return MARK_SIZE[kind] or MARK_S end
local ARROW_PATH = "/Game/Mods/DekBasicMinimap_P/T_PositionArrow.T_PositionArrow"

-- 원형 프레임 오버레이: 우리가 직접 구운 커스텀 pak 텍스처(사각 지도 위에 얹어 원형 마스크+데코).
--   로드는 LoadAsset 아닌 AssetRegistryHelpers:GetAsset.
local FRAME_TEX_PATH = "/Game/Mods/MinimapFrame/T_MinimapFrame"
local FRAME_TEX_OBJ  = "/Game/Mods/MinimapFrame/T_MinimapFrame.T_MinimapFrame"
local FRAME_TEX_NAME = "T_MinimapFrame"
-- HOLE_R(원형 반경)은 applyConfig()에서 크기 따라 재계산된다(위).
local frameARH, frameAR = nil, nil
local gFrameOverlay = nil
local frameTexApplied = false

-- 지도 머티리얼(원형 클립): MID로 지도 텍스처 물리고 Center/ViewFrac로 패닝/줌.
local MAT_PATH = "/Game/Mods/MinimapFrame/M_MinimapMap"
local MAT_OBJ  = "/Game/Mods/MinimapFrame/M_MinimapMap.M_MinimapMap"
local MAT_NAME = "M_MinimapMap"
-- viewFrac(머티리얼 줌)은 맵별로 applyConfig()에서 재계산(위).
local gMID = nil
local appliedMapName = nil   -- 현재 MID 에 물린 맵 이름(바뀔 때만 MapTex/ViewFrac 스왑 → 매 틱 재설정 방지)

-- 종류별 색(FLinearColor). 워프=시안, 타워=빨강, 던전=자주, 여신상=노랑.
-- 색점은 "실아이콘 로드 전" 임시 표시. 아이콘이 로드되면 승격한다.
local COLOR = {
    warp   = { R = 0.15, G = 0.85, B = 1.0,  A = 1.0 },
    tower  = { R = 1.0,  G = 0.2,  B = 0.2,  A = 1.0 },
    dungeon= { R = 0.75, G = 0.3,  B = 1.0,  A = 1.0 },
    statue = { R = 1.0,  G = 0.9,  B = 0.25, A = 1.0 },
    base   = { R = 0.3,  G = 1.0,  B = 0.4,  A = 1.0 },
    -- 관측탑: 전용 아이콘 미확보 → 민트 색점(여신상과 동일 방식). 현상수배: 수배 아이콘 로드 전 폴백(주황).
    obs    = { R = 0.4,  G = 1.0,  B = 0.8,  A = 1.0 },
    wanted = { R = 1.0,  G = 0.5,  B = 0.0,  A = 1.0 },
}
-- 종류별 실제 인게임 POI 아이콘(나침반 POI 세트, 타입명 붙은 텍스처). 평범한 텍스처라 그대로 물림.
--   여신상은 전용 아이콘 미확보 → 색점 유지.
local ICON_PATH = {
    warp    = "/Game/Pal/Texture/UI/InGame/T_icon_compass_FTtower.T_icon_compass_FTtower",
    tower   = "/Game/Pal/Texture/UI/InGame/T_icon_compass_tower.T_icon_compass_tower",
    dungeon = "/Game/Pal/Texture/UI/InGame/T_icon_compass_dungeon.T_icon_compass_dungeon",
    -- 현상수배: 월드맵 수배 아이콘(실측). 색점(주황) → 아이콘으로 승격.
    wanted  = "/Game/Pal/Texture/UI/InGame/T_icon_compass_Bounty.T_icon_compass_Bounty",
    -- 관측탑(UnlockMapPoint=지도 밝히는 fast-travel 해금 지점): 전용 나침반 아이콘 FTUnlockMap(각진 cyan 새).
    --   일반 워프(FTtower=부드러운 새)와 다른 별도 텍스처 → IconProbe 로 로드된 텍스처 실측해 확정.
    obs     = "/Game/Pal/Texture/UI/InGame/T_icon_compass_FTUnlockMap.T_icon_compass_FTUnlockMap",
    -- base는 스트리밍이라 refreshDynamic()에서 동적 처리(ICON_PATH 대상 아님).
    -- 보스(필드팰보스)는 원 프레임+팰얼굴 2겹이라 buildBossMarkers/얼굴승격에서 별도 처리.
}
-- 아이콘 승격 시 틴트(기본 WHITE). 현재 모든 종류 원색 사용(관측탑도 원본 cyan 새 그대로).
local ICON_TINT = {}

-- ── 보스 마커(필드 팰 보스) 에셋 & 데이터 소스 ───────────────────────────────
-- 실측(docs/research/03): 월드맵 보스 마커 = 원 프레임 텍스처 위에 종별 팰 얼굴 아이콘 합성.
--   프레임(공용 1장) + 팰 얼굴(T_<종>_icon_normal). 위치·종은 게임 마스터 데이터테이블에서 읽는다.
local BOSSFRAME_PKG  = "/Game/Pal/Texture/UI/Map/T_prt_map_BossIconFrame"
local BOSSFRAME_OBJ  = "/Game/Pal/Texture/UI/Map/T_prt_map_BossIconFrame.T_prt_map_BossIconFrame"
local BOSSFRAME_NAME = "T_prt_map_BossIconFrame"
-- 어두운 원반 배경(팰 아이콘 뒤, 원형). 프레임(테두리)과 얼굴 사이 층.
--   ★원형 텍스처(pal_icon_base_s)는 반투명 → 여러 겹(BOSSDISC_LAYERS) 겹쳐 검정으로 불투명화.
--     (T_Circle01 은 사각을 꽉 채워 링 밖으로 검은 사각이 튀어나오므로 부적합 — 원형 유지 위해 이 텍스처 사용)
local BOSSDISC_PKG   = "/Game/Pal/Texture/UI/InGame/T_prt_pal_icon_base_s"
local BOSSDISC_OBJ   = "/Game/Pal/Texture/UI/InGame/T_prt_pal_icon_base_s.T_prt_pal_icon_base_s"
local BOSSDISC_NAME  = "T_prt_pal_icon_base_s"
local BOSSDISC_LAYERS = 3   -- 반투명 원을 3겹 겹쳐 사실상 불투명 검정 배경
-- 팰 얼굴 원형 마스크(게임 월드맵과 동일): 사각 팰 초상을 원으로 잘라주는 머티리얼.
--   얼굴 Image 에 이 머티리얼을 물리고, 종별 팰 텍스처를 파라미터로 주입하면 원 밖이 잘린다.
local PALMASK_PKG  = "/Game/Pal/Material/UI/Common/MI_SphereMaskedPalIcon"
local PALMASK_OBJ  = "/Game/Pal/Material/UI/Common/MI_SphereMaskedPalIcon.MI_SphereMaskedPalIcon"
local PALMASK_NAME = "MI_SphereMaskedPalIcon"
local palMaskMat, palMaskTried = nil, false
-- 팰 텍스처를 넣을 파라미터 이름: 프로브(MID 생성 후 후보 판별)로 "Texture" 확정.
local PALMASK_PARAM = "Texture"
local PALICON_DIR    = "/Game/Pal/Texture/PalIcon/Normal/"   -- + T_<종>_icon_normal

-- 보스 스포너 UI 데이터테이블(SSOT): 행 = SpawnerID / CharacterID(종) / Location / Level.
--   접근 API(전부 네이티브 CDO, 실측 확인): PalMasterDataTablesUtility + DataTableFunctionLibrary
--   + PalMasterDataTableAccess_BossSpawnerUIData:BP_FindRow. (근거: 03_marker-survey.md)
local CDO_DTUTIL = "/Script/Pal.Default__PalMasterDataTablesUtility"
local CDO_DTFL   = "/Script/Engine.Default__DataTableFunctionLibrary"
-- 플레이어 화살표: 게임 월드맵의 그 화살표(T_icon_map_player)로 교체(로드되면 승격).
local PLAYER_ICON = "/Game/Pal/Texture/UI/InGame/T_icon_map_player.T_icon_map_player"
local playerIconApplied = false
local iconTex = {}       -- kind -> 로드된 텍스처(캐시). 마커는 m.iconDone 으로 개별 승격.
local iconTry = {}       -- kind -> 로드 시도 횟수(상한까지만 재시도 → 못 여는 텍스처의 매프레임 강제로드 폭주 방지)
local ICON_TRY_MAX = 40  -- 스로틀(초당 1회) 기준 약 40초까지만 재시도 후 포기
local iconTick = 0
local WHITE = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
-- 보스 원반 순검정(불투명 solid 원을 검정으로 곱해 완전 검은 배경).
local BOSSDISC_TINT = { R = 0.0, G = 0.0, B = 0.0, A = 1.0 }

-- 우리 커스텀 pak 에셋 확보(이미 로드됐으면 찾고, 아니면 AssetRegistry GetAsset로 로드).
local function arGet(pkg, obj, name)
    local t = StaticFindObject(obj); if isv(t) then return t end
    if not (isv(frameARH) and isv(frameAR)) then
        frameARH = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
        if isv(frameARH) then pcall(function() frameAR = frameARH:GetAssetRegistry() end) end
    end
    if isv(frameARH) then
        local data = { PackageName = UEHelpers.FindOrAddFName(pkg), AssetName = UEHelpers.FindOrAddFName(name) }
        local ok, o = pcall(function() return frameARH:GetAsset(data) end)
        if ok and isv(o) then return o end
    end
    return nil
end
local function acquireFrameTex() return arGet(FRAME_TEX_PATH, FRAME_TEX_OBJ, FRAME_TEX_NAME) end

-- POI 아이콘 텍스처 확보(오브젝트경로 objPath 하나로). 로드돼 있으면 즉시, 아니면 강제 로드.
--   (기존엔 StaticFindObject 만 써서, 미로드 아이콘=수배 Bounty 등은 승격 못 하고 색 네모로 남았다.)
local function acquireIconTex(objPath)
    local t = StaticFindObject(objPath); if isv(t) then return t end
    local pkg = objPath:gsub("%.[^.]+$", "")       -- ".AssetName" 제거 → 패키지경로
    local name = pkg:match("([^/]+)$")             -- 마지막 세그먼트 = 에셋명
    if not name then return nil end
    return arGet(pkg, objPath, name)
end

-- 맵별 지도 텍스처 확보(1회 캐시). 텍스처는 그 맵에 서 있어야 로드되므로, 아직 없으면 nil 반환
-- → 호출부가 그동안 미니맵을 숨기고 다음 틱에 재시도한다. 캐시되면 즉시 반환(값싼 경로).
--
-- ⚠️ 게임스레드 보호: FindAllOf("Texture2D")+full() 은 로드된 텍스처(세계수 진입 시 7082개)를 통째로
--    훑어 무겁다. 이걸 매 틱(초당 30회) 돌리면 ExecuteInGameThread 가 게임 스레드를 마비시켜, 특히
--    "세계수 세이브로 로딩 진입" 처럼 스트리밍이 몰릴 때 로딩 자체가 안 끝나는 교착(화면 정지·소리만)이
--    생긴다. 그래서 캐시가 빈 동안엔 첫 시도(즉시) + 이후 SCAN_EVERY 틱마다만 스캔한다. 텍스처가 로드되면
--    캐시 히트로 곧장 빠져나가므로 스로틀은 "아직 못 찾은" 구간에만 걸린다(빈도만 낮출 뿐 반드시 찾는다).
local SCAN_EVERY = 12          -- ~30fps 기준 약 0.4초. 미니맵 등장은 눈에 안 띄게 늦고, 로딩 교착은 풀린다.
local texScanTick = 0
local function pickTexFor(m)
    if isv(m.tex) then return m.tex end
    -- 경로를 아는 맵(MAPS 에 objPath 지정)은 AssetRegistry 로 직접 확보한다: 로드돼 있으면 StaticFindObject
    --   로 즉시 찾고, 비상주면 GetAsset 이 강제 로드한다. 이래야 세계수 콜드스타트(T_TreeMap 비상주)에서도
    --   M 을 열지 않고 미니맵이 바로 뜬다. FindAllOf 전수스캔(7082개)도 피해 값싸다. 실패 시 아래 스캔 폴백.
    if m.objPath then
        local t = arGet(m.pkgPath, m.objPath, m.assetName)
        if isv(t) then m.tex = t; return t end
    end
    texScanTick = texScanTick + 1
    if texScanTick % SCAN_EVERY ~= 1 then return nil end   -- 첫 시도(==1) 즉시, 그 뒤엔 스로틀
    local list = nil; pcall(function() list = FindAllOf("Texture2D") end)
    if not list then return nil end
    for _, t in ipairs(list) do
        if isv(t) then
            if string.match(string.lower(full(t)), m.texMatch) then m.tex = t; return t end
        end
    end
    return nil
end

local mapImg, marker = nil, nil
local gWidget = nil         -- 루트 UserWidget 핸들(메뉴 열릴 때 통째로 숨기기용)
local markers = {}          -- { {slot, mpx, mpy, kind, img, sz, mapName}, ... }  (mpx/mpy = 소속 맵 mapRender 픽셀)
local built = false
local configApplied = false  -- 월드 진입 세션당 config 1회 재읽기 게이트(진입마다 최신값 반영)

-- 기지(팰박스)는 스트리밍 빌드오브젝트라 build 1회로 못 잡는다 → 주기적 재열거로 동적 추가.
local gTree, gFrame, gImgClass, gArrowTex = nil, nil, nil, nil
local baseSeen = {}    -- posKey -> true (이미 추가한 기지)
local BASE_ICON = "/Game/Pal/Texture/UI/InGame/T_icon_compass_camp.T_icon_compass_camp"

-- 보스 마커(필드 팰 보스): 마스터 데이터테이블을 1회 읽어 정적으로 생성. 스트리밍 아님.
local bossBuilt = false   -- 보스표 읽기·마커 생성 성공 게이트(월드 세션당 1회)

-- 마커 액터 열거 → 프레임 자식으로 아이콘 위젯 생성(색 틴트). 정적이라 1회만.
local function buildMarkers(tree, frame, ImgClass, arrowTex)
    local actors = nil; pcall(function() actors = FindAllOf("Actor") end)
    if not actors then return end
    for _, a in ipairs(actors) do
        if isv(a) then
            local cn = nil; pcall(function() cn = a:GetClass():GetFName():ToString() end)
            local kind = cn and classify(string.lower(cn)) or nil
            -- 기지(palbox)는 스트리밍 → refreshDynamic()가 동적 처리. 관측탑(obs)은 정적 상주라 여기서.
            --   필드보스·현상수배는 액터가 아니라 보스표에서 읽으므로 buildBossMarkers 소관(여기 없음).
            if kind == "base" then kind = nil end
            if kind then
                local x, y
                pcall(function() local L = a:K2_GetActorLocation(); x = L.X; y = L.Y end)
                local mm = x and mapAt(x, y) or nil   -- 소속 맵. 어느 맵에도 안 들면(nil) 마커 안 만듦.
                if mm then
                    local mk = StaticConstructObject(ImgClass, tree)
                    local slot = frame:AddChildToCanvas(mk)
                    local sz = markSize(kind)
                    slot:SetSize({ X = sz, Y = sz })
                    if isv(arrowTex) then mk:SetBrushFromTexture(arrowTex, false) end
                    pcall(function() mk:SetColorAndOpacity(COLOR[kind]) end)
                    local mpx, mpy = worldToPix(mm, x, y)   -- 그 맵의 픽셀좌표. 활성 맵일 때만 표시(루프).
                    markers[#markers + 1] = { slot = slot, mpx = mpx, mpy = mpy, kind = kind, img = mk, sz = sz, mapName = mm.name }
                end
            end
        end
    end
end

-- 미니맵 배치: 화면 X%/Y% 지점에 원의 "중앙"을 맞춘다.
--   앵커(SetAnchors) 방식은 이 포트에서 FAnchors 구조체 마샬링이 안 먹어 좌상단에 박힌다 →
--   뷰포트 픽셀 크기를 조회해 절대좌표로 배치한다(SetPosition). DPI 스케일 보정 포함.
local function getViewportWH(world)
    local WLL = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    if not isv(WLL) then return nil end
    local ctxs = { world, UEHelpers.GetPlayerController() }
    for _, ctx in ipairs(ctxs) do
        if isv(ctx) then
            local w, h, scale
            pcall(function() local sz = WLL:GetViewportSize(ctx); w = sz.X; h = sz.Y end)
            if w and h and w > 0 and h > 0 then
                pcall(function() scale = WLL:GetViewportScale(ctx) end)
                if not (scale and scale > 0) then scale = 1.0 end
                return w, h, scale
            end
        end
    end
    return nil
end

local function placeSlot(slot, x, y)
    pcall(function() slot:SetPosition({ X = x, Y = y }) end)
    pcall(function() slot:SetSize({ X = FRAME, Y = FRAME }) end)
end

-- build(world, bmap): bmap = 미니맵을 처음 만들 때 쓸 "부트스트랩 맵". 루프는 항상 MAPS[1](본섬,
--   T_WorldMap)을 넘긴다 — T_WorldMap 은 세계수에 서 있어도 늘 메모리에 상주하므로 어디서 시작하든
--   빌드가 성공한다. 세계수 텍스처(T_TreeMap)는 콜드스타트 땐 아직 비상주라 여기 의존하면 안 된다.
--   실제로 어느 맵을 보여줄지는 루프의 스왑 로직이 현재 맵 텍스처 로드 여부를 보고 결정한다.
local function build(world, bmap)
    local UWClass  = StaticFindObject("/Script/UMG.UserWidget")
    local ImgClass = StaticFindObject("/Script/UMG.Image")
    local CanClass = StaticFindObject("/Script/UMG.CanvasPanel")
    local WBPLib   = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not (isv(UWClass) and isv(ImgClass) and isv(CanClass) and isv(WBPLib)) then return false end
    if not bmap then return false end
    local tex = pickTexFor(bmap)
    if not isv(tex) then return false end
    local mat = arGet(MAT_PATH, MAT_OBJ, MAT_NAME)
    if not isv(mat) then return false end

    local uw = WBPLib:Create(world, UWClass, nil)
    if not isv(uw) then return false end
    local tree = uw.WidgetTree
    if not isv(tree) then return false end

    local root = StaticConstructObject(CanClass, tree)
    tree.RootWidget = root
    gTree, gImgClass = tree, ImgClass

    -- 화면 X%/Y% → 프레임 좌상단 절대좌표(원 중앙이 그 지점에 오도록). 뷰포트 크기 조회.
    local vw, vh, dpi = getViewportWH(world)
    local FX, FY
    if vw then
        FX = math.floor(vw * POSX_FRAC / dpi - FRAME / 2 + 0.5)
        FY = math.floor(vh * POSY_FRAC / dpi - FRAME / 2 + 0.5)
    else
        FX, FY = 24, 24
    end

    local frame = StaticConstructObject(CanClass, tree)
    local frameSlot = root:AddChildToCanvas(frame)
    placeSlot(frameSlot, FX, FY)
    frame.Clipping = 1

    local img = StaticConstructObject(ImgClass, tree)
    local imgSlot = frame:AddChildToCanvas(img)
    imgSlot:SetPosition({ X = 0, Y = 0 })
    imgSlot:SetSize({ X = FRAME, Y = FRAME })
    -- 지도 = 머티리얼 MID(원형 클립). MapTex/ViewFrac 세팅, Center(패닝)는 루프에서 매틱.
    local KML = StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    local mid = nil
    if isv(KML) then
        local ok, r = pcall(function()
            return KML:CreateDynamicMaterialInstance(world, mat, UEHelpers.FindOrAddFName("MID_MMap"), 0)
        end)
        if ok and isv(r) then mid = r end
    end
    if isv(mid) then
        gMID = mid
        appliedMapName = bmap.name
        pcall(function() mid:SetTextureParameterValue(UEHelpers.FindOrAddFName("MapTex"), tex) end)
        pcall(function() mid:SetScalarParameterValue(UEHelpers.FindOrAddFName("ViewFrac"), bmap.viewFrac) end)
        pcall(function() img:SetBrushFromMaterial(mid) end)
        pcall(function() img.Brush.DrawAs = 3 end)                      -- Image
        pcall(function() img.Brush.ImageSize = { X = FRAME, Y = FRAME } end)
    else
        img:SetBrushFromTexture(tex, false); imgSlot:SetSize({ X = bmap.mapRender, Y = bmap.mapRender })
    end

    local arrowTex = StaticFindObject(ARROW_PATH)
    gFrame, gArrowTex = frame, arrowTex   -- 기지 동적 추가용

    -- 마커 아이콘들(플레이어 화살표보다 먼저 자식으로 넣어 화살표가 위에 오게).
    buildMarkers(tree, frame, ImgClass, arrowTex)

    local mk = StaticConstructObject(ImgClass, tree)
    local mkSlot = frame:AddChildToCanvas(mk)
    mkSlot:SetSize({ X = MARK, Y = MARK })
    mkSlot:SetPosition({ X = FRAME / 2 - MARK / 2, Y = FRAME / 2 - MARK / 2 })
    pcall(function() mkSlot:SetZOrder(1000) end)   -- 항상 최상단(나중에 추가되는 기지 마커보다 위)
    if isv(arrowTex) then mk:SetBrushFromTexture(arrowTex, false) end
    pcall(function() mk:SetRenderTransformPivot({ X = 0.5, Y = 0.5 }) end)

    -- 원형 프레임 오버레이: root 자식(프레임 클리핑과 무관), 프레임 정확히 덮게 배치.
    --   프레임보다 위 ZOrder → 불투명 모서리가 사각 맵 모서리를 가려 원형으로 보임.
    --   텍스처는 아직 로드 전일 수 있어 숨겨두고, 루프에서 GetAsset 성공 시 승격.
    local ov = StaticConstructObject(ImgClass, tree)
    local ovSlot = root:AddChildToCanvas(ov)
    placeSlot(ovSlot, FX, FY)
    pcall(function() ovSlot:SetZOrder(500) end)
    pcall(function() ov:SetVisibility(1) end)   -- 승격 전 숨김(Collapsed)
    gFrameOverlay = ov

    -- ZOrder 음수 → 게임 UI(인벤토리·메뉴 등)보다 뒤에 깔린다. 평소엔 3D 위에 보이지만
    --   메뉴를 열면 그 패널 뒤로 숨어 덮지 않는다.
    uw:AddToViewport(-100)
    gWidget = uw
    mapImg = img
    marker = mk
    return true
end

-- FName/문자열 안전 변환(구조체 멤버 읽기용). 실패 시 nil.
local function fnameStr(v)
    local s
    if pcall(function() s = v:ToString() end) and type(s) == "string" then return s end
    return nil
end

-- 종명 → 팰 얼굴 텍스처(T_<종>_icon_normal). 정확 이름 실패 시 끝의 _속성(예:_Ice)을 떼고 재시도.
--   arGet 이 로드돼 있으면 즉시, 아니면 AssetRegistry 로 강제 로드.
local function palIconFor(species)
    if not species or species == "" then return nil end
    local tries = { species }
    local base = species:match("^(.+)_[A-Za-z]+$")   -- WhiteDeer_Dark → WhiteDeer, Horus_Water → Horus
    if base and base ~= species then tries[#tries + 1] = base end
    for _, sp in ipairs(tries) do
        local name = "T_" .. sp .. "_icon_normal"
        local t = arGet(PALICON_DIR .. name, PALICON_DIR .. name .. "." .. name, name)
        if isv(t) then return t end
    end
    return nil
end

-- UE4SS 배열(out-param 으로 채워진 Lua 테이블 또는 TArray) 순회 → fn(원소값).
local function iterArray(arr, fn)
    if type(arr) == "table" then for _, v in ipairs(arr) do fn(v) end; return end
    pcall(function()
        arr:ForEach(function(_, e)
            local g = e; pcall(function() local u = e:get(); if u ~= nil then g = u end end)
            fn(g)
        end)
    end)
end

-- 보스 마커 1회 생성: 마스터 데이터테이블(DT_BossSpawnerLoactionData)을 읽어
--   · 팰 보스(char=BOSS_<종>)   → 원 프레임 + 팰 얼굴(2겹)
--   · 인간 보스(char=None, 상인 제외) → 현상수배 마커(색점 → 수배 아이콘 승격)
--   위치·종이 표에 다 있어 액터 스캔/스트리밍 불필요. 표가 아직 미로드면 false 반환 → 다음에 재시도.
--   API 근거·행 구조는 파일 상단 상수 주석 + docs/research/03_marker-survey.md.

-- 원형 마스크 머티리얼 1회 로드. 팰 텍스처 주입 파라미터는 프로브로 "Texture"(PALMASK_PARAM) 확정.
local function ensurePalMask()
    if palMaskMat ~= nil or palMaskTried then return end
    palMaskTried = true
    local mat = arGet(PALMASK_PKG, PALMASK_OBJ, PALMASK_NAME)
    if isv(mat) then palMaskMat = mat end
end

local function buildBossMarkers(world)
    if not (isv(gFrame) and isv(gTree) and isv(gImgClass)) then return false end
    local util = StaticFindObject(CDO_DTUTIL)
    local dtfl = StaticFindObject(CDO_DTFL)
    if not (isv(util) and isv(dtfl)) then return false end
    local dt
    pcall(function() dt = util:GetBossSpawnerUIDataTable(world) end)
    if not isv(dt) then return false end
    local access
    pcall(function() access = util:GetBossSpawnerUIDataTableAccess(world) end)
    if not isv(access) then return false end
    -- 원 프레임 텍스처(공용 1장). 없으면 재시도(강제 로드 실패 시 다음 사이클).
    local frameTex = arGet(BOSSFRAME_PKG, BOSSFRAME_OBJ, BOSSFRAME_NAME)
    if not isv(frameTex) then return false end
    -- 어두운 원반(공용 1장, 반투명 원을 여러 겹). 없으면 원반 없이 진행(테두리+얼굴만).
    local discTex = arGet(BOSSDISC_PKG, BOSSDISC_OBJ, BOSSDISC_NAME)
    -- ★GetDataTableRowNames 는 반환값이 없고 out-param(OutRowNames)에만 채운다.
    --   → 넘긴 테이블을 읽어야 한다(반환값만 받으면 nil). 반환이 TArray 인 경우 대비해 폴백.
    local outTbl = {}
    local ret; pcall(function() ret = dtfl:GetDataTableRowNames(dt, outTbl) end)
    local names
    if type(outTbl) == "table" and #outTbl > 0 then names = outTbl
    elseif ret ~= nil then names = ret end
    if names == nil then return false end

    iterArray(names, function(rn)
        local key = rn; pcall(function() local u = rn:get(); if u ~= nil then key = u end end)
        local row; pcall(function() row = access:BP_FindRow(key, {}) end)
        if row == nil then return end
        local char, sid
        pcall(function() char = fnameStr(row.CharacterID) end)
        pcall(function() sid = fnameStr(row.SpawnerID) end)
        local x, y
        pcall(function() local L = row.Location; x = L.X; y = L.Y end)
        if not x then return end
        local mm = mapAt(x, y); if not mm then return end
        local mpx, mpy = worldToPix(mm, x, y)

        local isPal = char and char ~= "" and char ~= "None"
        if isPal then
            -- 팰 보스(월드맵과 동일 3겹): 어두운 원반(뒤) → 팰 얼굴(중) → 흰 테두리(앞).
            --   ZOrder 는 AddChildToCanvas 순서(나중 = 위)라 disc→face→ring 순으로 만든다.
            --   얼굴은 아래 '얼굴 승격'에서 종별 텍스처 로드. 로드 전엔 숨김(원반+테두리만 보임).
            local species = char:match("^BOSS_(.+)") or char
            -- (뒤) 어두운 원반: 반투명 원을 여러 겹 겹쳐 불투명 검정으로. 각 겹의 slot 을 discSlots 에 모은다.
            local dsz = markSize("bossDisc")
            local discSlots = {}
            if isv(discTex) then
                for _ = 1, BOSSDISC_LAYERS do
                    local disc = StaticConstructObject(gImgClass, gTree)
                    local dslot = gFrame:AddChildToCanvas(disc)
                    dslot:SetSize({ X = dsz, Y = dsz })
                    pcall(function() disc:SetBrushFromTexture(discTex, false) end)
                    pcall(function() disc:SetColorAndOpacity(BOSSDISC_TINT) end)
                    discSlots[#discSlots + 1] = { slot = dslot, img = disc }
                end
            end
            -- (중) 팰 얼굴
            local fsz = markSize("bossFace")
            local face = StaticConstructObject(gImgClass, gTree)
            local fslot = gFrame:AddChildToCanvas(face)
            fslot:SetSize({ X = fsz, Y = fsz })
            pcall(function() face:SetVisibility(1) end)   -- 얼굴 로드 전 숨김
            -- (앞) 흰 테두리 — 컬링·위치의 기준 레이어(m.slot)
            local rsz = markSize("boss")
            local ring = StaticConstructObject(gImgClass, gTree)
            local rslot = gFrame:AddChildToCanvas(ring)
            rslot:SetSize({ X = rsz, Y = rsz })
            pcall(function() ring:SetBrushFromTexture(frameTex, false) end)
            pcall(function() ring:SetColorAndOpacity(WHITE) end)
            markers[#markers + 1] = {
                slot = rslot, img = ring, sz = rsz, kind = "boss",
                slot2 = fslot, img2 = face, sz2 = fsz,
                discSlots = discSlots, discSz = dsz,
                species = species, faceApplied = false,
                mpx = mpx, mpy = mpy, mapName = mm.name,
            }
        else
            -- 인간 보스 = 현상수배. 상인(Trader)만 노이즈로 제외. 색점 → 수배 아이콘 승격(ICON_PATH).
            local lsid = sid and string.lower(sid) or ""
            if string.find(lsid, "trader", 1, true) then return end
            local sz = markSize("wanted")
            local mk = StaticConstructObject(gImgClass, gTree)
            local slot = gFrame:AddChildToCanvas(mk)
            slot:SetSize({ X = sz, Y = sz })
            if isv(gArrowTex) then pcall(function() mk:SetBrushFromTexture(gArrowTex, false) end) end
            pcall(function() mk:SetColorAndOpacity(COLOR.wanted) end)
            markers[#markers + 1] = { slot = slot, img = mk, sz = sz, kind = "wanted", mpx = mpx, mpy = mpy, mapName = mm.name }
        end
    end)
    return true
end

-- 동적 재열거: 스트리밍 빌드오브젝트(기지=palbox)만 훑어 새 위치면 마커 추가. 위젯 1개 원자 생성.
--   (관측탑=정적 buildMarkers, 필드보스·현상수배=정적 buildBossMarkers 소관이라 여기 없음)
local function refreshDynamic()
    if not isv(gFrame) then return end
    local actors = nil; pcall(function() actors = FindAllOf("Actor") end)
    if not actors then return end
    local baseTex = StaticFindObject(BASE_ICON)
    for _, a in ipairs(actors) do
        if isv(a) then
            local cn = nil; pcall(function() cn = a:GetClass():GetFName():ToString() end)
            local lname = cn and string.lower(cn) or nil
            if lname and string.find(lname, "palbox", 1, true) then
                local x, y; pcall(function() local L = a:K2_GetActorLocation(); x = L.X; y = L.Y end)
                local mm = x and mapAt(x, y) or nil
                if mm then
                    local k = posKey(x, y)
                    if not baseSeen[k] then
                        baseSeen[k] = true
                        local mk = StaticConstructObject(gImgClass, gTree)
                        local slot = gFrame:AddChildToCanvas(mk)
                        local sz = markSize("base")
                        slot:SetSize({ X = sz, Y = sz })
                        if isv(baseTex) then
                            mk:SetBrushFromTexture(baseTex, false)
                            pcall(function() mk:SetColorAndOpacity(WHITE) end)
                        elseif isv(gArrowTex) then
                            mk:SetBrushFromTexture(gArrowTex, false)
                            pcall(function() mk:SetColorAndOpacity(COLOR.base) end)
                        end
                        local mpx, mpy = worldToPix(mm, x, y)
                        markers[#markers + 1] = { slot = slot, mpx = mpx, mpy = mpy, kind = "base", img = mk, sz = sz, mapName = mm.name }
                    end
                end
            end
        end
    end
end

local function readPlayer()
    local pc = UEHelpers.GetPlayerController()
    if not isv(pc) then return nil end
    local pawn = nil
    pcall(function() pawn = pc.Pawn end)
    if not isv(pawn) then pcall(function() pawn = pc:K2_GetPawn() end) end
    if not isv(pawn) then return nil end
    local loc = nil; pcall(function() loc = pawn:K2_GetActorLocation() end)
    if not loc then return nil end
    local x, y, z; pcall(function() x = loc.X; y = loc.Y; z = loc.Z end)
    if not x then return nil end
    local yaw = 0.0
    pcall(function() local r = pawn:K2_GetActorRotation(); yaw = r.Yaw end)
    return x, y, yaw, z
end

-- 월드 재로드(타이틀→재접속) 시 이전 위젯은 월드와 함께 파괴된다. 남은 상태(built·마커·플래그)를
-- 전부 비워 다음 틱에서 깨끗이 재생성되게 한다. 모든 대상은 위 파일스코프 지역변수(업밸류)라 재대입됨.
local function resetState()
    built = false
    configApplied = false   -- 재접속 때 config 재읽기 게이트를 다시 연다(최신 설정 반영)
    mapImg, marker = nil, nil
    gWidget = nil
    markers = {}
    baseSeen = {}
    bossBuilt = false   -- 재접속 시 보스표 재읽기(마커 재생성)
    gTree, gFrame, gImgClass, gArrowTex = nil, nil, nil, nil
    gFrameOverlay = nil
    gMID = nil
    appliedMapName = nil
    for _, m in ipairs(MAPS) do m.tex = nil end   -- 월드 재로드로 텍스처 오브젝트가 갈릴 수 있어 캐시 비움
    frameARH, frameAR = nil, nil
    playerIconApplied = false
    frameTexApplied = false
    iconTex = {}
    iconTry = {}
    iconTick = 0
    palMaskMat, palMaskTried = nil, false
end

LoopAsync(33, function()   -- ~30fps: 지도 패닝/마커 부드럽게(버벅임 해소)
    pcall(function()
        ExecuteInGameThread(function()
            local world = UEHelpers.GetWorld()
            if not isv(world) then return end

            if not built then
                -- 월드 진입 세션당 1회 config 재읽기(메뉴에서 바꾼 값 반영). IterateGameDirectories가
                -- 무거우니 매 틱이 아니라 세션 시작에만. resetState()가 게이트를 다시 연다.
                if not configApplied then applyConfig(); configApplied = true end
                -- ★ 항상 상주하는 본섬 텍스처(MAPS[1]=T_WorldMap)로 부트스트랩 → 어디서 시작하든(세계수
                --   콜드스타트 포함) 빌드는 성공한다. 실제 표시 맵은 아래 스왑 루프가 담당: 현재 맵 텍스처가
                --   로드되면 그걸로 교체하고, 아직이면 숨김(hide) 유지 → 로드되는 즉시 표시.
                --   빌드 성공 전엔 플레이어 위치를 안 읽어 로딩 중 pc.Pawn GC 경고 소음도 없앤다.
                built = build(world, MAPS[1])
                return
            end
            -- 타이틀로 나갔다 재접속하면 위젯이 파괴돼 mapImg 가 죽는다 → 리셋 후 다음 틱에서 재생성.
            if not isv(mapImg) then
                resetState()
                return
            end

            -- 위젯 존재 확정 후 플레이어 위치/높이를 읽는다(패닝·숨김·표시맵 판정 공용). z로 지하 판별.
            local x, y, yaw, z = readPlayer()
            local inDungeon = (z ~= nil and z < HIDE_BELOW_Z)
            local am = mapAt(x, y)   -- 플레이어가 선 맵(멀티맵). 어느 맵에도 안 들면 nil.

            local amTex = am and pickTexFor(am) or nil

            -- 미니맵 통째 숨김 조건:
            --   (1) 메뉴 열림 — Palworld 메뉴 UI는 우리 뷰포트 위젯보다 상위 레이어라 ZOrder로 못 가린다 →
            --       커서 표시되면(bShowMouseCursor) 숨겨서 안 가리게 한다.
            --   (2) 던전/보스타워/보스탑 — 지상 지도가 무의미한 별도 지하 인스턴스(깊은 -Z)라 숨긴다.
            --   (3) 어느 맵에도 안 듦(am=nil) 또는 그 맵 텍스처 아직 미로드(amTex nil) — 그릴 지도가 없다.
            if isv(gWidget) then
                local pc = UEHelpers.GetPlayerController()
                local menuOpen = false
                pcall(function() menuOpen = (pc and pc.bShowMouseCursor == true) end)
                local hide = menuOpen or inDungeon or (am == nil) or not isv(amTex)
                pcall(function() gWidget:SetVisibility(hide and 1 or 0) end)  -- 1=Collapsed, 0=Visible
            end

            -- 현재 맵이 바뀌면 MID 지도 텍스처·줌을 그 맵 것으로 스왑(바뀔 때만 → 매 틱 재설정 방지).
            if am and isv(amTex) and isv(gMID) and am.name ~= appliedMapName then
                pcall(function() gMID:SetTextureParameterValue(UEHelpers.FindOrAddFName("MapTex"), amTex) end)
                pcall(function() gMID:SetScalarParameterValue(UEHelpers.FindOrAddFName("ViewFrac"), am.viewFrac) end)
                appliedMapName = am.name
            end

            -- 플레이어 화살표 승격: 맵 화살표 텍스처가 로드되면 교체(회전 유지).
            if not playerIconApplied and isv(marker) then
                local ptex = StaticFindObject(PLAYER_ICON)
                if isv(ptex) then
                    pcall(function() marker:SetBrushFromTexture(ptex, false) end)
                    pcall(function() marker:SetColorAndOpacity(WHITE) end)
                    playerIconApplied = true
                end
            end

            -- 원형 프레임 오버레이 텍스처 승격(우리 pak 로드되면 1회).
            if not frameTexApplied and isv(gFrameOverlay) then
                local ftex = acquireFrameTex()
                if isv(ftex) then
                    pcall(function() gFrameOverlay:SetBrushFromTexture(ftex, false) end)
                    pcall(function() gFrameOverlay:SetVisibility(0) end)   -- Visible
                    frameTexApplied = true
                end
            end

            -- 아이콘 승격: 종류별 텍스처를 1회 로드해 캐시(iconTex)에 담고,
            --   아직 승격 안 된 마커(m.iconDone 미설정)에 개별 적용한다.
            --   ★수배·보스 마커는 buildBossMarkers 로 '나중에' 생성되므로, 캐시+마커별 플래그라야
            --     늦게 태어난 마커도 색점→실아이콘으로 승격된다(과거: 1회성이라 영영 주황박스로 남음).
            --   ★강제 로드(acquireIconTex→GetAsset)는 무거워 매프레임 돌리면 렉 → 초당 1회로 스로틀,
            --     못 여는 텍스처는 상한(ICON_TRY_MAX)까지만 시도 후 포기(폭주 차단).
            iconTick = iconTick + 1
            if iconTick % 30 == 0 then
                for kind, path in pairs(ICON_PATH) do
                    if iconTex[kind] == nil and (iconTry[kind] or 0) < ICON_TRY_MAX then
                        iconTry[kind] = (iconTry[kind] or 0) + 1
                        local tex = acquireIconTex(path)
                        if isv(tex) then iconTex[kind] = tex end
                    end
                end
            end
            for i = 1, #markers do
                local m = markers[i]
                if not m.iconDone and m.kind and iconTex[m.kind] and isv(m.img) then
                    local tint = ICON_TINT[m.kind] or WHITE
                    pcall(function() m.img:SetBrushFromTexture(iconTex[m.kind], false) end)
                    pcall(function() m.img:SetColorAndOpacity(tint) end)
                    m.iconDone = true
                end
            end
            -- 보스 마커 1회 생성(마스터 데이터테이블). 표가 준비되면 성공, 아니면 다음 틱 재시도.
            if not bossBuilt then
                if buildBossMarkers(world) then bossBuilt = true end
            else
                -- 팰 얼굴 승격: 로드되는 대로 원 안에 얼굴을 채운다. 틱당 소수만 처리(히치 방지).
                local budget = 4
                for i = 1, #markers do
                    if budget <= 0 then break end
                    local m = markers[i]
                    if m.kind == "boss" and not m.faceApplied and m.species and isv(m.img2) then
                        local ftex = palIconFor(m.species)
                        if isv(ftex) then
                            -- 원형 마스크 머티리얼로 팰 얼굴을 원 안에 넣고 밖은 클리핑(월드맵 방식).
                            ensurePalMask()
                            local masked = false
                            if isv(palMaskMat) then
                                pcall(function()
                                    m.img2:SetBrushFromMaterial(palMaskMat)
                                    local mid = m.img2:GetDynamicMaterial()
                                    if isv(mid) then
                                        -- 확정 파라미터 "Texture"(PALMASK_PARAM)에 팰 텍스처 주입.
                                        pcall(function() mid:SetTextureParameterValue(UEHelpers.FindOrAddFName(PALMASK_PARAM), ftex) end)
                                        masked = true
                                    end
                                end)
                            end
                            if not masked then   -- 폴백: 마스크 실패 시 평범한 텍스처(원 밖 튀어나올 수 있음)
                                pcall(function() m.img2:SetBrushFromTexture(ftex, false) end)
                                pcall(function() m.img2:SetColorAndOpacity(WHITE) end)
                            end
                        end
                        m.faceApplied = true   -- 성공이든(원+얼굴) 실패든(원만) 매틱 재시도 방지
                        budget = budget - 1
                    end
                end
            end

            -- 기지 동적 재열거(약 3초마다): 스트리밍으로 로드되는 대로 base 마커 추가.
            baseTick = (baseTick or 0) + 1
            if baseTick % 90 == 0 then refreshDynamic() end   -- ~3초마다(30fps 기준)

            -- 활성 맵이 없으면(숨김 상태) 패닝·마커 갱신 스킵. worldToPix 는 am 필수라 여기서 가드.
            if not x or am == nil then return end
            local px, py = worldToPix(am, x, y)
            -- 지도 팬: 플레이어 픽셀이 프레임 중앙에 오도록.
            local tx, ty = FRAME / 2 - px, FRAME / 2 - py
            -- 지도 패닝: 머티리얼 Center를 플레이어 맵UV로(원형 클립 유지). 폴백이면 RenderTranslation.
            if isv(gMID) then
                local cu = (y - am.minY) / am.spanY + am.centerOff
                local cv = 1.0 - (x - am.minX) / am.spanX
                pcall(function() gMID:SetScalarParameterValue(UEHelpers.FindOrAddFName("CenterU"), cu) end)
                pcall(function() gMID:SetScalarParameterValue(UEHelpers.FindOrAddFName("CenterV"), cv) end)
            else
                pcall(function() mapImg:SetRenderTranslation({ X = tx, Y = ty }) end)
            end
            -- 마커: 활성 맵 소속만 표시(다른 맵 마커는 숨김). 지도와 동일 오프셋으로 재배치(밖은 클리핑).
            for i = 1, #markers do
                local m = markers[i]
                if isv(m.slot) then
                    if m.mapName ~= am.name then
                        if isv(m.img) then pcall(function() m.img:SetVisibility(1) end) end   -- 다른 맵 = 숨김
                        if isv(m.img2) then pcall(function() m.img2:SetVisibility(1) end) end
                        if m.discSlots then for _, d in ipairs(m.discSlots) do
                            if isv(d.img) then pcall(function() d.img:SetVisibility(1) end) end
                        end end
                    else
                        local hs = (m.sz or MARK_S) / 2
                        local sx = m.mpx + tx - hs
                        local sy = m.mpy + ty - hs
                        pcall(function() m.slot:SetPosition({ X = sx, Y = sy }) end)
                        -- 반경 컬링: 마커 중심이 원(HOLE_R) 밖이면 숨김 → 사각 모서리에 안 튀어나옴.
                        local dx = sx + hs - FRAME / 2
                        local dy = sy + hs - FRAME / 2
                        local inside = (dx * dx + dy * dy) <= (HOLE_R * HOLE_R)
                        if isv(m.img) then pcall(function() m.img:SetVisibility(inside and 0 or 1) end) end
                        -- 보스 원반(뒤, 여러 겹): 같은 중심에 얹기. 테두리와 함께 보임/숨김.
                        if m.discSlots then
                            local hsd = (m.discSz or hs * 2) / 2
                            local dx2, dy2 = m.mpx + tx - hsd, m.mpy + ty - hsd
                            for _, d in ipairs(m.discSlots) do
                                pcall(function() d.slot:SetPosition({ X = dx2, Y = dy2 }) end)
                                if isv(d.img) then pcall(function() d.img:SetVisibility(inside and 0 or 1) end) end
                            end
                        end
                        -- 보스 얼굴(중): 같은 중심에 작게 얹기. 얼굴 로드 전엔 숨김(원반+테두리만 보임).
                        if isv(m.slot2) then
                            local hs2 = (m.sz2 or hs * 2) / 2
                            pcall(function() m.slot2:SetPosition({ X = m.mpx + tx - hs2, Y = m.mpy + ty - hs2 }) end)
                            local showFace = inside and m.faceApplied
                            if isv(m.img2) then pcall(function() m.img2:SetVisibility(showFace and 0 or 1) end) end
                        end
                    end
                end
            end
            if isv(marker) then
                pcall(function() marker:SetRenderTransformAngle(yaw or 0) end)
            end
        end)
    end)
    return false
end)
