local api = require("api")

-- ============================================================================
-- 設定ウィンドウ
-- チャンネルごとに 表示チェック / R/G/B 色 / 透過率 を変更できる
-- ============================================================================

local WIN_W   = 440   -- チェックボックス列 + RaidLeader 対応で幅を拡張
local ROW_H   = 24
local PADDING = 10

-- 列の X 座標（左から順に配置）
local COL_CHECK   = PADDING            -- チェックボタン  (幅26)
local COL_LABEL   = PADDING + 30       -- チャンネル名    (幅80)
local COL_R       = COL_LABEL + 84     -- R 入力欄
local COL_G       = COL_R + 50         -- G 入力欄
local COL_B       = COL_G + 50         -- B 入力欄
local COL_PREVIEW = COL_B + 50         -- プレビュー
local COL_APPLY   = COL_PREVIEW + 38   -- Apply ボタン
local COL_RESET   = COL_APPLY + 56     -- Reset ボタン

local win              = nil
local sRows            = {}   -- 各チャンネル行のウィジェット参照
local settings         = nil
local onChanged        = nil  -- 色変更時コールバック（ui.RefreshColors）
local onOpacityChanged = nil  -- 透過率変更時コールバック（ui.SetOpacity）
local onFontSizeChanged = nil -- フォントサイズ変更時コールバック（ui.SetFontSize）
local onRaidPosChanged = nil  -- RaidLeader位置変更時コールバック（ui.SetRaidOverlayPos）
local onRaidPreview    = nil  -- RaidLeaderプレビュー時コールバック（ui.PreviewRaidOverlay）

local M = {}

-- ============================================================================
-- ヘルパー
-- ============================================================================

local function MakeColorEdit(id, parent, val)
    local edit = W_CTRL.CreateEdit(id, parent)
    edit:SetExtent(44, 18)
    edit:SetText(string.format("%.2f", val))
    return edit
end

local function ParseFloat(s)
    local v = tonumber(s)
    if v == nil then return nil end
    return math.max(0.0, math.min(1.0, v))
end

local function ParseOpacity(s)
    local v = tonumber(s)
    if v == nil then return nil end
    return math.max(0.10, math.min(1.0, v))
end

-- チェックボタンの見た目を現在の visible 状態に合わせて更新する
local function UpdateCheckBtn(btn, key)
    if settings.GetVisible(key) then
        btn:SetText("[v]")
    else
        btn:SetText("[ ]")
    end
end

-- ============================================================================
-- 行の構築
-- ============================================================================

