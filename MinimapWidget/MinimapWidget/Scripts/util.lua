-- util.lua — 순수 헬퍼(상태 없음). main 이 require("util") 로 쓴다.
--   isv/full 은 UE 오브젝트 안전접근, classify 는 마커 분류, posKey 는 기지 중복제거 키.

-- 오브젝트가 살아있는지(IsValid) 안전 확인. GC/무효 핸들이면 false.
local function isv(o) local ok, r = pcall(function() return o and o:IsValid() end); return ok and r == true end

-- 오브젝트 풀네임(안전). 실패 시 "<?>".
local function full(o) local f = "<?>"; pcall(function() f = o:GetFullName() end); return f end

-- 클래스명(부분일치, 소문자) → 마커 종류. 서로 겹치지 않는 특정 문자열로 매칭. 없으면 nil.
local function classify(lname)
    if string.find(lname, "towerfasttravelpoint", 1, true) then return "warp" end
    if string.find(lname, "palbosstower",         1, true) then return "tower" end
    if string.find(lname, "dungeonportalmarker",  1, true) then return "dungeon" end
    if string.find(lname, "dungeonfixedentrance", 1, true) then return "dungeon" end
    if string.find(lname, "goddessstatue",        1, true) then return "statue" end
    if string.find(lname, "palbox",               1, true) then return "base" end
    -- 관측탑: 정적 상주(맵 전역 x22) 액터라 buildMarkers 1회 스캔으로 잡는다.
    --   (필드보스·현상수배는 액터가 아니라 마스터 데이터테이블 DT_BossSpawnerLoactionData 에서
    --    위치+종을 읽어 main 의 buildBossMarkers 가 그린다 — 여기 classify 대상 아님.
    --    근거: docs/research/03_marker-survey.md)
    if string.find(lname, "unlockmappoint",        1, true) then return "obs" end
    return nil
end

-- 기지 위치 중복제거 키: 월드좌표를 8m 격자 셀로 양자화(같은 셀 = 같은 기지로 간주).
local function posKey(x, y) return math.floor(x / 800) .. "_" .. math.floor(y / 800) end

return { isv = isv, full = full, classify = classify, posKey = posKey }
