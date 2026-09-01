local api          = require("api")
local ui           = require("jpchat/ui")
local settings     = require("jpchat/settings")
local settingsPage = require("jpchat/settings_page")

local jpchat_addon = {
    name    = "jpchat",
    author  = "Syu",
    version = "1.1.0",
    desc    = "Chat translation addon. Displays Japanese translations in a window.",
}

-- ============================================================================
-- 設定
-- ============================================================================

local INPUT_FILE       = "jpchat/input.lua"
local OUTPUT_FILE      = "jpchat/output.lua"
local SEND_INPUT_FILE  = "jpchat/send_input.lua"
local SEND_OUTPUT_FILE = "jpchat/send_output.lua"
local HEARTBEAT_FILE   = "jpchat/heartbeat.lua"
local POLL_INTERVAL    = 100  -- ミリ秒

-- CHAT_MESSAGE の arg展開: channel, unit, isHostile, name, message
local CHANNEL_LABEL = {
    [0]  = "Say",
    [1]  = "Zone",
    [2]  = "Trade",
    [3]  = "Party",     -- パーティー（自分から送る）
    [4]  = "Party",     -- パーティー（相手から）
    [5]  = "Raid",
    [6]  = "Nation",
    [7]  = "Guild",
    [9]  = "Family",
    [10] = "RaidLeader",
    [11] = "Trial",
    [14] = "Faction",
    [-3] = "Whisper",      -- ささやき（相手から）
    [-4] = "WhisperTo",   -- ささやき（自分から送る）
}

-- ============================================================================
-- 内部状態
-- ============================================================================

local cantReadWindow = nil
local clockTimer     = 0
local lastOutput     = ""
local pendingItems   = {}  -- 翻訳待ちアイテム情報キュー
local lastSender     = ""  -- 重複チェック用
local lastMessage    = ""  -- 重複チェック用

-- 翻訳エンジン状態管理
local MODE_IDLE      = 0
local MODE_TRANSLATE = 1
local engineMode     = MODE_IDLE
local waitingResponse = false  -- input.lua 書き込み後、応答待ち中か
local noResponseTime = 0      -- 応答待ち開始からの経過時間(ms)
local NO_RESPONSE_TIMEOUT = 3000  -- 3秒間応答なしでIDLEに戻る
local hbCheckTimer   = 0   -- ハートビート確認用タイマー
local HB_CHECK_INTERVAL = 5000  -- 5秒ごとにハートビート確認

-- ============================================================================
-- 日本語判定
-- ============================================================================
-- UTF-8 でひらがな・カタカナが含まれるかチェック
-- ひらがな: U+3040-U+309F → UTF-8: E3 81 80 - E3 82 9F
-- カタカナ: U+30A0-U+30FF → UTF-8: E3 82 A0 - E3 83 BF

local function containsJapanese(text)
    local i = 1
    while i <= #text do
        local b = string.byte(text, i)
        if b >= 0xE3 and i + 2 <= #text then
            local b2 = string.byte(text, i + 1)
            local b3 = string.byte(text, i + 2)
            -- ひらがな: E3 81 80 ~ E3 82 9F
            if b == 0xE3 and b2 == 0x81 and b3 >= 0x80 then return true end
            if b == 0xE3 and b2 == 0x82 and b3 <= 0x9F then return true end
            -- カタカナ: E3 82 A0 ~ E3 83 BF
            if b == 0xE3 and b2 == 0x82 and b3 >= 0xA0 then return true end
            if b == 0xE3 and b2 == 0x83 then return true end
            i = i + 3
        elseif b >= 0xF0 then
            i = i + 4
        elseif b >= 0xE0 then
            i = i + 3
        elseif b >= 0xC0 then
            i = i + 2
        else
            i = i + 1
        end
    end
    return false
end

-- ============================================================================
-- アイテムリンク解決
-- ============================================================================
-- メッセージ内の |iItemID,...; 形式のリンクを [アイテム名] に置換する
-- itemGrade に応じた等級マーカーを付加し、アイテム情報リストを返す

local GRADE_MARKER = {
    [0]  = "",        -- Basic（一般）
    [1]  = "",        -- Grand（高級）
    [2]  = "",        -- Rare（希少）
    [3]  = "",        -- Arcane（古代）
    [4]  = "",        -- Heroic（英雄）
    [5]  = "",        -- Heroic（英雄）
    [6]  = "",        -- Unique（唯一）
    [7]  = "",        -- Celestial（天上）
    [8]  = "",        -- Divine（神聖）
    [9]  = "",        -- Epic（叙事）
    [10] = "",        -- Legendary（伝説）
    [11] = "",        -- Mythic（神話）
}

