#!/bin/bash
# ClaudeUsage.app 用の statusline ラッパー（install.sh が設置する）。
#
# Claude Code が statusline に渡す JSON をサイドカーへ書き出したうえで、
# 元の statusline コマンドへ同じ入力をそのまま流す。元のスクリプトには
# 一切手を入れないので、あとで外すのも settings.json を戻すだけで済む。
set -u

SNAPSHOT="$HOME/.claude/usage-snapshot.json"
WRAPPED_FILE="$HOME/.claude/claude-usage-wrapped-command"

input=$(cat)
now=$(date +%s)

# rate_limits のキーはプランや状況で増える（seven_day_opus / spend_limit 等）ため、
# 個別に取り出さずオブジェクトごとコピーし、解釈はアプリ側に任せる。
# 一時ファイル + mv で atomic に書き、複数セッションが同時に statusline を
# 回しても壊れた JSON を読ませない。
if printf '%s' "$input" | jq -c --argjson now "$now" '{
  updated_at: $now,
  session_id: (.session_id // null),
  model: (.model.display_name // null),
  session_cost_usd: (.cost.total_cost_usd // null),
  context_used_percentage: (.context_window.used_percentage // null),
  rate_limits: (.rate_limits // {})
}' > "$SNAPSHOT.$$" 2>/dev/null; then
  mv -f "$SNAPSHOT.$$" "$SNAPSHOT" 2>/dev/null
else
  rm -f "$SNAPSHOT.$$"
fi

# 元の statusline コマンド。引用符を含んでも壊れないよう、install.sh が
# このラッパー本体ではなく別ファイルへ書き出している。
if [ -s "$WRAPPED_FILE" ]; then
  printf '%s' "$input" | eval "$(cat "$WRAPPED_FILE")"
  exit $?
fi

# statusline が未設定だった場合に出す最小限の 1 行。
printf '%s' "$input" | jq -r '
  "🤖 \(.model.display_name // "Claude")"
  + " | 🧠 \(.context_window.used_percentage // 0 | round)%"
  + (if .rate_limits.five_hour then " | ⏳ 5h \(.rate_limits.five_hour.used_percentage | round)%" else "" end)
  + (if .rate_limits.seven_day then " · 7d \(.rate_limits.seven_day.used_percentage | round)%" else "" end)
'
