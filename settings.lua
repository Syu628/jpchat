local api = require("api")

-- ============================================================================
-- デフォルト色設定（チャンネルキー → {r, g, b, a}）
-- ============================================================================

local DEFAULTS = {
    Say        = {1.00, 1.00, 1.00, 1.00},  -- 白
    Zone       = {1.00, 0.60, 0.80, 1.00},  -- ピンク
    Trade      = {1.00, 0.80, 0.50, 1.00},  -- オレンジ
    Party      = {0.35, 0.75, 0.42, 1.00},  -- 緑
    Raid       = {1.00, 0.50, 0.20, 1.00},  -- オレンジ
    Nation     = {0.56, 0.70, 0.20, 1.00},  -- 黄緑
    Guild      = {0.40, 0.65, 1.00, 1.00},  -- 青
    Family     = {0.12, 0.65, 0.28, 1.00},  -- 深緑
    Faction    = {1.00, 0.90, 0.40, 1.00},  -- 黄
    RaidLeader = {1.00, 0.40, 0.00, 1.00},  -- オレンジ赤
    Trial      = {1.00, 0.20, 0.40, 1.00},  -- 赤紫
    Whisper    = {1.00, 0.35, 0.95, 1.00},  -- マゼンタ
}

local SAVE_PATH       = "jpchat/jpchat_settings.lua"
local ADDON_ID        = "jpchat"
local DEFAULT_OPACITY = 0.92   -- ウィンドウ背景の不透明度デフォルト値（0.1〜1.0）
local DEFAULT_FONTSIZE = 13    -- デフォルトフォントサイズ（FONT_SIZE.MIDDLE = 13）
local DEFAULT_RAID_X   = 0     -- RaidLeaderオーバーレイのXオフセット（TOP基準）
local DEFAULT_RAID_Y   = 80    -- RaidLeaderオーバーレイのYオフセット（TOP基準）

-- 実行時テーブル（デフォルトをコピーして使う）
local colors   = {}
local opacity  = DEFAULT_OPACITY
local fontSize = DEFAULT_FONTSIZE
local visible  = {}  -- チャンネルキー → bool（true=表示、false=非表示）
local winPos   = nil -- ウィンドウ位置・サイズ { x, y, w, h } （nil = デフォルト位置）
local raidX    = DEFAULT_RAID_X  -- RaidLeaderオーバーレイXオフセット
local raidY    = DEFAULT_RAID_Y  -- RaidLeaderオーバーレイYオフセット
npcList = {
--ルル
["Auctioneer"] = true,
["kim"] = true,
--ガード
["Guard"] = true,
["Sentry"] = true,
--ヌイ
["Teemple Priestess"] = true,
--家具の雑貨商
["Hotal"] = true,
--コミュニティセンター
["Community Center Manager Dumo"] = true,    --Lylyut
["Community Center Manager Olivian"] = true, --karksa
}
for k, v in pairs(DEFAULTS) do
    colors[k]  = { v[1], v[2], v[3], v[4] }
    visible[k] = true  -- デフォルトはすべて表示
end

-- ============================================================================
-- 保存 / 読み込み
-- ============================================================================

local M = {}

function M.Save()
    api.File:Write(SAVE_PATH, { colors = colors, opacity = opacity, visible = visible, winPos = winPos, fontSize = fontSize, npcList = npcList, raidX = raidX, raidY = raidY })
end

function M.Load()
    local data = api.File:Read(SAVE_PATH)
    if type(data) ~= "table" then return end
    if type(data.colors) == "table" then
        for k, v in pairs(data.colors) do
            if type(v) == "table" and #v >= 4 then
                colors[k] = { v[1], v[2], v[3], v[4] }
            end
        end
    end
    if type(data.opacity) == "number" then
        opacity = math.max(0.1, math.min(1.0, data.opacity))
    end
    -- visible は bool なので明示的に true/false を確認する
    if type(data.visible) == "table" then
        for k, v in pairs(data.visible) do
            if visible[k] ~= nil then  -- 既知のチャンネルキーのみ受け入れる
                visible[k] = (v == true)
            end
        end
    end
    -- ウィンドウ位置・サイズ
    if type(data.winPos) == "table" then
        winPos = {
            x = tonumber(data.winPos.x),
            y = tonumber(data.winPos.y),
            w = tonumber(data.winPos.w),
            h = tonumber(data.winPos.h),
        }
    end
    -- フォントサイズ
    if type(data.fontSize) == "number" then
        fontSize = data.fontSize
    end
    -- NPC名リスト
    if type(data.npcList) == "table" then
        for k, v in pairs(data.npcList) do
            if v == true then
                npcList[k] = true
            end
        end
    end
    -- RaidLeaderオーバーレイ位置
    if type(data.raidX) == "number" then raidX = data.raidX end
    if type(data.raidY) == "number" then raidY = data.raidY end
end

-- ============================================================================
-- 色の取得 / 設定
-- ============================================================================

function M.GetColor(key)
    return colors[key] or DEFAULTS[key] or {1, 1, 1, 1}
end

function M.SetColor(key, r, g, b, a)
    colors[key] = { r, g, b, a or 1 }
end

function M.Reset(key)
    if DEFAULTS[key] then
        local d = DEFAULTS[key]
        colors[key] = { d[1], d[2], d[3], d[4] }
    end
end

function M.GetAllKeys()
    return { "Say", "Zone", "Trade", "Party", "Raid", "Nation", "Guild", "Family", "Faction", "RaidLeader", "Trial", "Whisper" }
end

function M.GetDefaults()
    return DEFAULTS
end

-- ============================================================================
-- 透過率の取得 / 設定
-- ============================================================================

function M.GetOpacity()
    return opacity
end

function M.SetOpacity(a)
    opacity = math.max(0.1, math.min(1.0, a))
end

function M.GetDefaultOpacity()
    return DEFAULT_OPACITY
end

-- ============================================================================
-- チャンネル表示フラグの取得 / 設定
-- ============================================================================

-- true = 表示、false = 非表示。未登録キーは true（表示）扱い
function M.GetVisible(key)
    if visible[key] == nil then return true end
    return visible[key]
end

function M.SetVisible(key, flag)
    visible[key] = (flag == true)
end

-- ============================================================================
-- ウィンドウ位置・サイズの取得 / 設定
-- ============================================================================

-- 戻り値: { x, y, w, h } or nil（未保存時）
function M.GetWinPos()
    return winPos
end

function M.SetWinPos(x, y, w, h)
    winPos = { x = x, y = y, w = w, h = h }
end

-- ============================================================================
-- RaidLeaderオーバーレイ位置の取得 / 設定
-- ============================================================================

function M.GetRaidPos()
    return raidX, raidY
end

function M.SetRaidPos(x, y)
    raidX = tonumber(x) or DEFAULT_RAID_X
    raidY = tonumber(y) or DEFAULT_RAID_Y
end

function M.GetDefaultRaidPos()
    return DEFAULT_RAID_X, DEFAULT_RAID_Y
end

-- ============================================================================
-- フォントサイズの取得 / 設定
-- ============================================================================

function M.GetFontSize()
    return fontSize
end

function M.SetFontSize(size)
    fontSize = size
end

function M.GetDefaultFontSize()
    return DEFAULT_FONTSIZE
end

-- ============================================================================
-- NPC名リストの取得 / 追加 / 判定
-- ============================================================================

function M.IsNpc(name)
    return npcList[name] == true
end

function M.AddNpc(name)
    npcList[name] = true
end

function M.RemoveNpc(name)
    npcList[name] = nil
end

function M.GetNpcList()
    return npcList
end

return M