-- gradeColor 文字列 "FFRRGGBB" を {r, g, b, 1} テーブルに変換
local function ParseGradeColor(hexStr)
    if hexStr == nil or #hexStr < 8 then return nil end
    -- "FFBA976D" → skip first 2 (alpha), take RRGGBB
    local r = tonumber(hexStr:sub(3, 4), 16)
    local g = tonumber(hexStr:sub(5, 6), 16)
    local b = tonumber(hexStr:sub(7, 8), 16)
    if r and g and b then
        return { r / 255, g / 255, b / 255, 1 }
    end
    return nil
end

-- resolvedItems: 呼び出し後にアイテム情報が格納されるテーブル（外から参照）
local lastResolvedItems = {}

local function resolveItemLinks(msg)
    lastResolvedItems = {}
    local resolved = string.gsub(msg, "|i(%d+)([^;]*);", function(idStr, rest)
        local itemId = tonumber(idStr)
        if itemId == nil then return "[Item]" end

        local info = api.Item:GetItemInfoByType(itemId)
        if info and info.name and info.name ~= "" then
            local marker = ""
            local grade = tonumber(info.itemGrade)
            if grade and GRADE_MARKER[grade] then
                marker = GRADE_MARKER[grade]
            end
            -- アイテム情報を保存（等級色付き表示用）
            local color = ParseGradeColor(info.gradeColor)
            table.insert(lastResolvedItems, {
                name   = marker .. info.name,
                color  = color or {1, 1, 1, 1},
            })
            if marker ~= "" then
                return "[" .. marker .. info.name .. "]"
            end
            return "[" .. info.name .. "]"
        end
        return "[Item#" .. idStr .. "]"
    end)
    return resolved
end

-- 直前の resolveItemLinks で抽出されたアイテム情報を返す
local function getLastResolvedItems()
    return lastResolvedItems
end

-- チャンネル名から表示ラベルを生成（名前の開始位置を揃える）
local CHANNEL_DISPLAY = {
    Whisper   = "[W From]",
    WhisperTo = "[W To  ]",
}

local function makeLabel(channelName)
    return CHANNEL_DISPLAY[channelName] or ("[" .. channelName .. "]")
end

-- ============================================================================
-- チャット受信 → input.lua に書き出す
-- ============================================================================

local function writeChatToFile(channel, unit, isHostile, name, message)
    if unit == "player" then return end
    if name == nil or name == "" then return end
    if message == nil or #message <= 0 then return end

    local channelId   = tonumber(channel)
    local channelName = CHANNEL_LABEL[channelId]
    if channelName == nil then return end

    -- WhisperTo は設定上 Whisper と共通（色・表示/非表示）
    local colorKey = channelName
    if channelName == "WhisperTo" then colorKey = "Whisper" end

    -- NPC名リストに登録されていれば完全にスキップ（翻訳もウィンドウ表示もしない）
    if settings.IsNpc(name) then return end

    -- 同一人物 + 同一メッセージの連投をスキップ
    if name == lastSender and message == lastMessage then return end
    lastSender  = name
    lastMessage = message

    -- Family チャットは翻訳せずそのまま表示
    if channelName == "Family" then
        local resolvedMsg = resolveItemLinks(message)
        local label = makeLabel(channelName)
        ui.AddMessage(label, name, colorKey, resolvedMsg, resolvedMsg)
        return
    end

    -- アイテムリンクを名前に置換してから書き出す
    local resolvedMsg = resolveItemLinks(message)
    local items = getLastResolvedItems()

    -- 日本語が含まれるメッセージは翻訳せずそのまま表示（アイテムリンク解決後に判定）
    if containsJapanese(resolvedMsg) then
        local label = makeLabel(channelName)
        ui.AddMessage(label, name, colorKey, resolvedMsg, resolvedMsg)
        return
    end

    -- 設定で非表示に指定されているチャンネルは表示も翻訳もしない
    if not settings.GetVisible(colorKey) then return end

    -- "x " で始まる短いメッセージ（レイド参加表明等）は翻訳せず直接表示
    -- "wts" / "wtb" で始まるメッセージも翻訳せず直接表示
    local lower = string.lower(resolvedMsg)
    if string.sub(lower, 1, 2) == "x "
        or string.sub(lower, 1, 3) == "wts"
        or string.sub(lower, 1, 3) == "wtb"
        or string.sub(lower, 1, 4) == "~ x " then
        local label = makeLabel(channelName)
        local itemColorMap = {}
        for _, item in ipairs(items) do
            itemColorMap[item.name] = item.color
        end
        ui.AddMessageWithItems(label, name, colorKey, resolvedMsg, resolvedMsg, itemColorMap)
        return
    end

    -- exe が動作していない場合は翻訳リクエストを送らない
    if engineMode ~= MODE_TRANSLATE then return end

    -- アイテム情報をキューに保存（翻訳結果受信時に取り出す）
    table.insert(pendingItems, items)

    local msg = string.format("[[JPCHAT||||%s||||%s||||%s]]", channelName, name, resolvedMsg)
    api.File:Write(INPUT_FILE, { chatMsg = msg })

    -- 応答待ち開始
    waitingResponse = true
    noResponseTime = 0
