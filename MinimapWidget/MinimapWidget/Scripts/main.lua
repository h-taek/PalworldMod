-- MinimapWidget — 팔월드 macOS용 자체제작 미니맵.
-- 정적 전체지도를 원형으로 크롭해 화면 구석에 띄우고, 워프/타워/던전/여신상/기지 마커를 얹는다.
-- 마커는 맵 전역에 로드된 액터라 build 때 FindAllOf("Actor") 1회로 분류·좌표 캐시한다.
-- 크기·줌·위치는 ModConfigMenu 설정(modconfig.json)에서 읽어 월드 진입마다 적용한다.
--
-- 맵 경계: Min=(-1099400,-724400) Max=(349400,724400), 스팬 1,448,800(정사각).
--   변환(SWAP+세로뒤집기): u(가로)=(worldY-MinY)/스팬,  v(세로)=1-(worldX-MinX)/스팬.
--
-- 경계값 출처(1.0 에서 바뀜 → probe/MapBoundsProbe 로 실측, 2026-07-10, 게임 v1.0.2):
--   게임은 이 값을 DT_WorldMapUIData 행의 landScapeRealPositionMin/Max 로 들고 있는데,
--   런타임에 "읽을" 방법이 없다 — 값은 TMap(WorldMapDataMap) 안에만 있고 UE4SS_mac Lua 엔
--   TMap 바인딩이 없으며, 행을 반환하는 게터(GetCurrentPlayMapUIRowData 등)는 구조체를
--   값으로 반환해 콜백이 죽는다.
--   대신 UPalWorldMapUIData::GetMapNameByWorldLocation(FVector)->FName (스칼라 반환이라 호출 가능)
--   이 "그 좌표가 어느 맵 사각형에 드는가"를 판정한다는 점을 이용해, 반환이 'MainMap' 에서
--   'None' 으로 바뀌는 지점을 네 변마다 이분탐색해 측량했다. 즉 게임 자신의 포함 판정이 근거다.
--   측량 원값: X[-1099400.1, 349399.9] Y[-724399.8, 724399.9] (정밀도 ±0.5 → 정수로 반올림)
--   재측량이 필요하면 probe/MapBoundsProbe 를 mods.txt 에 넣고 인게임에서 M(월드맵) 한 번.
local UEHelpers = require("UEHelpers")

local MIN_X, MIN_Y = -1099400.0, -724400.0
local MAX_X, MAX_Y =   349400.0,  724400.0
local SPAN_X = MAX_X - MIN_X
local SPAN_Y = MAX_Y - MIN_Y

-- 플레이어를 원 중심에 맞추는 가로 미세 보정.
--   1.0 경계 갱신 후에도 그대로 둔다: 옛 경계도 게임의 landScapeRealPosition 계열 값이었는데
--   그때도 이 보정이 필요했으니, 경계 오차가 아니라 지도 텍스처 여백 같은 구조적 차이를
--   메우는 값으로 보인다. 정렬이 가로로 살짝 어긋나면 여기부터 의심할 것.
local CENTER_OFF_U = -0.0013

-- 특수지역(던전/보스타워/보스탑) 진입 시 미니맵 숨김 임계 높이.
--   실측: 지상 Z ≈ -2,000~+6,800 인데, 던전/탑은 입구 지하의 별도 인스턴스라 Z 가 뚝 떨어진다
--   (일반던전 ≈-26,900 · 테라리아던전 ≈-41,800 · 보스탑 ≈-64,900). 그 사이(-8k~-26k)는 데이터가
--   없어, -15000 을 경계로 삼으면 지상/특수지역이 여유롭게 갈린다. 지상 지도가 무의미한 곳이라 숨긴다.
local HIDE_BELOW_Z = -15000.0