local function BuildRow(key, yOffset)
    local col = settings.GetColor(key)

    -- ---- チェックボタン（表示/非表示トグル）----
    local chk = win:CreateChildWidget("button", "jpchatSP_chk_" .. key, 0, true)
    chk:SetExtent(24, ROW_H - 2)
    chk:AddAnchor("TOPLEFT", win, COL_CHECK, yOffset + 1)
    UpdateCheckBtn(chk, key)
    chk:SetHandler("OnClick", function()
        local cur = settings.GetVisible(key)
        settings.SetVisible(key, not cur)
        settings.Save()
        UpdateCheckBtn(chk, key)
        -- ラベルの alpha で有効/無効を視覚的に表す
        local alpha = settings.GetVisible(key) and 1.0 or 0.35
        if sRows[key] and sRows[key].lbl and sRows[key].lbl.style then
            sRows[key].lbl.style:SetColor(col[1], col[2], col[3], alpha)
        end
    end)

    -- ---- チャンネル名ラベル ----
    local lbl = win:CreateChildWidget("label", "jpchatSP_lbl_" .. key, 0, true)
    lbl:SetExtent(80, ROW_H)
    lbl:AddAnchor("TOPLEFT", win, COL_LABEL, yOffset)
    lbl:SetText(key)
    local labelAlpha = settings.GetVisible(key) and 1.0 or 0.35
    if lbl.style then
        lbl.style:SetAlign(ALIGN.LEFT)
        lbl.style:SetColor(col[1], col[2], col[3], labelAlpha)
    end

    -- ---- R / G / B 入力欄 ----
    local eR = MakeColorEdit("jpchatSP_r_" .. key, win, col[1])
    eR:AddAnchor("TOPLEFT", win, COL_R, yOffset + 3)
    local eG = MakeColorEdit("jpchatSP_g_" .. key, win, col[2])
    eG:AddAnchor("TOPLEFT", win, COL_G, yOffset + 3)
    local eB = MakeColorEdit("jpchatSP_b_" .. key, win, col[3])
    eB:AddAnchor("TOPLEFT", win, COL_B, yOffset + 3)

    -- ---- プレビュー（色付き矩形）----
    local preview = win:CreateChildWidget("label", "jpchatSP_prev_" .. key, 0, true)
    preview:SetExtent(30, ROW_H - 4)
    preview:AddAnchor("TOPLEFT", win, COL_PREVIEW, yOffset + 2)
    preview:SetText("  ")
    local prevBg = preview:CreateColorDrawable(col[1], col[2], col[3], 1, "background")
    prevBg:AddAnchor("TOPLEFT",     preview, 0, 0)
    prevBg:AddAnchor("BOTTOMRIGHT", preview, 0, 0)

    -- ---- Apply ボタン ----
    local btnApply = win:CreateChildWidget("button", "jpchatSP_apply_" .. key, 0, true)
    btnApply:SetExtent(50, ROW_H - 2)
    btnApply:AddAnchor("TOPLEFT", win, COL_APPLY, yOffset + 1)
    btnApply:SetText("適用")
    btnApply:SetHandler("OnClick", function()
        local r = ParseFloat(eR:GetText())
        local g = ParseFloat(eG:GetText())
        local b = ParseFloat(eB:GetText())
        if r == nil or g == nil or b == nil then
            api.Log:Err("[jpchat] 色の値は 0.00〜1.00 で入力してください")
            return
        end
        settings.SetColor(key, r, g, b, 1)
        settings.Save()
        -- ラベル色とプレビューを更新（visible の alpha を維持）
        local alpha = settings.GetVisible(key) and 1.0 or 0.35
        if lbl.style then lbl.style:SetColor(r, g, b, alpha) end
        prevBg:SetColor(r, g, b, 1)
        -- メインウィンドウの色を再描画
        if onChanged then onChanged() end
        -- col を最新値に同期（チェックボタンの OnClick が参照するため）
        col = settings.GetColor(key)
    end)

    -- ---- Reset ボタン ----
    local btnReset = win:CreateChildWidget("button", "jpchatSP_reset_" .. key, 0, true)
    btnReset:SetExtent(44, ROW_H - 2)
    btnReset:AddAnchor("TOPLEFT", win, COL_RESET, yOffset + 1)
    btnReset:SetText("初期化")
    btnReset:SetHandler("OnClick", function()
        settings.Reset(key)
        settings.Save()
        local c = settings.GetColor(key)
        eR:SetText(string.format("%.2f", c[1]))
        eG:SetText(string.format("%.2f", c[2]))
        eB:SetText(string.format("%.2f", c[3]))
        local alpha = settings.GetVisible(key) and 1.0 or 0.35
        if lbl.style then lbl.style:SetColor(c[1], c[2], c[3], alpha) end
        prevBg:SetColor(c[1], c[2], c[3], 1)
        if onChanged then onChanged() end
        col = settings.GetColor(key)
    end)

    sRows[key] = { lbl = lbl, chk = chk, eR = eR, eG = eG, eB = eB, prevBg = prevBg }
end

-- ============================================================================
-- 公開 API
-- ============================================================================

function M.Init(settingsModule, refreshCallback, opacityCallback, fontSizeCallback, raidPosCallback, raidPreviewCallback)
    settings           = settingsModule
    onChanged          = refreshCallback
    onOpacityChanged   = opacityCallback
    onFontSizeChanged  = fontSizeCallback
    onRaidPosChanged   = raidPosCallback
    onRaidPreview      = raidPreviewCallback
end

