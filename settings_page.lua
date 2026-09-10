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
local onRaidAdjustStart = nil -- RaidLeader位置調整モード開始（ui.StartRaidOverlayAdjust）
local onRaidAdjustStop  = nil -- RaidLeader位置調整モード終了（ui.StopRaidOverlayAdjust）
local onRaidReset       = nil -- RaidLeader位置を初期化（設定リセット＋ui.RefreshRaidOverlayPos）
local getParent         = nil -- 親ウィジェット（メインウィンドウ）供給コールバック
local raidAdjusting     = false -- 位置調整モード中フラグ（トグルボタンの表示切替用）
local palettePopup      = nil -- カラーパレットのポップアップ（win の子。初回のみ生成し使い回す）
local paletteTargetKey  = nil -- パレットで選んだ色を反映する対象チャンネルキー

-- 共通「適用」ボタンから呼ぶ、透過率・フォントサイズの適用処理。
-- M.Open 内で本体を代入する。入力が不正なら false を返しスキップ（Save はしない）。
local applyOpacity      = nil
local applyFontSize     = nil

-- ============================================================================
-- カラーパレット（ゲーム内パレットに準拠。16列 × 6行 = 96色）
-- ============================================================================
-- 画像の各セル中央付近の色を近似で拾った 16進コード（RRGGBB）。
-- 行構成: 1=淡色, 2=鮮やか, 3=やや暗い, 4=暗い, 5=暗色+灰, 6=最暗色+白黒。
local PALETTE_COLS = 16
local PALETTE_ROWS = 6
-- 実機のカラーパレットをマウスオーバーで実測した値（左上から右へ index 1..96）。
local PALETTE_HEX  = {
    -- 1行目
    "F7987B","FAAE82","FEC68A","FFF89A","C5E09C","A3D49D","83CB9D","7CCDC9",
    "6FD0F7","7FA8D9","8594CB","8983BF","A288BF","BD8DC0","F59BC3","F6999E",
    -- 2行目
    "F36D4F","F78F56","FCB05D","FFF568","ACD473","7DC677","3CB9FF","1BBCB5",
    "01C0F4","448DCB","5675BA","615DA9","8660A9","A864A9","F16FAA","F36E7D",
    -- 3行目
    "FF0B15","FF6116","FF9516","FFF201","96FF07","01EF22","01A751","01AA9D",
    "01AEF0","0173BD","5655A7","0105C1","6D01BE","BA01B4","ED018C","FF0355",
    -- 4行目
    "9E0B10","A1420E","A4630A","ACA101","5A8628","1B7B31","017337","01746C",
    "0177A4","014C81","013572","1C1565","450F63","640561","9F015E","9E013A",
    -- 5行目
    "7A0101","7C2F01","7E4A01","837B01","416719","015F21","015927","015A53",
    "015C80","013764","012258","0E014D","33014C","4C014A","7C0147","7A0127",
    -- 6行目
    "C8B39A","998776","746358","544842","37302E","C69D6E","A77D53","8D633A",
    "764D25","613A14","FFFFFF","C3C3C3","969696","474747","262626","010101",
}

-- 16進(RRGGBB)を {r, g, b}(0.0-1.0) に変換する
local function HexToRgb(hex)
    local r = tonumber(hex:sub(1, 2), 16) or 0
    local g = tonumber(hex:sub(3, 4), 16) or 0
    local b = tonumber(hex:sub(5, 6), 16) or 0
    return { r / 255, g / 255, b / 255 }
end

-- 正規化済みパレット（{r, g, b} の配列。読み込み時に1回だけ生成）
local PALETTE = {}
for i, hex in ipairs(PALETTE_HEX) do
    PALETTE[i] = HexToRgb(hex)
end

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
-- カラーパレット ポップアップ
-- ============================================================================

local PAL_CELL   = 22   -- 1色セルの1辺(px)
local PAL_GAP    = 1    -- セル間の隙間(px)
local PAL_MARGIN = 8    -- パレット内側の余白(px)
local PAL_HEADER = 22   -- ヘッダー(閉じるボタン)の高さ(px)

-- パレットを閉じる
local function ClosePalette()
    if palettePopup then palettePopup:Show(false) end
    paletteTargetKey = nil
end

