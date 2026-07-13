-- config.lua — 설정(ModConfigMenu 연동) 로드. main 이 require("config") 로 쓴다.
-- 크기·줌·위치를 modconfig.json 에서 읽어 { size, zoom, posX, posY } 로 돌려준다(load()).
--   값 → 기하(FRAME/HOLE_R/VIEW_WORLD…) 변환은 main 의 applyConfig 담당(여기선 원값만).
-- 메뉴는 메인화면 전용이고 미니맵은 인게임 로드라 둘이 동시에 존재하지 않는다 → 폴링·라이브콜백 불필요.
-- 쓰기가능 SSOT = 샌드박스 컨테이너(번들 파일은 읽기전용 심링크). 이식성 위해 컨테이너를 직접 읽는다.
local CFG_DEFAULT = { size = 288, zoom = 1.0, posX = 9, posY = 15 }
local MOD_NAME = "MinimapWidget"
local CFG_FILE = "MinimapWidget.modconfig.json"

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

return { load = loadConfig, DEFAULT = CFG_DEFAULT }