function M.Open()
    if win then
        win:Show(not win:IsVisible())
        return
    end

    local keys   = settings.GetAllKeys()
    -- チャンネル行 + 透過率行 + フォントサイズ行 + RaidLeader位置行 の合計高さ
    local totalH = PADDING + #keys * (ROW_H + 4) + (ROW_H + 8) * 3 + PADDING + 30

    win = api.Interface:CreateEmptyWindow("jpchatSettingsWin")
    win:SetExtent(WIN_W, totalH)
    win:AddAnchor("CENTER", "UIParent", "CENTER", 0, 0)
    win:Show(true)

    -- 背景（透過率を設定値と同期）
    local opacity = settings.GetOpacity()
    local spBg = win:CreateColorDrawable(0.06, 0.06, 0.10, opacity, "background")
    spBg:AddAnchor("TOPLEFT",     win, 0, 0)
    spBg:AddAnchor("BOTTOMRIGHT", win, 0, 0)

    -- タイトルバー
    local titleLbl = win:CreateChildWidget("label", "jpchatSP_title", 0, true)
    titleLbl:SetText("JP Chat - 設定")
    titleLbl:SetExtent(WIN_W - 40, 20)
    titleLbl:AddAnchor("TOPLEFT", win, PADDING, 6)
    if titleLbl.style then
        titleLbl.style:SetAlign(ALIGN.LEFT)
        titleLbl.style:SetColor(0.9, 0.9, 1.0, 1)
    end

    -- 列ヘッダ
    local function MakeHeader(id, text, x, w)
        local h = win:CreateChildWidget("label", id, 0, true)
        h:SetText(text)
        h:SetExtent(w or 50, 16)
        h:AddAnchor("TOPLEFT", win, x, 26)
        if h.style then
            h.style:SetAlign(ALIGN.LEFT)
            h.style:SetColor(0.6, 0.6, 0.6, 1)
        end
    end
    MakeHeader("jpchatSP_hShow",  "",        COL_CHECK,   26)
    MakeHeader("jpchatSP_hCh",    "チャンネル", COL_LABEL,   80)
    MakeHeader("jpchatSP_hR",     "R",       COL_R,       44)
    MakeHeader("jpchatSP_hG",     "G",       COL_G,       44)
    MakeHeader("jpchatSP_hB",     "B",       COL_B,       44)
    MakeHeader("jpchatSP_hPrev",  "色",      COL_PREVIEW, 50)

    -- 閉じるボタン
    local btnClose = win:CreateChildWidget("button", "jpchatSP_close", 0, true)
    btnClose:SetExtent(26, 20)
    btnClose:AddAnchor("TOPRIGHT", win, -4, 4)
    btnClose:SetText("X")
    btnClose:SetHandler("OnClick", function() win:Show(false) end)

    -- Shift+ドラッグで移動
    titleLbl:EnableDrag(true)
    titleLbl:SetHandler("OnDragStart", function()
        if api.Input:IsShiftKeyDown() then win:StartMoving() end
    end)
    titleLbl:SetHandler("OnDragStop", function()
        win:StopMovingOrSizing()
    end)

    -- 各チャンネル行
    local y = PADDING + 38
    for _, key in ipairs(keys) do
        BuildRow(key, y)
        y = y + ROW_H + 4
    end

    -- ============================================================================
    -- 透過率設定行
    -- ============================================================================
    y = y + 4

    -- 区切り線
    local sep = win:CreateColorDrawable(0.4, 0.4, 0.4, 0.6, "background")
    sep:SetExtent(WIN_W - PADDING * 2, 1)
    sep:AddAnchor("TOPLEFT", win, PADDING, y)
    y = y + 6

    -- ラベル
    local opLbl = win:CreateChildWidget("label", "jpchatSP_opLbl", 0, true)
    opLbl:SetExtent(80, ROW_H)
    opLbl:AddAnchor("TOPLEFT", win, PADDING, y)
    opLbl:SetText("透過率")
    if opLbl.style then
        opLbl.style:SetAlign(ALIGN.LEFT)
        opLbl.style:SetColor(0.8, 0.8, 0.8, 1)
    end

    -- 数値入力欄（0.10〜1.00）
    local eOp = MakeColorEdit("jpchatSP_op", win, settings.GetOpacity())
    eOp:AddAnchor("TOPLEFT", win, 85, y + 3)

    -- 説明ラベル
    local opHint = win:CreateChildWidget("label", "jpchatSP_opHint", 0, true)
    opHint:SetExtent(120, ROW_H)
    opHint:AddAnchor("TOPLEFT", win, 135, y)
    opHint:SetText("(0.10 - 1.00)")
    if opHint.style then
        opHint.style:SetAlign(ALIGN.LEFT)
        opHint.style:SetColor(0.5, 0.5, 0.5, 1)
    end

    -- Apply ボタン
    local btnOpApply = win:CreateChildWidget("button", "jpchatSP_opApply", 0, true)
    btnOpApply:SetExtent(50, ROW_H - 2)
    btnOpApply:AddAnchor("TOPLEFT", win, COL_APPLY, y + 1)
    btnOpApply:SetText("適用")
    btnOpApply:SetHandler("OnClick", function()
        local v = ParseOpacity(eOp:GetText())
        if v == nil then
            api.Log:Err("[jpchat] 透過率は 0.10〜1.00 で入力してください")
            return
        end
        if onOpacityChanged then onOpacityChanged(v) end
        -- 設定画面の背景も更新
        if spBg then spBg:SetColor(0.06, 0.06, 0.10, v) end
        eOp:SetText(string.format("%.2f", v))
    end)

    -- Reset ボタン
    local btnOpReset = win:CreateChildWidget("button", "jpchatSP_opReset", 0, true)
    btnOpReset:SetExtent(44, ROW_H - 2)
    btnOpReset:AddAnchor("TOPLEFT", win, COL_RESET, y + 1)
    btnOpReset:SetText("初期化")
    btnOpReset:SetHandler("OnClick", function()
        local def = settings.GetDefaultOpacity()
        eOp:SetText(string.format("%.2f", def))
        if onOpacityChanged then onOpacityChanged(def) end
        -- 設定画面の背景も更新
        if spBg then spBg:SetColor(0.06, 0.06, 0.10, def) end
    end)

    -- ============================================================================
    -- フォントサイズ設定行
    -- ============================================================================
    y = y + ROW_H + 8

    -- ラベル
    local fsLbl = win:CreateChildWidget("label", "jpchatSP_fsLbl", 0, true)
    fsLbl:SetExtent(80, ROW_H)
    fsLbl:AddAnchor("TOPLEFT", win, PADDING, y)
    fsLbl:SetText("文字サイズ")
    if fsLbl.style then
        fsLbl.style:SetAlign(ALIGN.LEFT)
        fsLbl.style:SetColor(0.8, 0.8, 0.8, 1)
    end

    -- 数値入力欄
    local eFs = MakeColorEdit("jpchatSP_fs", win, settings.GetFontSize())
    eFs:AddAnchor("TOPLEFT", win, 85, y + 3)

    -- 説明ラベル
    local fsHint = win:CreateChildWidget("label", "jpchatSP_fsHint", 0, true)
    fsHint:SetExtent(130, ROW_H)
    fsHint:AddAnchor("TOPLEFT", win, 135, y)
    fsHint:SetText("(11, 13, 15, 18, 22)")
    if fsHint.style then
        fsHint.style:SetAlign(ALIGN.LEFT)
        fsHint.style:SetColor(0.5, 0.5, 0.5, 1)
    end

    -- Apply ボタン
    local btnFsApply = win:CreateChildWidget("button", "jpchatSP_fsApply", 0, true)
    btnFsApply:SetExtent(50, ROW_H - 2)
    btnFsApply:AddAnchor("TOPLEFT", win, COL_APPLY, y + 1)
    btnFsApply:SetText("適用")
    btnFsApply:SetHandler("OnClick", function()
        local v = tonumber(eFs:GetText())
        if v == nil then
            api.Log:Err("[jpchat] フォントサイズは数値で入力してください")
            return
        end
        if onFontSizeChanged then onFontSizeChanged(v) end
        eFs:SetText(tostring(v))
    end)

    -- Reset ボタン
    local btnFsReset = win:CreateChildWidget("button", "jpchatSP_fsReset", 0, true)
    btnFsReset:SetExtent(44, ROW_H - 2)
    btnFsReset:AddAnchor("TOPLEFT", win, COL_RESET, y + 1)
    btnFsReset:SetText("初期化")
    btnFsReset:SetHandler("OnClick", function()
        local def = settings.GetDefaultFontSize()
        eFs:SetText(tostring(def))
        if onFontSizeChanged then onFontSizeChanged(def) end
    end)

    -- ============================================================================
    -- RaidLeaderオーバーレイ位置設定行
    -- ============================================================================
    y = y + ROW_H + 8

    -- ラベル
    local rpLbl = win:CreateChildWidget("label", "jpchatSP_rpLbl", 0, true)
    rpLbl:SetExtent(90, ROW_H)
    rpLbl:AddAnchor("TOPLEFT", win, PADDING, y)
    rpLbl:SetText("RL表示位置")
    if rpLbl.style then
        rpLbl.style:SetAlign(ALIGN.LEFT)
        rpLbl.style:SetColor(0.8, 0.8, 0.8, 1)
    end

    local curX, curY = settings.GetRaidPos()

    -- X 入力欄
    local eRX = W_CTRL.CreateEdit("jpchatSP_rpX", win)
    eRX:SetExtent(50, 18)
    eRX:SetText(tostring(curX))
    eRX:AddAnchor("TOPLEFT", win, 105, y + 3)

    -- Y 入力欄
    local eRY = W_CTRL.CreateEdit("jpchatSP_rpY", win)
    eRY:SetExtent(50, 18)
    eRY:SetText(tostring(curY))
    eRY:AddAnchor("TOPLEFT", win, 160, y + 3)

    -- 説明ラベル
    local rpHint = win:CreateChildWidget("label", "jpchatSP_rpHint", 0, true)
    rpHint:SetExtent(70, ROW_H)
    rpHint:AddAnchor("TOPLEFT", win, 215, y)
    rpHint:SetText("(X, Y)")
    if rpHint.style then
        rpHint.style:SetAlign(ALIGN.LEFT)
        rpHint.style:SetColor(0.5, 0.5, 0.5, 1)
    end

    -- プレビューボタン（COL_PREVIEW付近）
    local btnRpPrev = win:CreateChildWidget("button", "jpchatSP_rpPrev", 0, true)
    btnRpPrev:SetExtent(44, ROW_H - 2)
    btnRpPrev:AddAnchor("TOPLEFT", win, COL_PREVIEW - 8, y + 1)
    btnRpPrev:SetText("確認")
    btnRpPrev:SetHandler("OnClick", function()
        -- 現在入力中の位置を一時適用してプレビュー表示
        local vx = tonumber(eRX:GetText())
        local vy = tonumber(eRY:GetText())
        if vx and vy and onRaidPosChanged then onRaidPosChanged(vx, vy) end
        if onRaidPreview then onRaidPreview() end
    end)

    -- Apply ボタン
    local btnRpApply = win:CreateChildWidget("button", "jpchatSP_rpApply", 0, true)
    btnRpApply:SetExtent(50, ROW_H - 2)
    btnRpApply:AddAnchor("TOPLEFT", win, COL_APPLY, y + 1)
    btnRpApply:SetText("適用")
    btnRpApply:SetHandler("OnClick", function()
        local vx = tonumber(eRX:GetText())
        local vy = tonumber(eRY:GetText())
        if vx == nil or vy == nil then
            api.Log:Err("[jpchat] 位置は数値で入力してください")
            return
        end
        settings.SetRaidPos(vx, vy)
        settings.Save()
        if onRaidPosChanged then onRaidPosChanged(vx, vy) end
        if onRaidPreview then onRaidPreview() end
    end)

    -- Reset ボタン
    local btnRpReset = win:CreateChildWidget("button", "jpchatSP_rpReset", 0, true)
    btnRpReset:SetExtent(44, ROW_H - 2)
    btnRpReset:AddAnchor("TOPLEFT", win, COL_RESET, y + 1)
    btnRpReset:SetText("初期化")
    btnRpReset:SetHandler("OnClick", function()
        local dx, dy = settings.GetDefaultRaidPos()
        settings.SetRaidPos(dx, dy)
        settings.Save()
        eRX:SetText(tostring(dx))
        eRY:SetText(tostring(dy))
        if onRaidPosChanged then onRaidPosChanged(dx, dy) end
        if onRaidPreview then onRaidPreview() end
    end)
end

function M.Shutdown()
    if win then
        win:Show(false)
        api.Interface:Free(win)
        win   = nil
        sRows = {}
    end
end

return M
