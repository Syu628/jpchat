local api = require("api")

-- ============================================================================
-- 定数
-- ============================================================================

local WIN_W_DEFAULT = 520
local WIN_H_DEFAULT = 380
local WIN_W_MIN     = 280
local WIN_H_MIN     = 120
local HEADER_H      = 30
local FOOTER_H      = 52   -- 入力欄を含むため拡張
local RESIZE_SZ     = 14   -- リサイズハンドルのサイズ（px）
local LINE_H        = 18   -- フォントサイズに応じて動的に変更される
local MAX_MSGS      = 200

-- フォント幅の目安（GetFontSize() に連動して UpdateLineHeight 内で更新）
local HALF_PX = 7
local FULL_PX = 14

-- ============================================================================
-- 内部状態
-- ============================================================================

local win         = nil
local bodyWidget  = nil
local footer      = nil
local resizeHandle = nil
local bodyRows    = {}         -- { {lbl=label, overlay=label}, ... } 各行に2枚のラベル
local BODY_ROWS   = 0
local messages    = {}         -- { full, colKey, original, itemRanges } 
                               -- itemRanges: { {s=startByte, e=endByte, color={r,g,b,a}}, ... } or nil
local rowOffset   = 0
local bodyVisible = true

-- 現在のウィンドウサイズ（リサイズ後に更新）
local WIN_W = WIN_W_DEFAULT
local WIN_H = WIN_H_DEFAULT

-- リサイズ用ドラッグ状態
local resizing    = false
local resizeSX    = 0   -- ドラッグ開始時のマウスX
local resizeSY    = 0   -- ドラッグ開始時のマウスY
local resizeBaseW = 0   -- ドラッグ開始時のウィンドウ幅
local resizeBaseH = 0   -- ドラッグ開始時のウィンドウ高さ

-- テキスト折り返し幅（WIN_W に連動して更新）
local TEXT_WIDTH = WIN_W - 14

local bgDrawables = {}
local settings    = nil

-- ============================================================================
-- テキスト折り返し
-- ============================================================================

local function WrapText(s)
    local lines     = {}
    local lineStart = 1
    local lineW     = 0

    local i = 1
    while i <= #s do
        local b = s:byte(i)
        local charLen, charW
        if b < 0x80 then
            charLen = 1; charW = HALF_PX
        elseif b < 0xE0 then
            charLen = 2; charW = FULL_PX
        elseif b < 0xF0 then
            charLen = 3; charW = FULL_PX
        else
            charLen = 4; charW = FULL_PX
        end

        if lineW + charW > TEXT_WIDTH then
            table.insert(lines, s:sub(lineStart, i - 1))
            lineStart = i
            lineW     = charW
        else
            lineW = lineW + charW
        end
        i = i + charLen
    end
    if lineStart <= #s then
        table.insert(lines, s:sub(lineStart))
    end
    if #lines == 0 then lines = { "" } end
    return lines
end

-- ============================================================================
-- ヘルパー
-- ============================================================================

