# jpchat — ArcheAge Classic チャット翻訳アドオン

ゲーム内のチャットメッセージをリアルタイムで日本語に翻訳して、専用ウィンドウに表示するアドオンです。

---

## ファイル構成

```
Addon/
└── jpchat/
    ├── addon.lua               # エントリーポイント（ゲームが読み込む）
    ├── main.lua                # チャット受信・ファイル連携のメインロジック
    ├── ui.lua                  # 翻訳結果表示ウィンドウ
    ├── settings.lua            # 設定管理
    ├── settings_page.lua       # 設定画面UI
    ├── npc_list.lua            # NPC名リスト（Git共有管理）
    ├── dictionary.txt          # 辞書ファイル（Git共有管理）
    ├── JpChatTranslator.exe    # 翻訳エンジン（単体実行ファイル）
    ├── JpChatLlm.dll           # ローカルLLM推論エンジン（Vulkan GPU対応）
    ├── deepl_api_key.txt       # DeepL APIキー（自動生成、Git管理外）
    ├── llm_settings.txt        # ローカルLLM設定（自動生成、Git管理外）
    ├── heartbeat.lua           # 翻訳エンジン状態（自動生成、Git管理外）
    ├── input.lua               # Lua→翻訳エンジン 通信ファイル（自動生成）
    └── output.lua              # 翻訳エンジン→Lua 通信ファイル（自動生成）
```

---

## セットアップ

### 1. アドオンの配置

`jpchat` フォルダごと `Documents/AAClassic/Addon/` にコピーします。

```
Documents/
└── AAClassic/
    └── Addon/
        ├── addons.txt   ← "jpchat" の1行を追記
        └── jpchat/
```

`addons.txt` に以下を追記してください。

```
jpchat
```

### 2. 翻訳エンジンの起動

ゲームを起動する**前または後**に、`JpChatTranslator.exe` をダブルクリックして起動します。

GUIウィンドウが表示されれば起動成功です。  
このウィンドウはゲーム中は開いたままにしてください。

> **追加インストールは不要です。** Python や .NET のインストールは必要ありません。

### 3. ゲームを起動

キャラクター選択画面の「Addons」ボタンから `jpchat` が有効になっていることを確認します。

---

## 翻訳モード

### Google 翻訳（デフォルト）
- APIキー不要、無料
- レート制限あり（短時間に大量リクエストでブロックされる場合がある）

### DeepL 翻訳
- 高精度な翻訳
- APIキーが必要（無料プランあり: https://www.deepl.com/pro-api）

#### DeepL の設定方法

以下のいずれかの方法で APIキーを設定してください。

**方法A: ファイル**
1. `jpchat` フォルダに `deepl_api_key.txt` を作成
2. 中に APIキーを1行で記入

**方法B: 環境変数（OneDrive環境で推奨）**
1. Windowsキー → 「環境変数」と検索 → 「システム環境変数の編集」
2. 「環境変数」→ ユーザー環境変数の「新規」
3. 変数名: `DEEPL_API_KEY`、変数値: APIキー
4. OK → exe を再起動

GUIウィンドウ上部の「Google」「DeepL」ボタンでモードを切り替えられます。

### ローカルLLM 翻訳
- インターネット不要、完全オフラインで翻訳
- プライバシー重視（テキストが外部に送信されない）
- Vulkan 対応で NVIDIA / AMD / Intel GPU をサポート
- `JpChatLlm.dll` による内蔵推論（外部アプリ不要）

#### ローカルLLM のセットアップ

##### 1. 翻訳用モデルのダウンロード

GGUF 形式のモデルを用意します。

**推奨モデル: Qwen2.5-7B-Instruct Q4_K_M**

1. 以下のページにアクセス:  
   https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF
2. 「Files and versions」タブから **Q4_K_M** をダウンロード（約4.5GB）
3. 任意のフォルダに保存（例: `E:\LLM\qwen2.5-7b-instruct-q4_k_m.gguf`）

| モデル | サイズ | 推奨環境 |
|--------|--------|----------|
| Qwen2.5-7B-Instruct Q4_K_M | ~4.5GB | dGPU（推奨） |
| Qwen2.5-14B-Instruct Q4_K_M | ~8.5GB | VRAM 16GB以上 |
| Qwen2.5-3B-Instruct Q4_K_M | ~2.1GB | iGPU / CPU |