end

-- ============================================================================
-- output.lua をポーリング → UIウィンドウに表示
-- ============================================================================

local function readTranslation()
    local data = api.File:Read(OUTPUT_FILE)
    if data == nil then return end
    if data.chatMsg == nil or data.chatMsg == "" then return end

    local translated = data.chatMsg
    if translated == lastOutput then return end
    lastOutput = translated

    -- exe からの応答を受信 → 応答待ち解除
    noResponseTime = 0
    waitingResponse = false

    -- output形式: "Channel|||Sender|||翻訳テキスト|||原文"
    -- "|||" を固定セパレーターとして最大4分割する
    local function splitNext(s)
        local p1, p2 = string.find(s, "|||", 1, true)
        if p1 then
            return string.sub(s, 1, p1 - 1), string.sub(s, p2 + 1)
        end
        return s, ""
    end

    local colKey, sender, text, original
    local rest
    colKey, rest   = splitNext(translated)
    sender, rest   = splitNext(rest)
    text,   rest   = splitNext(rest)
    original = rest  -- 4フィールド目が原文（旧フォーマット時は空）

    if colKey == "" then colKey = "Say" end

    local label = makeLabel(colKey)

    -- WhisperTo は色設定で Whisper を使う
    local displayColorKey = colKey
    if colKey == "WhisperTo" then displayColorKey = "Whisper" end

    -- colKey をそのまま渡して ui 側で色を引く。original はツールチップ用
    -- キューからアイテム色情報を取り出す
    local itemColorMap = {}
    if #pendingItems > 0 then
        local items = table.remove(pendingItems, 1)
        if items then
            for _, item in ipairs(items) do
                itemColorMap[item.name] = item.color
            end
        end
    end

    -- アイテム色マップがあればオーバーレイ表示、なければ通常表示
    ui.AddMessageWithItems(label, sender, displayColorKey, text, original, itemColorMap)

    -- RaidLeader は画面中央上部のオーバーレイにも表示（自動フェードアウト）
    if colKey == "RaidLeader" and ui.ShowRaidLeaderOverlay then
        ui.ShowRaidLeaderOverlay(sender .. ": " .. text)
    end

    -- 読んだら空にする
    api.File:Write(OUTPUT_FILE, { chatMsg = "" })
end

-- ============================================================================
-- 送信翻訳結果をポーリング → 血盟チャットに送信
-- ============================================================================

local lastSendOutput = ""

local function readSendTranslation()
    local data = api.File:Read(SEND_OUTPUT_FILE)
    if data == nil then return end
    if data.chatMsg == nil or data.chatMsg == "" then return end

    local translated = data.chatMsg
    if translated == lastSendOutput then return end
    lastSendOutput = translated

    -- 翻訳結果をUIウィンドウに表示（クリップボードにコピー済み）
    ui.AddMessage("[Send]", "\226\134\146", "Say", translated, "")

    -- 読んだら空にする
    api.File:Write(SEND_OUTPUT_FILE, { chatMsg = "" })
end

-- ============================================================================
-- UPDATE ループ
-- ============================================================================