local function CreateBackdrop(parent, r, g, b, a)
    local bg = parent:CreateColorDrawable(r, g, b, a, "background")
    bg:AddAnchor("TOPLEFT",     parent, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", parent, 0, 0)
    return bg
end

local function GetColor(colKey)
    if settings then
        local c = settings.GetColor(colKey)
        if c then return c end
    end
    return {1, 1, 1, 1}
end

local function GetOpacity()
    if settings and settings.GetOpacity then
        return settings.GetOpacity()
    end
    return 0.92
end

-- 現在のフォントサイズを返す（設定なし時は 13）
local function GetFontSize()
    if settings and settings.GetFontSize then
        return settings.GetFontSize()
    end
    return 13
end

-- フォントサイズに応じて LINE_H とフォント幅を更新する
local function UpdateLineHeight()
    local fs = GetFontSize()
    LINE_H  = fs + 6
    -- フォント幅をフォントサイズに比例させる
    HALF_PX = math.floor(fs * 0.55 + 0.5)
    FULL_PX = math.floor(fs * 1.05 + 0.5)
    TEXT_WIDTH = WIN_W - 14
end

local function ApplyOpacity()
    local a = GetOpacity()
    if bgDrawables.win    then bgDrawables.win:SetColor(0.10, 0.10, 0.14, a)    end
    if bgDrawables.body   then bgDrawables.body:SetColor(0.06, 0.06, 0.10, a)   end
    if bgDrawables.header then bgDrawables.header:SetColor(0.08, 0.08, 0.14, a) end
    if bgDrawables.footer then bgDrawables.footer:SetColor(0.08, 0.08, 0.14, a) end
end

-- ウィンドウ位置・サイズを settings に保存する
local function SaveWinPos()
    if not win then return end
    if not settings or not settings.SetWinPos then return end

    local x, y
    pcall(function() x, y = win:GetOffset() end)

    if x and y then
        -- GetOffset はスケール後の論理座標を返す
        -- AddAnchor はスケール前の座標を期待するため、UIScale を掛けて変換する
        local scale = 1
        pcall(function() scale = api.Interface:GetUIScale() end)
        if scale and scale > 0 then
            x = x * scale
            y = y * scale
        end
        settings.SetWinPos(x, y, WIN_W, WIN_H)
        settings.Save()
    end
end

-- ============================================================================
-- ツールチップ（原文表示）
-- ============================================================================

local function GetMsgIndex(rowIdx)
    local total    = #displayLines
    local endIdx   = total - rowOffset
    local startIdx = math.max(1, endIdx - BODY_ROWS + 1)
    return startIdx + rowIdx - 1
end

local function ShowOriginalTooltip(rowWidget, msgIdx)
    local dl = displayLines[msgIdx]
    if dl == nil then return end
    local original = dl.original
    if original == nil or original == "" then return end
    if api.Tooltip then
        api.Tooltip:SetText(original)
        api.Tooltip:Show(true)
        api.Tooltip:ClearAnchors()
        api.Tooltip:AddAnchor("BOTTOMLEFT", rowWidget, "TOPLEFT", 0, -4)
    end
end

local function HideOriginalTooltip()
    if api.Tooltip then api.Tooltip:Show(false) end
end

-- ============================================================================
-- 描画
-- ============================================================================

-- messages を現在の TEXT_WIDTH で折り返して表示行の配列を生成する
-- 戻り値: { {text, colKey, original}, ... } （表示行単位）
local function BuildDisplayLines()
    local lines = {}
    for _, msg in ipairs(messages) do
        local wrapped = WrapText(msg.full)
        -- 折り返し行ごとにアイテム範囲を再計算する
        local byteOffset = 0
        for idx, lineText in ipairs(wrapped) do
            local lineLen = #lineText
            -- この行に含まれるアイテム範囲を抽出
            local lineRanges = nil
            if msg.itemRanges then
                for _, r in ipairs(msg.itemRanges) do
                    -- 元テキスト中の範囲 [r.s, r.e] が現在行 [byteOffset+1, byteOffset+lineLen] と重なるか
                    local lineStart = byteOffset + 1
                    local lineEnd   = byteOffset + lineLen
                    if r.s <= lineEnd and r.e >= lineStart then
                        local localS = math.max(r.s - byteOffset, 1)
                        local localE = math.min(r.e - byteOffset, lineLen)
                        if lineRanges == nil then lineRanges = {} end
                        table.insert(lineRanges, { s = localS, e = localE, color = r.color })
                    end
                end
            end
            table.insert(lines, {
                text        = lineText,
                colKey      = msg.colKey,
                original    = (idx == 1) and msg.original or "",
                customColor = msg.customColor,
                itemRanges  = lineRanges,
            })
            byteOffset = byteOffset + lineLen
        end
    end
    return lines
end

-- 現在表示すべき行データのキャッシュ（リサイズ / メッセージ追加時に更新）
local displayLines = {}

local function RefreshDisplayLines()
    displayLines = BuildDisplayLines()
end

-- テキスト中の指定範囲を同じバイト数のスペースに置き換える
local function BlankRanges(text, ranges)
    if not ranges or #ranges == 0 then return text end
    local result = text
    -- 後ろの範囲から置き換えることでバイト位置がずれないようにする
    -- まずソート（降順）
    local sorted = {}
    for _, r in ipairs(ranges) do table.insert(sorted, r) end
    table.sort(sorted, function(a, b) return a.s > b.s end)
    for _, r in ipairs(sorted) do
        local len = r.e - r.s + 1
        result = string.sub(result, 1, r.s - 1) .. string.rep(" ", len) .. string.sub(result, r.e + 1)
    end
    return result
end

-- テキスト中の指定範囲 以外 を同じバイト数のスペースに置き換える
local function KeepOnlyRanges(text, ranges)
    if not ranges or #ranges == 0 then return "" end
    -- 全体をスペースにしてからアイテム部分だけ復元
    local result = string.rep(" ", #text)
    for _, r in ipairs(ranges) do
        local item = string.sub(text, r.s, r.e)
        result = string.sub(result, 1, r.s - 1) .. item .. string.sub(result, r.e + 1)
    end
    return result
end

local function RedrawBody()
    if not bodyWidget then return end
    local total    = #displayLines
    local endIdx   = total - rowOffset
    local startIdx = math.max(1, endIdx - BODY_ROWS + 1)
    local row = 1
    for i = startIdx, endIdx do
        local dl = displayLines[i]
        if dl and bodyRows[row] then
            local lbl     = bodyRows[row].lbl
            local overlay = bodyRows[row].overlay

            -- 本文色を決定
            local col
            if dl.customColor then
                col = dl.customColor
            else
                col = GetColor(dl.colKey)
            end

            if dl.itemRanges and #dl.itemRanges > 0 then
                -- アイテム範囲がある行: 2レイヤー表示
                lbl:SetText(BlankRanges(dl.text, dl.itemRanges))
                if lbl.style then
                    lbl.style:SetColor(col[1], col[2], col[3], col[4])
                end
                lbl:Show(true)

                overlay:SetText(KeepOnlyRanges(dl.text, dl.itemRanges))
                local itemCol = dl.itemRanges[1].color or {1, 1, 1, 1}
                if overlay.style then
                    overlay.style:SetColor(itemCol[1], itemCol[2], itemCol[3], itemCol[4])
                end
                overlay:Show(true)
            else
                -- アイテム範囲なし: 本文のみ表示
                lbl:SetText(dl.text)
                if lbl.style then
                    lbl.style:SetColor(col[1], col[2], col[3], col[4])
                end
                lbl:Show(true)
                overlay:SetText("")
                overlay:Show(false)
            end
        end
        row = row + 1
    end
    for i = row, #bodyRows do
        if bodyRows[i] and bodyRows[i].lbl then
            bodyRows[i].lbl:SetText("")
            bodyRows[i].lbl:Show(false)
        end
        if bodyRows[i] and bodyRows[i].overlay then
            bodyRows[i].overlay:SetText("")
            bodyRows[i].overlay:Show(false)
        end
    end
end

local function Scroll(delta)
    local maxOffset = math.max(0, #displayLines - BODY_ROWS)
    rowOffset = math.max(0, math.min(maxOffset, rowOffset + delta))
    RedrawBody()
end

local function WheelHandler(self, d)
    Scroll(d > 0 and 3 or -3)
end

-- ============================================================================
-- リサイズ後に子ウィジェットを新しいサイズへ追従させる
-- ============================================================================

-- ボディ行・スクロールボタンの再構築（行数が変わる可能性があるため再生成）
local function RebuildBody()
    if not bodyWidget then return end

    -- 既存の行ラベルを破棄
    for i = 1, #bodyRows do
        if bodyRows[i] then
            if bodyRows[i].lbl then bodyRows[i].lbl:Show(false) end
            if bodyRows[i].overlay then bodyRows[i].overlay:Show(false) end
        end
    end
    bodyRows = {}

    local innerH  = WIN_H - HEADER_H - FOOTER_H
    BODY_ROWS = math.floor(innerH / LINE_H)

    -- bodyWidget のサイズを更新
    bodyWidget:SetExtent(WIN_W, innerH)
    TEXT_WIDTH = WIN_W - 14

    for i = 1, BODY_ROWS do
        -- 本文レイヤー
        local lbl = bodyWidget:CreateChildWidget("label", "jpchatRow" .. i, 0, true)
        lbl:AddAnchor("TOPLEFT", bodyWidget, 6, (i - 1) * LINE_H + 2)
        lbl:SetExtent(WIN_W - 14, LINE_H)
        if lbl.style then
            lbl.style:SetAlign(ALIGN.LEFT)
            lbl.style:SetShadow(true)
            lbl.style:SetFontSize(GetFontSize())
            lbl.style:SetColor(1, 1, 1, 1)
        end
        lbl:SetText("")
        lbl:Show(false)
        lbl:EnableDrag(true)
        lbl:SetHandler("OnMouseWheel", WheelHandler)

        local rowIdx = i
        lbl:SetHandler("OnEnter", function(self)
            local msgIdx = GetMsgIndex(rowIdx)
            ShowOriginalTooltip(self, msgIdx)
        end)
        lbl:SetHandler("OnLeave", function()
            HideOriginalTooltip()
        end)

        -- オーバーレイレイヤー（アイテム名用、同じ位置に重ねる）
        local overlay = bodyWidget:CreateChildWidget("label", "jpchatRowOv" .. i, 0, true)
        overlay:AddAnchor("TOPLEFT", bodyWidget, 6, (i - 1) * LINE_H + 2)
        overlay:SetExtent(WIN_W - 14, LINE_H)
        if overlay.style then
            overlay.style:SetAlign(ALIGN.LEFT)
            overlay.style:SetShadow(true)
            overlay.style:SetFontSize(GetFontSize())
            overlay.style:SetColor(1, 1, 0, 1)
        end
        overlay:SetText("")
        overlay:Show(false)
        overlay:EnableDrag(true)
        overlay:SetHandler("OnMouseWheel", WheelHandler)

        bodyRows[i] = { lbl = lbl, overlay = overlay }
    end

    -- スクロールボタンはアンカーが BOTTOMRIGHT なので位置は自動追従
    RefreshDisplayLines()
    rowOffset = math.max(0, math.min(math.max(0, #displayLines - BODY_ROWS), rowOffset))
    RedrawBody()
end

-- リサイズハンドルの位置を右下に合わせる（ハンドルはアンカー BOTTOMRIGHT なので自動）
local function OnResized()
    -- ウィンドウ全体サイズを適用
    win:SetExtent(WIN_W, WIN_H)
    RebuildBody()
    -- リサイズハンドルを最前面に保つため再表示
    if resizeHandle then resizeHandle:Show(true) end
    -- 位置・サイズを保存
    SaveWinPos()
end

-- ============================================================================
-- ウィンドウ構築
-- ============================================================================

local settingsPageOpen = nil
local btnToggle        = nil
local sendHandler      = nil  -- 送信コールバック（main.lua から注入）
local sendEditWidget   = nil  -- 入力欄（リサイズ連動用）

local function SetBodyVisible(visible)
    bodyVisible = visible
    if bodyWidget then bodyWidget:Show(visible) end
    if footer     then footer:Show(visible)     end
    if resizeHandle then resizeHandle:Show(visible) end
    if win then
        if visible then
            win:SetExtent(WIN_W, WIN_H)
        else
            win:SetExtent(WIN_W, HEADER_H)
        end
    end
    if btnToggle then
        btnToggle:SetText(visible and "隠す" or "表示")
    end
end

local function CreateHeader()
    local header = win:CreateChildWidget("emptywidget", "jpchatHeader", 0, true)
    header:AddAnchor("TOPLEFT",  win, 0, 0)
    header:AddAnchor("TOPRIGHT", win, 0, 0)
    header:SetHeight(HEADER_H)
    bgDrawables.header = CreateBackdrop(header, 0.08, 0.08, 0.14, GetOpacity())

    local title = header:CreateChildWidget("label", "jpchatTitle", 0, true)
    title:SetText("JP Chat 翻訳")
    title:SetExtent(180, HEADER_H)
    title:AddAnchor("LEFT", header, 8, 0)
    if title.style then
        title.style:SetAlign(ALIGN.LEFT)
        title.style:SetColor(0.8, 0.8, 0.9, 1)
    end

    -- 閉じるボタン（右端）
    local btnClose = header:CreateChildWidget("button", "jpchatClose", 0, true)
    btnClose:SetExtent(26, 20)
    btnClose:AddAnchor("RIGHT", header, -4, 0)
    btnClose:SetText("X")
    btnClose:SetHandler("OnClick", function() win:Show(false) end)

    -- 設定ボタン
    local btnSettings = header:CreateChildWidget("button", "jpchatSettings", 0, true)
    btnSettings:SetExtent(46, 20)
    btnSettings:AddAnchor("RIGHT", header, -34, 0)
    btnSettings:SetText("設定")
    btnSettings:SetHandler("OnClick", function()
        if settingsPageOpen then settingsPageOpen() end
    end)

    -- Hide/Show トグルボタン
    btnToggle = header:CreateChildWidget("button", "jpchatToggle", 0, true)
    btnToggle:SetExtent(44, 20)
    btnToggle:AddAnchor("RIGHT", header, -84, 0)
    btnToggle:SetText("隠す")
    btnToggle:SetHandler("OnClick", function()
        SetBodyVisible(not bodyVisible)
    end)

    -- Shift+ドラッグで移動
    header:EnableDrag(true)
    header:SetHandler("OnDragStart", function()
        if api.Input:IsShiftKeyDown() then win:StartMoving() end
    end)
    header:SetHandler("OnDragStop", function()
        win:StopMovingOrSizing()
        SaveWinPos()
    end)
end

local function CreateBody()
    local innerH = WIN_H - HEADER_H - FOOTER_H
    BODY_ROWS = math.floor(innerH / LINE_H)

    bodyWidget = win:CreateChildWidget("emptywidget", "jpchatBody", 0, true)
    bodyWidget:AddAnchor("TOPLEFT", win, 0, HEADER_H)
    bodyWidget:SetExtent(WIN_W, innerH)
    bodyWidget:EnableDrag(true)
    bodyWidget:SetHandler("OnMouseWheel", WheelHandler)
    bgDrawables.body = CreateBackdrop(bodyWidget, 0.06, 0.06, 0.10, GetOpacity())

    for i = 1, BODY_ROWS do
        -- 本文レイヤー
        local lbl = bodyWidget:CreateChildWidget("label", "jpchatRow" .. i, 0, true)
        lbl:AddAnchor("TOPLEFT", bodyWidget, 6, (i - 1) * LINE_H + 2)
        lbl:SetExtent(WIN_W - 14, LINE_H)
        if lbl.style then
            lbl.style:SetAlign(ALIGN.LEFT)
            lbl.style:SetShadow(true)
            lbl.style:SetFontSize(GetFontSize())
            lbl.style:SetColor(1, 1, 1, 1)
        end
        lbl:SetText("")
        lbl:Show(false)
        lbl:EnableDrag(true)
        lbl:SetHandler("OnMouseWheel", WheelHandler)

        local rowIdx = i
        lbl:SetHandler("OnEnter", function(self)
            local msgIdx = GetMsgIndex(rowIdx)
            ShowOriginalTooltip(self, msgIdx)
        end)
        lbl:SetHandler("OnLeave", function()
            HideOriginalTooltip()
        end)

        -- オーバーレイレイヤー（アイテム名用、同じ位置に重ねる）
        local overlay = bodyWidget:CreateChildWidget("label", "jpchatRowOv" .. i, 0, true)
        overlay:AddAnchor("TOPLEFT", bodyWidget, 6, (i - 1) * LINE_H + 2)
        overlay:SetExtent(WIN_W - 14, LINE_H)
        if overlay.style then
            overlay.style:SetAlign(ALIGN.LEFT)
            overlay.style:SetShadow(true)
            overlay.style:SetFontSize(GetFontSize())
            overlay.style:SetColor(1, 1, 0, 1)
        end
        overlay:SetText("")
        overlay:Show(false)
        overlay:EnableDrag(true)
        overlay:SetHandler("OnMouseWheel", WheelHandler)

        bodyRows[i] = { lbl = lbl, overlay = overlay }
    end

    local btnUp = bodyWidget:CreateChildWidget("button", "jpchatUp", 0, true)
    btnUp:SetExtent(20, 24)
    btnUp:AddAnchor("TOPRIGHT", bodyWidget, -2, 2)
    btnUp:SetText("^")
    btnUp:SetHandler("OnClick", function() Scroll(3) end)

    local btnDn = bodyWidget:CreateChildWidget("button", "jpchatDn", 0, true)
    btnDn:SetExtent(20, 24)
    btnDn:AddAnchor("BOTTOMRIGHT", bodyWidget, -2, -2)
    btnDn:SetText("v")
    btnDn:SetHandler("OnClick", function() Scroll(-3) end)
end

local function CreateFooter()
    footer = win:CreateChildWidget("emptywidget", "jpchatFooter", 0, true)
    footer:AddAnchor("BOTTOMLEFT",  win, 0, 0)
    footer:AddAnchor("BOTTOMRIGHT", win, 0, 0)
    footer:SetHeight(FOOTER_H)
    bgDrawables.footer = CreateBackdrop(footer, 0.08, 0.08, 0.14, GetOpacity())

    -- 上段: Clear ボタン
    local btnClear = footer:CreateChildWidget("button", "jpchatClear", 0, true)
    btnClear:SetExtent(60, 20)
    btnClear:AddAnchor("TOPRIGHT", footer, -8, 2)
    btnClear:SetText("消去")
    btnClear:SetHandler("OnClick", function()
        messages     = {}
        displayLines = {}
        rowOffset    = 0
        RedrawBody()
    end)

    -- 下段: テキスト入力欄 + Send ボタン（日本語→英語翻訳送信用）
    local sendEdit = W_CTRL.CreateEdit("jpchatSendEdit", footer)
    sendEdit:SetHeight(20)
    sendEdit:AddAnchor("BOTTOMLEFT", footer, 6, -4)
    sendEdit:AddAnchor("BOTTOMRIGHT", footer, -76, -4)
    sendEdit:SetText("")
    sendEditWidget = sendEdit  -- リサイズ連動用に保持

    -- 送信処理を共通関数化
    local function doSend()
        local text = sendEdit:GetText()
        if text == nil or text == "" then return end
        if sendHandler then
            sendHandler(text)
        end
        sendEdit:SetText("")
    end

    -- Enter キーで送信し、フォーカスを外す
    sendEdit:SetHandler("OnEnterPressed", function()
        doSend()
        sendEdit:ClearFocus()
    end)

    local btnSend = footer:CreateChildWidget("button", "jpchatSend", 0, true)
    btnSend:SetExtent(62, 20)
    btnSend:AddAnchor("BOTTOMRIGHT", footer, -8, -4)
    btnSend:SetText("翻訳")
    btnSend:SetHandler("OnClick", function()
        doSend()
    end)
end

-- リサイズハンドル：右下隅に配置し、ドラッグでウィンドウをリサイズする
local function CreateResizeHandle()
    resizeHandle = win:CreateChildWidget("button", "jpchatResize", 0, true)
    resizeHandle:SetExtent(RESIZE_SZ, RESIZE_SZ)
    resizeHandle:AddAnchor("BOTTOMRIGHT", win, -2, -2)
    -- 三角形を連想させる文字でハンドルを示す
    resizeHandle:SetText("◢")

    resizeHandle:EnableDrag(true)

    resizeHandle:SetHandler("OnDragStart", function()
        -- まず StartSizing を試みる（API が対応している場合）
        local ok = pcall(function() win:StartSizing("BOTTOMRIGHT") end)
        if ok then
            -- StartSizing が成功した場合は OnDragStop で処理
            resizing = false
        else
            -- フォールバック: 純粋 Lua でマウス追跡リサイズ
            resizing = true
            resizeSX, resizeSY = api.Input:GetMousePos()
            resizeBaseW = WIN_W
            resizeBaseH = WIN_H
        end
    end)

    resizeHandle:SetHandler("OnDragStop", function()
        if resizing then
            -- 純粋 Lua リサイズの終了（OnUpdate 側で最終サイズ確定済み）
            resizing = false
        else
            -- StartSizing 経由: 実際のウィンドウサイズを読み取って子を再構築
            win:StopMovingOrSizing()
            local newW = win:GetWidth()
            local newH = win:GetHeight()
            if newW and newH then
                WIN_W = math.max(WIN_W_MIN, newW)
                WIN_H = math.max(WIN_H_MIN, newH)
                OnResized()
            end
        end
    end)
end

-- ============================================================================
-- UPDATE: 純粋 Lua リサイズ処理
-- ============================================================================

local function OnUpdateResize()
    if not resizing then return end
    local mx, my = api.Input:GetMousePos()
    local newW = math.max(WIN_W_MIN, resizeBaseW + (mx - resizeSX))
    local newH = math.max(WIN_H_MIN, resizeBaseH + (my - resizeSY))
    if newW ~= WIN_W or newH ~= WIN_H then
        WIN_W = newW
        WIN_H = newH
        OnResized()
    end
end

-- ============================================================================
-- 公開 API
-- ============================================================================

local M = {}

function M.SetSettings(s)
    settings = s
end

function M.SetSettingsOpener(fn)
    settingsPageOpen = fn
end

function M.SetSendHandler(fn)
    sendHandler = fn
end

function M.Init()
    -- フォントサイズに応じて行高さを設定
    UpdateLineHeight()

    -- 保存されたウィンドウ位置・サイズがあれば復元する
    if settings and settings.GetWinPos then
        local pos = settings.GetWinPos()
        if pos and pos.x and pos.y and pos.w and pos.h then
            WIN_W = math.max(WIN_W_MIN, pos.w)
            WIN_H = math.max(WIN_H_MIN, pos.h)
            TEXT_WIDTH = WIN_W - 14
        end
    end

    win = api.Interface:CreateEmptyWindow("jpchatWindow")
    win:SetExtent(WIN_W, WIN_H)

    -- 位置復元: 常に TOPLEFT 基準で管理する
    local restored = false
    if settings and settings.GetWinPos then
        local pos = settings.GetWinPos()
        if pos and pos.x and pos.y then
            local px, py = pos.x, pos.y
            -- 解像度・スケール変更対策: 画面内に収まるようクランプする
            local screenW, screenH = 1920, 1080
            pcall(function() screenW = api.Interface:GetScreenWidth() end)
            pcall(function() screenH = api.Interface:GetScreenHeight() end)
            local scale = 1
            pcall(function() scale = api.Interface:GetUIScale() end)
            -- AddAnchor に渡す座標は UIScale 適用前の値
            -- 画面サイズもスケールで割って論理座標空間に合わせる
            local logicalW = screenW * scale
            local logicalH = screenH * scale
            local maxX = logicalW - 100
            local maxY = logicalH - 50
            if px > maxX then px = maxX end
            if py > maxY then py = maxY end
            if px < 0 then px = 0 end
            if py < 0 then py = 0 end
            win:AddAnchor("TOPLEFT", "UIParent", "TOPLEFT", px, py)
            restored = true
        end
    end
    if not restored then
        -- デフォルト: 画面右上付近（TOPLEFT基準で計算）
        local screenW = 1920
        pcall(function() screenW = api.Interface:GetScreenWidth() end)
        local scale = 1
        pcall(function() scale = api.Interface:GetUIScale() end)
        local logicalW = screenW * scale
        local defaultX = logicalW - WIN_W - 20
        local defaultY = 200
        win:AddAnchor("TOPLEFT", "UIParent", "TOPLEFT", defaultX, defaultY)
    end

    win:Show(true)
    bgDrawables.win = CreateBackdrop(win, 0.10, 0.10, 0.14, GetOpacity())

    CreateHeader()
    CreateBody()
    CreateFooter()
    CreateResizeHandle()
end

-- リサイズ UPDATE を main.lua の OnUpdate から呼んでもらう
function M.OnUpdate()
    OnUpdateResize()
end

-- colKey:     チャンネルキー文字列（"Say", "Party" など）
-- translated: 翻訳後テキスト
-- original:   翻訳前の原文（ツールチップに表示）
function M.AddMessage(label, sender, colKey, translated, original)
    local prefix = label .. " " .. sender .. ": "
    local body   = translated or ""
    local full   = prefix .. body

    -- 折り返し前の生テキストを保持（描画時に動的に折り返す）
    table.insert(messages, {
        full     = full,
        colKey   = colKey,
        original = original or "",
    })

    while #messages > MAX_MSGS do
        table.remove(messages, 1)
    end

    RefreshDisplayLines()
    rowOffset = 0
    RedrawBody()
end

function M.RefreshColors()
    RedrawBody()
end

-- 指定色で1行を追加（アイテム名の等級色表示用）
-- color: {r, g, b, a} テーブル
function M.AddColoredLine(text, color)
    table.insert(messages, {
        full       = text or "",
        colKey     = "__custom__",
        original   = "",
        customColor = color,  -- 直接指定色
    })

    while #messages > MAX_MSGS do
        table.remove(messages, 1)
    end

    RefreshDisplayLines()
    rowOffset = 0
    RedrawBody()
end

-- アイテム名の色表示（オーバーレイ方式）
-- 現在は通常表示にフォールバック
function M.AddMessageWithItems(label, sender, colKey, text, original, itemColorMap)
    M.AddMessage(label, sender, colKey, text, original)
end

function M.GetTestLabel()
    if bodyRows[1] and bodyRows[1].lbl then
        return bodyRows[1].lbl
    end
    return nil
end

-- フォントサイズを変更する（全行に適用）
function M.SetFontSize(size)
    if settings and settings.SetFontSize then
        settings.SetFontSize(size)
        settings.Save()
    end
    -- LINE_H を更新してボディを再構築
    UpdateLineHeight()
    RebuildBody()
end

function M.SetOpacity(a)
    if settings and settings.SetOpacity then
        settings.SetOpacity(a)
        settings.Save()
    end
    ApplyOpacity()
end

function M.Shutdown()
    HideOriginalTooltip()
    if win then
        win:Show(false)
        api.Interface:Free(win)
        win          = nil
        bodyWidget   = nil
        footer       = nil
        resizeHandle = nil
        bodyRows     = {}
        btnToggle    = nil
        bgDrawables  = {}
    end
end

return M