##### 2. llm_settings.txt の設定

初回起動時に `llm_settings.txt` が自動生成されます。`model_path` にダウンロードした GGUF ファイルのパスを記入してください。

```
model_path=E:\LLM\qwen2.5-7b-instruct-q4_k_m.gguf
gpu_layers=999
context_size=512
threads=0
system_prompt=Translate the following MMORPG chat message into natural Japanese. Output only the Japanese translation. Rules: Keep player names unchanged. Convert game locations to katakana. Use casual spoken Japanese. Never add explanations or notes.
send_prompt=Translate the following Japanese message into natural English for an MMORPG game chat. Output only the English translation. Use casual gamer English. Never add explanations or notes.
```

| 設定 | 説明 |
|------|------|
| `model_path` | GGUF ファイルの絶対パス |
| `gpu_layers` | GPU に載せるレイヤー数（999 = 全て GPU） |
| `context_size` | コンテキストサイズ（512 で十分） |
| `threads` | CPU スレッド数（0 = 自動検出） |
| `system_prompt` | 受信翻訳（英/韓/露→日）のプロンプト |
| `send_prompt` | 送信翻訳（日→英）のプロンプト |

##### 3. 使用方法

1. `JpChatTranslator.exe` を起動（モデルが自動ロードされる）
2. GUIウィンドウ上部の「**LLM**」ボタンをクリックしてモードを切替

> **注意:** `JpChatLlm.dll` が exe と同じフォルダに必要です。

##### パフォーマンス目安

| 環境 | モデル | チャット翻訳の応答時間 |
|------|--------|----------------------|
| RTX 3060 以上 | qwen2.5-7b | 0.5〜1.5秒 |
| RX 6800 XT | qwen2.5-7b | 0.5〜1.5秒 |
| RX 6800 XT | qwen2.5-14b | 1〜2秒 |
| CPU のみ | qwen2.5-7b | 3〜5秒 |

---

## 使い方

### 翻訳ウィンドウ

- ゲーム内に **JP Chat 翻訳** ウィンドウが表示されます
- チャットメッセージが届くと翻訳されてウィンドウに追加されます
- メッセージにマウスを乗せると**原文**がツールチップで確認できます
- **消去** ボタンで表示中のメッセージをすべて消去できます
- **隠す/表示** ボタンでリストの表示を折りたためます
- ウィンドウは **Shift+ドラッグ** で移動、右下の **◢** でリサイズ可能です
- ウィンドウの位置・サイズは自動保存されます

### 日本語→英語 翻訳送信

- ウィンドウ下部の入力欄に日本語を入力して **Enter** または **翻訳** ボタンを押す
- 英語に翻訳されクリップボードにコピーされます
- ゲーム内チャット欄で **Ctrl+V** でペーストして送信してください

### 設定画面

**設定** ボタンから以下を変更できます:

- チャンネルごとの表示/非表示（チェックボックス）
- チャンネルごとの表示色（RGB値）
- ウィンドウ透過率（0.10〜1.00）
- 文字サイズ（11, 13, 15, 18, 22）

---

## 翻訳をスキップする条件

以下の条件に該当するメッセージは翻訳せずにそのまま表示されます:

| 条件 | 例 |
|------|------|
| `x ` で始まるメッセージ | `x cr`, `x up halcy` |
| `wts` / `wtb` で始まるメッセージ | `wts Hellkissed Shield 100g` |
| 日本語を含むメッセージ | ひらがな・カタカナが含まれる場合 |
| Family チャンネル | 全メッセージ |
| 数字のみ | `123`, `456` |
| 時間表現 | `1h`, `30m`, `5s`, `1h30m` |
| NPC名リストに登録済み | `npc_list.lua` 参照 |
| 同一人物の同一メッセージ連投 | 2回目以降スキップ |

---

## 辞書機能

`dictionary.txt` に登録した単語は翻訳前に日本語に置換されます。

```
# 形式: 英語=日本語（1行1エントリ）
halcy=ゴールド平原
cr=昼デイリー
gr=夜デイリー
mm=赤露
```

- 大文字小文字は区別しない
- 単語境界で一致する場合のみ置換（部分一致しない）
- exe を再起動すると辞書が再読み込みされる

---

## NPC名リスト

