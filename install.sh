#!/bin/bash
# ClaudeUsage.app を導入する。
#
#   1. 必要なコマンドが揃っているか確認する
#   2. Claude Code の statusline がサイドカーを書くようにする
#      （既存の statusline スクリプトは書き換えず、ラッパーで包む）
#   3. アプリをビルドして ~/Applications に入れ、起動する
#
# --dry-run を付けると、何をするかだけ表示して一切変更しない。
set -euo pipefail

cd "$(dirname "$0")"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
WRAPPER="$CLAUDE_DIR/claude-usage-statusline.sh"
WRAPPED_FILE="$CLAUDE_DIR/claude-usage-wrapped-command"
SNAPSHOT="$CLAUDE_DIR/usage-snapshot.json"
STAMP=$(date +%Y%m%d%H%M%S)

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }

# 引用符が壊れないよう eval は使わず、引数をそのまま実行する。
# リダイレクトが要る処理は下の個別関数に分ける。
run() {
  if $DRY_RUN; then say "   [dry-run] $*"; else "$@"; fi
}

install_wrapper() {
  run cp statusline-wrapper.sh "$WRAPPER"
  run chmod +x "$WRAPPER"
}

# 元の statusline コマンドを別ファイルへ退避する。
# 引用符やスペースを含んでも壊れないよう、ラッパー本体には埋め込まない。
save_wrapped_command() {
  if $DRY_RUN; then
    say "   [dry-run] 元のコマンドを $WRAPPED_FILE へ退避"
    return
  fi
  jq -r '.statusLine.command' "$SETTINGS" > "$WRAPPED_FILE"
}

# type や padding など既存のキーは保持したまま command だけ差し替える。
update_settings() {
  if $DRY_RUN; then
    say "   [dry-run] settings.json の statusLine.command を $WRAPPER にする"
    return
  fi
  jq --arg cmd "$WRAPPER" '
    if (.statusLine | type) == "object"
    then .statusLine.command = $cmd
    else .statusLine = {type: "command", command: $cmd}
    end' "$SETTINGS" > "$SETTINGS.tmp"
  mv "$SETTINGS.tmp" "$SETTINGS"
}

# ---------------------------------------------------------------- 前提チェック

step "前提を確認"

[ "$(uname -s)" = "Darwin" ] || { say "macOS 専用です"; exit 1; }

missing=()
command -v jq     >/dev/null || missing+=("jq（brew install jq）")
command -v swiftc >/dev/null || missing+=("swiftc（xcode-select --install）")
if [ ${#missing[@]} -gt 0 ]; then
  say "次が足りません:"
  printf '   - %s\n' "${missing[@]}"
  exit 1
fi
say "   jq / swiftc  OK"

if command -v claude >/dev/null; then
  version=$(claude --version 2>/dev/null | awk '{print $1}')
  say "   Claude Code $version"
  # rate_limits が statusline に渡るのは 2.1.220 以降
  if [ "$(printf '%s\n2.1.220\n' "$version" | sort -V | head -1)" != "2.1.220" ]; then
    say "   ⚠︎ 2.1.220 未満では rate_limits が statusline に渡りません。更新してください"
  fi
else
  say "   ⚠︎ claude コマンドが見つかりません（PATH を確認してください）"
fi

command -v npx >/dev/null \
  && say "   npx OK（モデル別集計に使います）" \
  || say "   ⚠︎ npx がありません。レート制限は出ますが、モデル別集計は出ません"

# ------------------------------------------------------- statusline の設定

step "statusline を確認"

current_cmd=""
if [ -f "$SETTINGS" ]; then
  current_cmd=$(jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null || echo "")
fi

# 既にサイドカーを書いているなら触らない（このスクリプトの再実行、
# あるいは statusline へ直接書き出し処理を入れてある場合）。
already_writes=false
candidate=""
if [ -n "$current_cmd" ]; then
  # コマンド文字列から .sh の実体を拾って中身を見る
  candidate=$(printf '%s' "$current_cmd" | tr -d "'\"" \
    | awk '{for (i = 1; i <= NF; i++) if ($i ~ /\.sh$/) { print $i; exit }}')
  candidate="${candidate/#\~/$HOME}"
  if [ -n "$candidate" ] && [ -f "$candidate" ] && grep -q "usage-snapshot.json" "$candidate"; then
    already_writes=true
  fi
fi

if $already_writes; then
  say "   既にサイドカーを書き出しています。statusline は変更しません"
  say "   ($candidate)"
elif [ "$current_cmd" = "$WRAPPER" ]; then
  say "   既にラッパーが設定されています。ラッパーだけ更新します"
  install_wrapper
else
  if [ -f "$SETTINGS" ]; then
    run cp "$SETTINGS" "$SETTINGS.bak.$STAMP"
    say "   settings.json のバックアップ: $SETTINGS.bak.$STAMP"
  else
    run mkdir -p "$CLAUDE_DIR"
    $DRY_RUN || echo '{}' > "$SETTINGS"
  fi

  if [ -n "$current_cmd" ]; then
    say "   既存の statusline をラッパーで包みます（元のスクリプトは変更しません）"
    say "   元: $current_cmd"
    save_wrapped_command
  else
    say "   statusline が未設定なので、最小限の 1 行を出すラッパーを設定します"
    run rm -f "$WRAPPED_FILE"
  fi

  install_wrapper
  update_settings
  say "   statusline を設定しました"
fi

# ------------------------------------------------------------ ビルドと起動

step "アプリをビルド"
if $DRY_RUN; then say "   [dry-run] ./build.sh"; else ./build.sh; fi

step "起動"
run open "$HOME/Applications/ClaudeUsage.app"

cat <<MSG

完了しました。

  メニューバーの表示は、Claude Code のセッションが一度動いた時点で出ます
  （statusline が描かれたときに値が書き出されるため）。
  まだ何も出ない場合は Claude Code を開いて一言やり取りしてください。

  サイドカー: $SNAPSHOT

ログイン時に起動したいとき（自動では登録していません）:
  メニューの「ログイン時に起動」を選ぶか、次を実行してください。
  ~/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --register-login-item

外すとき:
  1. ~/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --unregister-login-item
     （ログイン項目を有効にしていた場合。アプリを消す前に実行してください）
  2. メニューから「ClaudeUsage を終了」
  3. rm -rf ~/Applications/ClaudeUsage.app
  4. settings.json を $SETTINGS.bak.* から戻す
     （ラッパーを使った場合。statusline に直接入れた場合はその行を消す）
MSG
