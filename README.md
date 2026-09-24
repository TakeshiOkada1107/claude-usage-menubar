# ClaudeUsage

claude.ai の「設定 > 使用量」に出るレート制限の消費率を、macOS のメニューバーに常時表示する常駐アプリ。

Anthropic とは無関係の個人製ツール（非公式）。Claude / Anthropic は Anthropic PBC の商標。

```
┌──────────────────────────┐
│ …  5h 10% · 7d 39%  🔋 🔍 │   ← メニューバー
└──────────────────────────┘
        ↓ クリック
┌────────────────────────────────┐
│ レート制限（claude.ai の使用量と同じ）  │
│   5 時間枠                   10% │
│   ▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│   あと 3 時間 20 分でリセット（19:00）│
│   7 日枠（全体）              39% │
│   ▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░ │
│   あと 4 日 2 時間でリセット（9/22） │
│ ────────────────────────────── │
│ 今日のモデル別使用量（ローカルログ集計）│
│   Opus 5                $172.12 │
│     出力 600k · 入力 1.5k · …   │
│   Sonnet 5              $100.44 │
│     出力 1.2M · 入力 3.4k · …   │
│   合計                  $272.56 │
│   ※ API 料金換算。サブスク枠の消費率とは別物 │
│ ────────────────────────────── │
│ 最終更新 12 秒前 · Opus 5 セッション │
│ 使用量ページを開く               │
│ モデル別集計を更新               │
│ ログイン時に起動              ✓  │
│ ClaudeUsage を終了              │
└────────────────────────────────┘
```

## 仕組み

```
Claude Code（セッション）
  │  画面を描くたびに statusline スクリプトを起動し、標準入力に JSON を流す。
  │  その JSON の rate_limits がサーバー側の値 = 使用量ページと同じもの
  ▼
statusline ラッパー（install.sh が設置）
  │  jq で必要な部分を切り出し、一時ファイル + mv で atomic に書き出したうえで、
  │  元の statusline コマンドへ同じ入力をそのまま渡す
  ▼
~/.claude/usage-snapshot.json
  │
  ▼
ClaudeUsage.app（Swift + Cocoa）
     2 秒ごとに mtime を見て、変わったときだけ読み直す
     5 分ごとに裏で npx ccusage を叩いてモデル別の内訳を取る
```

`rate_limits` のキーは決め打ちしていない。`five_hour` / `seven_day` のほかに
`seven_day_opus` や `spend_limit` が降ってくることがあり、将来増えることもあるため、
オブジェクトごと受け渡してアプリ側で動的に行を作る。知らないキーも落とさず表示する。

## 必要なもの

| | 用途 | 無いとどうなる |
|---|---|---|
| macOS 13 以降 | | 動かない |
| Claude Code 2.1.220 以降 | `rate_limits` が statusline に渡るバージョン | レート制限が出ない |
| `jq` | statusline での JSON 切り出し | 動かない |
| `swiftc`（Xcode Command Line Tools） | ビルド | ビルドできない |
| `npx`（Node.js） | ccusage によるモデル別集計 | レート制限は出るが、モデル別集計は出ない |

## インストール

```sh
./install.sh            # 実行前に何をするか見たいときは ./install.sh --dry-run
```

install.sh は次を行う。

1. 上の前提が揃っているか確認する
2. statusline がサイドカーを書くようにする
   - **既存の statusline スクリプトは書き換えない。** ラッパーで包み、`settings.json` の
     `statusLine.command` だけを差し替える（`type` や `padding` などのキーは保持）。
     元のコマンドは `~/.claude/claude-usage-wrapped-command` に退避し、ラッパーから呼ぶ
   - statusline が未設定なら、最小限の 1 行を出すラッパーを設定する
   - 既にサイドカーを書いている場合は何もしない（再実行しても壊れない）
3. `swiftc` でビルドし、`~/Applications` に入れて起動する（Xcode プロジェクトも sudo も不要）

`settings.json` は書き換える前に `settings.json.bak.<日時>` へバックアップされる。

## ログイン時に起動

