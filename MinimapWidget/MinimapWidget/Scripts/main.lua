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
local MARK_SIZE = { dungeon = 22 }   -- 던전은 더 작게
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
}
-- 종류별 실제 인게임 POI 아이콘(나침반 POI 세트, 타입명 붙은 텍스처). 평범한 텍스처라 그대로 물림.
--   여신상은 전용 아이콘 미확보 → 색점 유지.
local ICON_PATH = {
    warp    = "/Game/Pal/Texture/UI/InGame/T_icon_compass_FTtower.T_icon_compass_FTtower",
    tower   = "/Game/Pal/Texture/UI/InGame/T_icon_compass_tower.T_icon_compass_tower",
    dungeon = "/Game/Pal/Texture/UI/InGame/T_icon_compass_dungeon.T_icon_compass_dungeon",
    -- base는 스트리밍이라 아래 refreshBases()에서 동적 처리(ICON_PATH 대상 아님).
}
-- 플레이어 화살표: 게임 월드맵의 그 화살표(T_icon_map_player)로 교체(로드되면 승격).
local PLAYER_ICON = "/Game/Pal/Texture/UI/InGame/T_icon_map_player.T_icon_map_player"
local playerIconApplied = false
local iconApplied = {}   -- kind -> true (아이콘 승격 완료)
local WHITE = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }

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

-- 마커 액터 열거 → 프레임 자식으로 아이콘 위젯 생성(색 틴트). 정적이라 1회만.
local function buildMarkers(tree, frame, ImgClass, arrowTex)
    local actors = nil; pcall(function() actors = FindAllOf("Actor") end)
    if not actors then return end
    for _, a in ipairs(actors) do
        if isv(a) then
            local cn = nil; pcall(function() cn = a:GetClass():GetFName():ToString() end)
            local kind = cn and classify(string.lower(cn)) or nil
            if kind == "base" then kind = nil end   -- 기지는 refreshBases()가 동적 처리
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

-- 기지(팰박스) 동적 재열거: 로드된 팰박스를 훑어 새 위치면 base 마커 추가(위젯 1개 원자 생성).
local function refreshBases()
    if not isv(gFrame) then return end
    local actors = nil; pcall(function() actors = FindAllOf("Actor") end)
    if not actors then return end
    local baseTex = StaticFindObject(BASE_ICON)
    for _, a in ipairs(actors) do
        if isv(a) then
            local cn = nil; pcall(function() cn = a:GetClass():GetFName():ToString() end)
            if cn and string.find(string.lower(cn), "palbox", 1, true) then
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
    gTree, gFrame, gImgClass, gArrowTex = nil, nil, nil, nil
    gFrameOverlay = nil
    gMID = nil
    appliedMapName = nil
    for _, m in ipairs(MAPS) do m.tex = nil end   -- 월드 재로드로 텍스처 오브젝트가 갈릴 수 있어 캐시 비움
    frameARH, frameAR = nil, nil
    playerIconApplied = false
    frameTexApplied = false
    iconApplied = {}
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

            -- 아이콘 승격: 실아이콘 텍스처가 로드되면 색점 → 실아이콘으로 교체(종류별 1회).
            for kind, path in pairs(ICON_PATH) do
                if not iconApplied[kind] then
                    local tex = StaticFindObject(path)
                    if isv(tex) then
                        for i = 1, #markers do
                            local m = markers[i]
                            if m.kind == kind and isv(m.img) then
                                pcall(function() m.img:SetBrushFromTexture(tex, false) end)
                                pcall(function() m.img:SetColorAndOpacity(WHITE) end)
                            end
                        end
                        iconApplied[kind] = true
                    end
                end
            end
            -- 기지 동적 재열거(약 3초마다): 스트리밍으로 로드되는 대로 base 마커 추가.
            baseTick = (baseTick or 0) + 1
            if baseTick % 90 == 0 then refreshBases() end   -- ~3초마다(30fps 기준)

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