-- ── 설정(ModConfigMenu 연동) ────────────────────────────────────────────────
-- 크기·줌·위치를 modconfig.json 에서 build 시점 1회 읽는다. 메뉴는 메인화면 전용이고
-- 미니맵은 인게임 로드라 둘이 동시에 존재하지 않는다 → 폴링·라이브콜백 불필요, 1회로 충분.
-- 쓰기가능 SSOT = 샌드박스 컨테이너(번들 파일은 읽기전용 심링크). 이식성 위해 컨테이너를 직접 읽는다.
local CFG_DEFAULT = { size = 288, zoom = 1.0, posX = 9, posY = 15 }

-- 최소 순수-Lua JSON 디코더(객체/배열/문자열/숫자/bool/null). 레포에 파서가 없어 동봉.
local function jsonDecode(s)
    local i = 1
    local parseValue
    local function skip()
        while i <= #s do local c = s:sub(i, i)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then i = i + 1 else break end end
    end
    local function parseString()
        i = i + 1; local buf = {}
        while i <= #s do
            local c = s:sub(i, i)
            if c == '"' then i = i + 1; return table.concat(buf) end
            if c == "\\" then
                local n = s:sub(i + 1, i + 1)
                local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
                              b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                if map[n] then buf[#buf + 1] = map[n]; i = i + 2
                elseif n == "u" then buf[#buf + 1] = "?"; i = i + 6
                else buf[#buf + 1] = n; i = i + 2 end
            else buf[#buf + 1] = c; i = i + 1 end
        end
        error("json: unterminated string")
    end
    local function parseNumber()
        local j = i
        while i <= #s and s:sub(i, i):match("[%-%+%d%.eE]") do i = i + 1 end
        return tonumber(s:sub(j, i - 1))
    end
    local function parseObject()
        i = i + 1; local o = {}; skip()
        if s:sub(i, i) == "}" then i = i + 1; return o end
        while true do
            skip(); local k = parseString(); skip(); i = i + 1   -- ':' 건너뜀
            skip(); o[k] = parseValue(); skip()
            local c = s:sub(i, i)
            if c == "," then i = i + 1 elseif c == "}" then i = i + 1; return o
            else error("json: expected , or }") end
        end
    end
    local function parseArray()
        i = i + 1; local a = {}; skip()
        if s:sub(i, i) == "]" then i = i + 1; return a end
        while true do
            skip(); a[#a + 1] = parseValue(); skip()
            local c = s:sub(i, i)
            if c == "," then i = i + 1 elseif c == "]" then i = i + 1; return a
            else error("json: expected , or ]") end
        end
    end
    parseValue = function()
        skip(); local c = s:sub(i, i)
        if c == "{" then return parseObject()
        elseif c == "[" then return parseArray()
        elseif c == '"' then return parseString()
        elseif c == "t" then i = i + 4; return true
        elseif c == "f" then i = i + 5; return false
        elseif c == "n" then i = i + 4; return nil
        else return parseNumber() end
    end
    return parseValue()
end

-- 자기 모드 폴더의 절대경로를 UE4SS 디렉토리 트리에서 얻는다 — 설치 위치·샌드박스 컨테이너
-- 구조를 하나도 하드코딩하지 않는다. 컨테이너로의 우회는 심링크가 처리하고, 모드는 그저
-- "내 폴더 옆 내 config"만 읽는다. IterateGameDirectories 계약(로드 시점 호출 안전).
local MOD_NAME = "MinimapWidget"
local CFG_FILE = "MinimapWidget.modconfig.json"

local function findOwnConfigPath()
    local ok, Dirs = pcall(IterateGameDirectories)
    if not ok or type(Dirs) ~= "table" then return nil end
    local game = Dirs.Game
    local bin  = type(game) == "table" and game.Binaries or nil
    local root = type(bin) == "table" and (bin.Win64 or bin.WinGDK) or nil
    if type(root) ~= "table" then return nil end
    local mods = (type(root.ue4ss) == "table" and root.ue4ss.Mods) or root.Mods
    if type(mods) ~= "table" then return nil end
    for _, folder in pairs(mods) do
        if type(folder) == "table" and folder.__name == MOD_NAME then
            if type(folder.__absolute_path) == "string" then
                return folder.__absolute_path .. "/" .. CFG_FILE
            end
            if type(folder.__files) == "table" then
                for _, file in pairs(folder.__files) do
                    if type(file) == "table" and type(file.__name) == "string"
                       and string.find(file.__name, "modconfig.json", 1, true) then
                        return file.__absolute_path
                    end
                end
            end
        end
    end
    return nil
end

local function readConfigAt(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local raw = f:read("*a"); f:close()
    local ok, cfg = pcall(jsonDecode, raw)
    local d = ok and cfg and cfg.Minimap and cfg.Minimap.data
    if not d then return nil end
    local function live(k, dv) local n = d[k]; if n and n.live ~= nil then return n.live end; return dv end
    return {
        size = live("Size",       CFG_DEFAULT.size),
        zoom = live("Zoom",       CFG_DEFAULT.zoom),
        posX = live("Position X", CFG_DEFAULT.posX),
        posY = live("Position Y", CFG_DEFAULT.posY),
    }
end

local function loadConfig()
    local path = findOwnConfigPath()
    if not path then return CFG_DEFAULT end
    local cfg = readConfigAt(path)
    if not cfg then return CFG_DEFAULT end
    return cfg
end

-- 크기=원(포트홀)만 바꾸고 내부 지도 스케일은 고정 → 작은 원 = 좁은 시야.
-- 줌=별도 px/월드 배율(줌↑ = 시야 좁아짐 = 확대). 아이콘 크기는 아래 MARK 계열 고정값(불변).
local BASE_FRAME  = 288        -- 기준 크기(이 스케일에서 px/월드가 기준값)
local BASE_VIEW_M = 400        -- 기준 시야 반경(m), 기준 크기·줌1 기준
local UNITS_PER_M = 100
-- ↓ config 로 결정되는 값들. 월드 진입(build)마다 applyConfig()로 재계산 → 메뉴에서 바꾼 값이
--   타이틀 나갔다 재접속하면 반영된다(부팅 시 1회 고정 아님). 아이콘 크기(MARK)는 여기 없음=불변.
local FRAME, ZOOM, POSX_FRAC, POSY_FRAC
local VIEW_M, VIEW_WORLD, MAP_RENDER, HOLE_R, VIEW_FRAC

local function applyConfig()
    local ok, cfg = pcall(loadConfig)
    if not ok or not cfg then cfg = CFG_DEFAULT end
    FRAME     = cfg.size
    ZOOM      = cfg.zoom
    POSX_FRAC = math.max(0, math.min(100, cfg.posX)) / 100   -- 화면폭 대비(중앙 기준)
    POSY_FRAC = math.max(0, math.min(100, cfg.posY)) / 100   -- 화면높이 대비(중앙 기준)
    -- 시야 월드폭: 크기에 비례(px/월드 고정) → 줌으로 나눔(줌↑=시야 좁아짐).
    VIEW_M     = BASE_VIEW_M * FRAME / (BASE_FRAME * ZOOM)
    VIEW_WORLD = VIEW_M * UNITS_PER_M
    MAP_RENDER = math.floor(FRAME * SPAN_X / VIEW_WORLD + 0.5)
    HOLE_R     = math.floor(0.45 * FRAME)   -- 원형 반경 = 프레임의 0.45배(밖 마커 컬링, 크기 따라감)
    VIEW_FRAC  = VIEW_WORLD / SPAN_X          -- 머티리얼 줌(표시 원=반경 VIEW_WORLD/2 월드)
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
-- VIEW_FRAC(머티리얼 줌)도 applyConfig()에서 재계산(위).
local gMID = nil

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
-- 클래스명(부분일치, 소문자) → 종류. 서로 겹치지 않는 특정 문자열로 매칭.
local function classify(lname)
    if string.find(lname, "towerfasttravelpoint", 1, true) then return "warp" end
    if string.find(lname, "palbosstower",         1, true) then return "tower" end
    if string.find(lname, "dungeonportalmarker",  1, true) then return "dungeon" end
    if string.find(lname, "dungeonfixedentrance", 1, true) then return "dungeon" end
    if string.find(lname, "goddessstatue",        1, true) then return "statue" end
    if string.find(lname, "palbox",               1, true) then return "base" end
    return nil
end

local function isv(o) local ok, r = pcall(function() return o and o:IsValid() end); return ok and r == true end
local function full(o) local f = "<?>"; pcall(function() f = o:GetFullName() end); return f end

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

local function pickMapTexture()
    local best = nil
    local list = nil; pcall(function() list = FindAllOf("Texture2D") end)
    if not list then return nil end
    for _, t in ipairs(list) do
        if isv(t) then
            local fn = string.lower(full(t))
            if string.match(fn, "%.t_worldmap$") then return t end
            if best == nil and string.match(fn, "t_mainworld5_combined") then best = t end
        end
    end
    return best
end

local mapImg, marker = nil, nil
local gWidget = nil         -- 루트 UserWidget 핸들(메뉴 열릴 때 통째로 숨기기용)
local markers = {}          -- { {w=Image, mpx=, mpy=}, ... }  (mpx/mpy = MAP_RENDER 픽셀좌표)
local built = false
local configApplied = false  -- 월드 진입 세션당 config 1회 재읽기 게이트(진입마다 최신값 반영)

-- 기지(팰박스)는 스트리밍 빌드오브젝트라 build 1회로 못 잡는다 → 주기적 재열거로 동적 추가.
local gTree, gFrame, gImgClass, gArrowTex = nil, nil, nil, nil
local baseSeen = {}    -- posKey -> true (이미 추가한 기지)
local BASE_ICON = "/Game/Pal/Texture/UI/InGame/T_icon_compass_camp.T_icon_compass_camp"
local function posKey(x, y) return math.floor(x / 800) .. "_" .. math.floor(y / 800) end

local function worldToPix(x, y)
    local u =       (y - MIN_Y) / SPAN_Y
    local v = 1.0 - (x - MIN_X) / SPAN_X
    return u * MAP_RENDER, v * MAP_RENDER
end

-- 1.0 의 신규 지역(월드트리 일대, X 477k~630k)은 MainMap 사각형 밖이라 T_WorldMap 에 안 그려져
-- 있다(측량으로 확인: X>349400 이면 GetMapNameByWorldLocation 이 'None'). 그 좌표를 worldToPix 에
-- 넣으면 지도 밖 픽셀이 나오므로, 마커는 아예 만들지 않고 플레이어가 거기 있으면 미니맵을 숨긴다.
local function inBounds(x, y)
    return x >= MIN_X and x <= MAX_X and y >= MIN_Y and y <= MAX_Y
end

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
                if x and inBounds(x, y) then
                    local mk = StaticConstructObject(ImgClass, tree)
                    local slot = frame:AddChildToCanvas(mk)
                    local sz = markSize(kind)
                    slot:SetSize({ X = sz, Y = sz })
                    if isv(arrowTex) then mk:SetBrushFromTexture(arrowTex, false) end
                    pcall(function() mk:SetColorAndOpacity(COLOR[kind]) end)
                    local mpx, mpy = worldToPix(x, y)
                    markers[#markers + 1] = { slot = slot, mpx = mpx, mpy = mpy, kind = kind, img = mk, sz = sz }
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

local function build(world)
    local UWClass  = StaticFindObject("/Script/UMG.UserWidget")
    local ImgClass = StaticFindObject("/Script/UMG.Image")
    local CanClass = StaticFindObject("/Script/UMG.CanvasPanel")
    local WBPLib   = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not (isv(UWClass) and isv(ImgClass) and isv(CanClass) and isv(WBPLib)) then return false end
    local tex = pickMapTexture()
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
        pcall(function() mid:SetTextureParameterValue(UEHelpers.FindOrAddFName("MapTex"), tex) end)
        pcall(function() mid:SetScalarParameterValue(UEHelpers.FindOrAddFName("ViewFrac"), VIEW_FRAC) end)
        pcall(function() img:SetBrushFromMaterial(mid) end)
        pcall(function() img.Brush.DrawAs = 3 end)                      -- Image
        pcall(function() img.Brush.ImageSize = { X = FRAME, Y = FRAME } end)
    else
        img:SetBrushFromTexture(tex, false); imgSlot:SetSize({ X = MAP_RENDER, Y = MAP_RENDER })
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
                if x and inBounds(x, y) then
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
                        local mpx, mpy = worldToPix(x, y)
                        markers[#markers + 1] = { slot = slot, mpx = mpx, mpy = mpy, kind = "base", img = mk, sz = sz }
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
                built = build(world); return
            end
            -- 타이틀로 나갔다 재접속하면 위젯이 파괴돼 mapImg 가 죽는다 → 리셋 후 다음 틱에서 재생성.
            if not isv(mapImg) then
                resetState()
                return
            end

            -- 플레이어 위치/높이 1회 읽기(패닝·숨김판정 공용). z 로 던전/보스탑 지하 인스턴스 판별.
            local x, y, yaw, z = readPlayer()
            local inDungeon = (z ~= nil and z < HIDE_BELOW_Z)
            -- MainMap 사각형 밖(1.0 신규 지역 등) = 우리 지도 텍스처가 안 덮는 곳.
            local offMap = (x ~= nil and not inBounds(x, y))

            -- 미니맵 통째 숨김 조건 두 가지:
            --   (1) 메뉴 열림 — Palworld 메뉴 UI는 우리 뷰포트 위젯보다 상위 레이어라 ZOrder로 못 가린다 →
            --       커서 표시되면(bShowMouseCursor) 숨겨서 안 가리게 한다.
            --   (2) 던전/보스타워/보스탑 — 지상 지도가 무의미한 별도 지하 인스턴스(깊은 -Z)라 숨긴다.
            --   (3) MainMap 밖 — 1.0 신규 지역. 지도 텍스처가 안 덮어 UV 가 [0,1] 을 벗어난다.
            if isv(gWidget) then
                local pc = UEHelpers.GetPlayerController()
                local menuOpen = false
                pcall(function() menuOpen = (pc and pc.bShowMouseCursor == true) end)
                local hide = menuOpen or inDungeon or offMap
                pcall(function() gWidget:SetVisibility(hide and 1 or 0) end)  -- 1=Collapsed, 0=Visible
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

            if not x then return end
            local px, py = worldToPix(x, y)
            -- 지도 팬: 플레이어 픽셀이 프레임 중앙에 오도록.
            local tx, ty = FRAME / 2 - px, FRAME / 2 - py
            -- 지도 패닝: 머티리얼 Center를 플레이어 맵UV로(원형 클립 유지). 폴백이면 RenderTranslation.
            if isv(gMID) then
                local cu = (y - MIN_Y) / SPAN_Y + CENTER_OFF_U
                local cv = 1.0 - (x - MIN_X) / SPAN_X
                pcall(function() gMID:SetScalarParameterValue(UEHelpers.FindOrAddFName("CenterU"), cu) end)
                pcall(function() gMID:SetScalarParameterValue(UEHelpers.FindOrAddFName("CenterV"), cv) end)
            else
                pcall(function() mapImg:SetRenderTranslation({ X = tx, Y = ty }) end)
            end
            -- 마커: 지도와 동일 오프셋으로 재배치(프레임 밖은 클리핑).
            for i = 1, #markers do
                local m = markers[i]
                if isv(m.slot) then
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
            if isv(marker) then
                pcall(function() marker:SetRenderTransformAngle(yaw or 0) end)
            end
        end)
    end)
    return false
end)