install.sh は自動では登録しない。有効にするにはメニューの「ログイン時に起動」を選ぶか、
コマンドラインから次を実行する。

```sh
~/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --register-login-item
# 解除: --unregister-login-item / 確認: --login-item-status
```

登録はアプリ自身のプロセスからしか行えない（`SMAppService` の制約）ため、`.app` の中の
実行ファイルを直接呼ぶ。「システム設定 > 一般 > ログイン項目」にも `ClaudeUsage` として現れる。

ad-hoc 署名のままでも登録できるが、環境によっては「承認待ち」になることがある。
その場合はシステム設定で承認する。

## 表示の見方

メニューバーの％は、余裕があるうちは OS 標準の文字色（ライト / ダークで自動反転）で、
**50% を超えると橙、80% を超えると赤**になる。色が付いたら注意、という合図。
壁紙が透けるメニューバーでは彩度のある色が沈むため、平常時はあえて色を使っていない。

15 分以上更新が無いと全体が淡色になり、「Claude Code が動いていないため古い値の可能性」と表示する。

## 制約

- **レート制限は Claude Code のセッションが動いているときしか更新されない。**
  statusline が描かれたときに値が書き出される仕組みのため。claude.ai の Web で消費した分も、
  次に Claude Code が一言動けばサーバー側の値として反映される
- **モデル別集計の金額は API 料金換算であって、サブスク枠の消費率ではない。**
  ローカルログ（`~/.claude/projects/**/*.jsonl`）を ccusage が集計した値
- レート制限にモデル別の枠は無い。「Fable をどれだけ使ったか」はモデル別集計の側に出る
- ad-hoc 署名のため、他の Mac へ `.app` をそのまま配ると Gatekeeper に止められる。
  配布するときはソースを渡して `./install.sh` を実行してもらうのが早い

## セキュリティ

### このアプリがしないこと

- **認証情報を読まない。** `~/.claude/.credentials.json` をはじめ、トークンの類には一切触れない
- **ネットワークに出ない。** API も内部エンドポイントも叩かない。コード中の URL は、メニューの
  「使用量ページを開く」でブラウザに渡す 1 つだけ
- **`~/.claude` の既存ファイルを書き換えない。** 例外は `settings.json` の `statusLine.command` で、
  install.sh が変更前にバックアップを取る

表示している数値は、Claude Code が statusline に渡してくる JSON をそのまま読んだもの。

### 残存リスク

対応していないものを明示しておく。

- **`eval` を使っている**（`statusline-wrapper.sh`）。既存の statusline コマンドを呼び戻すため。
  `~/.claude/claude-usage-wrapped-command` に書き込める者は任意コードを実行できる
- **`npx` で外部パッケージを実行する。** モデル別集計は ccusage に依存する（バージョンは固定）。
  npx が無ければレート制限の表示だけで動く
- **`~/.claude/usage-snapshot.json` は 644 で置かれる。** `session_id` と料金が入るため、
  同じ Mac に別のユーザーアカウントがあると読める
- **install.sh は `settings.json` を書き換える。** 実行前に `--dry-run` で内容を確認できる

## アンインストール

1. `~/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --unregister-login-item`
   （アプリを消す前に。消してからだと登録が残ることがある）
2. メニューから「ClaudeUsage を終了」
3. `rm -rf ~/Applications/ClaudeUsage.app`
4. `~/.claude/settings.json` を `settings.json.bak.*` から戻す
5. `rm -f ~/.claude/claude-usage-statusline.sh ~/.claude/claude-usage-wrapped-command ~/.claude/usage-snapshot.json`

## 開発

```sh
./build.sh      # ビルドして ~/Applications へインストールし直す
```

ソースは `Sources/main.swift` の 1 ファイル。Xcode プロジェクトは無く、`build.sh` が
`swiftc` でバイナリを作り、`.app` のディレクトリ構造と `Info.plist` を組み立てて ad-hoc 署名する。
`Info.plist` の `LSUIElement` で Dock とアプリスイッチャーに出ないようにしている。

## ライセンス

MIT License（[LICENSE](LICENSE)）