local function OnUpdate(dt)
    clockTimer = clockTimer + dt
    if clockTimer > POLL_INTERVAL then
        clockTimer = 0

        -- ハートビート確認は5秒ごと、IDLEモード時のみ
        if engineMode == MODE_IDLE then
            hbCheckTimer = hbCheckTimer + POLL_INTERVAL
            if hbCheckTimer >= HB_CHECK_INTERVAL then
                hbCheckTimer = 0
                local hbData = api.File:Read(HEARTBEAT_FILE)
                if hbData and hbData.status == "ready" then
                    engineMode = MODE_TRANSLATE
                    noResponseTime = 0
                    ui.AddMessage("[System]", "", "Zone", "JpChatTranslator.exe接続完了", "")
                end
            end
        end

        -- 翻訳モード時の応答タイムアウト監視（応答待ち中のみ）
        if engineMode == MODE_TRANSLATE and waitingResponse then
            noResponseTime = noResponseTime + POLL_INTERVAL
            if noResponseTime > NO_RESPONSE_TIMEOUT then
                engineMode = MODE_IDLE
                pendingItems = {}
                waitingResponse = false
                noResponseTime = 0
                hbCheckTimer = 0
                ui.AddMessage("[System]", "", "Zone", "JpChatTranslator.exe接続待ち", "")
            end
        end

        readTranslation()
        readSendTranslation()
    end
    -- リサイズ処理（ドラッグ中のみ動作）
    ui.OnUpdate()
end

-- ============================================================================
-- OnLoad / OnUnload
-- ============================================================================

local function OnLoad()
    -- 設定を読み込む
    settings.Load()

    -- === フォントサイズ変更テスト ===
    -- style:SetFontSize が使えるかテスト（UI Init 後に実行）
    -- === テストここまで ===

    -- ui に設定モジュールと設定ページ開き関数を注入
    ui.SetSettings(settings)
    ui.SetSettingsOpener(function() settingsPage.Open() end)

    -- 設定ページに設定モジュールと各種コールバックを注入
    settingsPage.Init(
        settings,
        function() ui.RefreshColors() end,
        function(a) ui.SetOpacity(a) end,
        function(s) ui.SetFontSize(s) end,
        function(x, y) ui.SetRaidOverlayPos(x, y) end,
        function() ui.PreviewRaidOverlay() end
    )

    -- UI ウィンドウを構築
    ui.Init()

    -- 初回起動時は IDLE モード → 接続待ちを表示
    ui.AddMessage("[System]", "", "Zone", "JpChatTranslator.exe接続待ち", "")

    -- 送信機能のコールバックをUIに注入
    ui.SetSendHandler(function(text)
        -- 日本語テキストを send_input.lua に書き出す → 翻訳エンジンが翻訳して返す
        api.File:Write(SEND_INPUT_FILE, { chatMsg = text })
    end)

    -- NPC登録コールバックをUIに注入
    ui.SetNpcRegisterHandler(function(name)
        settings.AddNpc(name)
        settings.Save()
        api.Log:Info("[jpchat] NPCとして登録: " .. name)
    end)

    -- チャット受信キャンバスを作成
    cantReadWindow = api.Interface:CreateEmptyWindow("jpchatCanvas")

    function cantReadWindow:OnEvent(event, ...)
        if event == "CHAT_MESSAGE" then
            if arg ~= nil then
                writeChatToFile(unpack(arg))
            end
        end
    end
    cantReadWindow:SetHandler("OnEvent", cantReadWindow.OnEvent)
    cantReadWindow:RegisterEvent("CHAT_MESSAGE")

    api.On("UPDATE", OnUpdate)

    -- 通信ファイルを初期化
    api.File:Write(INPUT_FILE,       { chatMsg = "" })
    api.File:Write(OUTPUT_FILE,      { chatMsg = "" })
    api.File:Write(SEND_INPUT_FILE,  { chatMsg = "" })
    api.File:Write(SEND_OUTPUT_FILE, { chatMsg = "" })

    api.Log:Info("[jpchat] Loaded. Run translator.py to enable translations.")
end

local function OnUnload()
    api.On("UPDATE", function() return end)
    if cantReadWindow then
        cantReadWindow:ReleaseHandler("OnEvent")
        api.Interface:Free(cantReadWindow)
        cantReadWindow = nil
    end
    settingsPage.Shutdown()
    ui.Shutdown()
end

jpchat_addon.OnLoad  = OnLoad
jpchat_addon.OnUnload = OnUnload

return jpchat_addon