`npc_list.lua` に登録されたNPC名のメッセージは完全にスキップ（翻訳もウィンドウ表示もしない）されます。

```lua
return {
    ["Auctioneer"] = true,
    ["Guard"] = true,
}
```

このファイルはGitで共有管理されます。NPCを見つけたら追加してください。

---

## 対応チャンネル

| チャンネル | 番号 | 説明 |
|---|---|---|
| Say | 0 | 周辺チャット |
| Zone | 1 | シャウト |
| Trade | 2 | 貿易 |
| Party | 3, 4 | パーティー（送信/受信） |
| Raid | 5 | レイド |
| Nation | 6 | 国家 |
| Guild | 7 | ギルド |
| Family | 9 | 家族（翻訳スキップ） |
| RaidLeader | 10 | レイドリーダー |
| Trial | 11 | 裁判 |
| Faction | 14 | 勢力 |
| Whisper | -3, -4 | ささやき（受信/送信） |

---

## 仕組み

```
[ゲーム内チャット]
       ↓ CHAT_MESSAGE イベント (Lua)
  アイテムリンク解決 → input.lua に書き出す
       ↓ (0.3秒ごとに監視)
  JpChatTranslator.exe が読み込む
       ↓ 辞書置換 → Google/DeepL/ローカルLLM 翻訳
  output.lua に翻訳結果を書き出す
       ↓ (0.1秒ごとにポーリング)
  Lua が読み込んでUIに表示
```

---

## 翻訳エンジン（GUI）について

- ダークテーマのステータスウィンドウが表示されます
- 「Google」「DeepL」「LLM」ボタンでリアルタイムにモード切替可能
- 受信メッセージ（黄色）、翻訳結果（水色）、送信（緑）がリアルタイムで確認できます
- 翻訳数カウンターが右上に表示されます
- ウィンドウを閉じると翻訳エンジンが停止します

---

## ファイルの管理方針

| ファイル | Git管理 | 説明 |
|---|---|---|
| `npc_list.lua` | ✅ | NPC名リスト（複数人で追加・共有） |
| `dictionary.txt` | ✅ | 辞書ファイル（共有） |
| `JpChatTranslator.exe` | ✅ (LFS) | 翻訳エンジン |
| `JpChatLlm.dll` | ✅ (LFS) | LLM推論エンジン（Vulkan GPU対応） |
| `jpchat_settings.lua` | ❌ | ユーザー個別設定（初回起動時に自動生成） |
| `deepl_api_key.txt` | ❌ | APIキー（初回起動時に自動生成） |
| `llm_settings.txt` | ❌ | ローカルLLM設定（初回起動時に自動生成） |
| `heartbeat.lua` | ❌ | 翻訳エンジン状態（初回起動時に自動生成） |
| `input.lua` 等 | ❌ | 通信ファイル（自動生成） |

---

## トラブルシューティング

| 症状 | 確認事項 |
|------|---------|
| 翻訳ウィンドウが表示されない | `addons.txt` に `jpchat` が記載されているか確認 |
| 翻訳が表示されない | `JpChatTranslator.exe` が起動しているか確認 |
| exe が起動しない | Windows SmartScreen → 右クリック→プロパティ→「ブロックの解除」 |
| 「このアプリはお使いのPCでは実行できません」 | Git LFS 経由でダウンロードした場合、Releases ページから直接ダウンロード |
| DeepL が使えない | `deepl_api_key.txt` の配置か環境変数 `DEEPL_API_KEY` を確認 |
| Google 翻訳が 429 エラー | レート制限。しばらく待つか DeepL に切り替え |
| LLM 翻訳が動作しない | `JpChatLlm.dll` が exe と同じフォルダにあるか確認。`llm_settings.txt` の `model_path` を確認 |
| LLM の翻訳が遅い | `gpu_layers=999` で GPU を活用。より小型のモデルに変更 |
| 翻訳が遅い・失敗する | インターネット接続を確認（LLMモード以外） |
| アイテム名が Item#数字 で表示される | ゲーム内のアイテムデータ読み込み前に受信した場合。再ログインで改善 |

---

## 注意事項

- Google 翻訳は無料ですがレート制限があります
- DeepL は Free プランで月50万文字まで無料
- `jpchat_settings.lua` を削除すると設定が初期化されます
- アイテムリンクは `[アイテム名]` として表示されます（翻訳対象外）