-- パレットのポップアップを初回のみ生成する（win の子ウィジェット）。
-- トップレベルウィンドウを増やさないため、設定ウィンドウの子として作る。
local function EnsurePalettePopup()
    if palettePopup ~= nil then return end
    if win == nil then return end

    local gridW = PALETTE_COLS * PAL_CELL + (PALETTE_COLS - 1) * PAL_GAP
    local gridH = PALETTE_ROWS * PAL_CELL + (PALETTE_ROWS - 1) * PAL_GAP
    local popW  = gridW + PAL_MARGIN * 2
    local popH  = gridH + PAL_MARGIN * 2 + PAL_HEADER

    palettePopup = win:CreateChildWidget("emptywidget", "jpchatSP_palette", 0, true)
    palettePopup:SetExtent(popW, popH)
    palettePopup:AddAnchor("CENTER", win, "CENTER", 0, 0)

    -- 背景（不透明寄り。モーダル風）
    local bg = palettePopup:CreateColorDrawable(0.06, 0.06, 0.10, 0.98, "background")
    bg:AddAnchor("TOPLEFT",     palettePopup, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", palettePopup, 0, 0)

    -- 閉じるボタン（右上）
    local btnClose = palettePopup:CreateChildWidget("button", "jpchatSP_palClose", 0, true)
    btnClose:SetExtent(20, 18)
    btnClose:AddAnchor("TOPRIGHT", palettePopup, -4, -2)
    btnClose:SetText("X")
    btnClose:SetHandler("OnClick", function() ClosePalette() end)

    -- 色セル（16 x 6）。クリックで対象行の RGB 入力欄へ反映して閉じる
    for idx = 1, #PALETTE do
        local ci  = idx                       -- ループ変数をローカルにキャプチャ
        local col = PALETTE[ci]
        local row = math.floor((idx - 1) / PALETTE_COLS)
        local coln = (idx - 1) % PALETTE_COLS
        local cx = PAL_MARGIN + coln * (PAL_CELL + PAL_GAP)
        local cy = PAL_HEADER + PAL_MARGIN + row * (PAL_CELL + PAL_GAP)

        local cell = palettePopup:CreateChildWidget("button", "jpchatSP_pal_" .. ci, 0, true)
        cell:SetExtent(PAL_CELL, PAL_CELL)
        cell:AddAnchor("TOPLEFT", palettePopup, cx, cy)
        cell:SetText("")
        local cellBg = cell:CreateColorDrawable(col[1], col[2], col[3], 1, "background")
        cellBg:AddAnchor("TOPLEFT",     cell, 0, 0)
        cellBg:AddAnchor("BOTTOMRIGHT", cell, 0, 0)

        cell:SetHandler("OnClick", function()
            local key = paletteTargetKey
            if key and sRows[key] and sRows[key].setColor then
                sRows[key].setColor(col[1], col[2], col[3])
            end
            ClosePalette()
        end)
    end

    palettePopup:Show(false)   -- 生成直後は隠しておく
end

-- 指定行(key)を対象にパレットを開く
local function OpenPaletteFor(key)
    EnsurePalettePopup()
    if palettePopup == nil then return end
    paletteTargetKey = key
    palettePopup:Show(true)
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

    -- ---- プレビュー（色付き矩形。クリックでカラーパレットを開く）----
    -- クリックを確実に拾うため button で作り、色見本を全面に敷く
    local preview = win:CreateChildWidget("button", "jpchatSP_prev_" .. key, 0, true)
    preview:SetExtent(30, ROW_H - 4)
    preview:AddAnchor("TOPLEFT", win, COL_PREVIEW, yOffset + 2)
    preview:SetText("")
    local prevBg = preview:CreateColorDrawable(col[1], col[2], col[3], 1, "background")
    prevBg:AddAnchor("TOPLEFT",     preview, 0, 0)
    prevBg:AddAnchor("BOTTOMRIGHT", preview, 0, 0)
    preview:SetHandler("OnClick", function()
        OpenPaletteFor(key)
    end)

    -- ---- 色の適用処理（共通「適用」ボタンから呼ばれる）----
    -- 入力が不正な場合は何もせず false を返す（スキップ）。Save は呼ばない
    -- （共通「適用」側で最後にまとめて1回だけ保存する）。
    local function applyColor()
        local r = ParseFloat(eR:GetText())
        local g = ParseFloat(eG:GetText())
        local b = ParseFloat(eB:GetText())
        if r == nil or g == nil or b == nil then
            api.Log:Err("[jpchat] 色の値は 0.00〜1.00 で入力してください: " .. key)
            return false
        end
        settings.SetColor(key, r, g, b, 1)
        -- ラベル色とプレビューを更新（visible の alpha を維持）
        local alpha = settings.GetVisible(key) and 1.0 or 0.35
        if lbl.style then lbl.style:SetColor(r, g, b, alpha) end
        prevBg:SetColor(r, g, b, 1)
        -- col を最新値に同期（チェックボタンの OnClick が参照するため）
        col = settings.GetColor(key)
        return true
    end

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

    -- ---- パレットで選んだ色を入力欄とプレビューへ反映する（保存は共通「適用」で）----
    local function setColor(r, g, b)
        eR:SetText(string.format("%.2f", r))
        eG:SetText(string.format("%.2f", g))
        eB:SetText(string.format("%.2f", b))
        prevBg:SetColor(r, g, b, 1)
    end

    sRows[key] = {
        lbl = lbl, chk = chk, eR = eR, eG = eG, eB = eB, prevBg = prevBg,
        apply = applyColor, setColor = setColor,
    }
end

-- ============================================================================
-- 公開 API
-- ============================================================================

function M.Init(settingsModule, refreshCallback, opacityCallback, fontSizeCallback,
                raidAdjustStartCallback, raidAdjustStopCallback, raidResetCallback, parentProvider)
    settings            = settingsModule
    onChanged           = refreshCallback
    onOpacityChanged    = opacityCallback
    onFontSizeChanged   = fontSizeCallback
    onRaidAdjustStart   = raidAdjustStartCallback
    onRaidAdjustStop    = raidAdjustStopCallback
    onRaidReset         = raidResetCallback
    getParent           = parentProvider
end

-- 設定ウィンドウを閉じる/破棄する前のクリーンアップ。
-- 位置調整モードを終了し、開いているカラーパレットも閉じる。
local function StopAdjustIfNeeded()
    if raidAdjusting then
        raidAdjusting = false
        if onRaidAdjustStop then onRaidAdjustStop() end
    end
    ClosePalette()
end

function M.Open()
    if win then
        local willShow = not win:IsVisible()
        win:Show(willShow)
        if not willShow then StopAdjustIfNeeded() end   -- 閉じるときは調整モードも止める
        return
    end

    local keys   = settings.GetAllKeys()
    -- チャンネル行 + 透過率行 + フォントサイズ行 + RaidLeader位置行 + 共通適用ボタン行 の合計高さ
    local totalH = PADDING + #keys * (ROW_H + 4) + (ROW_H + 8) * 4 + PADDING + 30

    -- リファレンス指針: トップレベルウィンドウ（CreateEmptyWindow）を増やさない。
    -- 設定ウィンドウはメインウィンドウの子ウィジェットとして生成し、以後は
    -- Show(true/false) で使い回す（子は Rendered Windows にカウントされない）。
    local parent = getParent and getParent() or nil
    if parent == nil then
        api.Log:Err("[jpchat] 設定ウィンドウの親が取得できませんでした")
        return
    end

    win = parent:CreateChildWidget("emptywidget", "jpchatSettingsWin", 0, true)
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
    btnClose:SetHandler("OnClick", function()
        win:Show(false)
        StopAdjustIfNeeded()   -- 閉じるときは調整モードも止める
    end)

    -- Shift+ドラッグで移動（子ウィジェットでは効かない環境があるため pcall で保護）
    titleLbl:EnableDrag(true)
    titleLbl:SetHandler("OnDragStart", function()
        if api.Input:IsShiftKeyDown() then
            pcall(function() win:StartMoving() end)
        end
    end)
    titleLbl:SetHandler("OnDragStop", function()
        pcall(function() win:StopMovingOrSizing() end)
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

    -- 透過率の適用処理（共通「適用」ボタンから呼ばれる）。Save はしない。
    applyOpacity = function()
        local v = ParseOpacity(eOp:GetText())
        if v == nil then
            api.Log:Err("[jpchat] 透過率は 0.10〜1.00 で入力してください")
            return false
        end
        if onOpacityChanged then onOpacityChanged(v) end
        -- 設定画面の背景も更新
        if spBg then spBg:SetColor(0.06, 0.06, 0.10, v) end
        eOp:SetText(string.format("%.2f", v))
        return true
    end

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

    -- フォントサイズの適用処理（共通「適用」ボタンから呼ばれる）。Save はしない。
    applyFontSize = function()
        local v = tonumber(eFs:GetText())
        if v == nil then
            api.Log:Err("[jpchat] フォントサイズは数値で入力してください")
            return false
        end
        if onFontSizeChanged then onFontSizeChanged(v) end
        eFs:SetText(tostring(v))
        return true
    end

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

    -- 説明ラベル（操作方法の案内）
    local rpHint = win:CreateChildWidget("label", "jpchatSP_rpHint", 0, true)
    rpHint:SetExtent(160, ROW_H)
    rpHint:AddAnchor("TOPLEFT", win, 105, y)
    rpHint:SetText("Shift+ドラッグで移動")
    if rpHint.style then
        rpHint.style:SetAlign(ALIGN.LEFT)
        rpHint.style:SetColor(0.5, 0.5, 0.5, 1)
    end

    -- 位置調整トグルボタン: オン中はサンプルを出しっぱなしにして Shift+ドラッグで移動
    raidAdjusting = false
    local btnRpAdjust = win:CreateChildWidget("button", "jpchatSP_rpAdjust", 0, true)
    btnRpAdjust:SetExtent(64, ROW_H - 2)
    btnRpAdjust:AddAnchor("TOPLEFT", win, COL_APPLY - 14, y + 1)
    btnRpAdjust:SetText("位置調整")
    btnRpAdjust:SetHandler("OnClick", function()
        raidAdjusting = not raidAdjusting
        if raidAdjusting then
            btnRpAdjust:SetText("調整終了")
            if onRaidAdjustStart then onRaidAdjustStart() end
        else
            btnRpAdjust:SetText("位置調整")
            if onRaidAdjustStop then onRaidAdjustStop() end
        end
    end)

    -- Reset ボタン: 位置を既定に戻して貼り直す
    local btnRpReset = win:CreateChildWidget("button", "jpchatSP_rpReset", 0, true)
    btnRpReset:SetExtent(44, ROW_H - 2)
    btnRpReset:AddAnchor("TOPLEFT", win, COL_RESET, y + 1)
    btnRpReset:SetText("初期化")
    btnRpReset:SetHandler("OnClick", function()
        if onRaidReset then onRaidReset() end
    end)

    -- ============================================================================
    -- 共通「適用」ボタン（色・透過率・フォントサイズをまとめて適用）
    -- ============================================================================
    y = y + ROW_H + 8

    local btnApplyAll = win:CreateChildWidget("button", "jpchatSP_applyAll", 0, true)
    btnApplyAll:SetExtent(120, ROW_H)
    btnApplyAll:AddAnchor("TOP", win, "TOP", 0, y)
    btnApplyAll:SetText("適用")
    btnApplyAll:SetHandler("OnClick", function()
        -- 各項目を順に適用する。入力が不正な項目は各 apply 内で false を返して
        -- スキップされる（正しい項目だけ反映される）。
        for _, k in ipairs(settings.GetAllKeys()) do
            local row = sRows[k]
            if row and row.apply then row.apply() end
        end
        if applyOpacity  then applyOpacity()  end
        if applyFontSize then applyFontSize() end

        -- メインウィンドウの色を再描画（色変更の反映）
        if onChanged then onChanged() end

        -- 変更をまとめて1回だけ保存する
        settings.Save()
    end)
end

function M.Shutdown()
    -- 位置調整モードが残っていれば止めておく（フラグ整合のため）
    raidAdjusting = false

    -- 設定ウィンドウはメインウィンドウの子。メインウィンドウ（親）を Free すると
    -- 一緒に解放されるため、ここでは個別 Free せず参照を手放すだけにする。
    -- パレットも win の子なので参照を手放すだけでよい（次回 Open 時に再生成される）。
    if win then
        pcall(function() win:Show(false) end)
    end
    win              = nil
    sRows            = {}
    palettePopup     = nil
    paletteTargetKey = nil
end

return M
