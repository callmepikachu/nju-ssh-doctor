#!/usr/bin/env bash
# watchdog.sh —— 定时体检，只在「链路不正常且能自动修」时才动作。
# 由 launchd 调用（见 launchd/），也可以手动跑。
#
# 行为（2026-10 修订，「如无必要不开 QuickFox」）：
#   - 状态 OK：安静退出（不写日志噪音）
#   - 故障 A：重启 beyond 重新握手；只在 NJU_ENABLE_QUICKFOX=1 时才临时开 QuickFox
#   - 故障 B：自动重启 beyond App（需要机器前一次 sudo 授权）
#   - 跳板不可达：只记录，不动作
#
# 修复结束后如果 doctor 自己开过 QuickFox，会把它关回去。
#
# 日志：~/Library/Logs/nju-ssh-doctor.log

set -u
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG="${HOME}/Library/Logs/nju-ssh-doctor.log"

mkdir -p "$(dirname "$LOG")"

out="$("${ROOT_DIR}/bin/doctor.sh" --json 2>/dev/null)"
state="$(printf '%s' "$out" | sed -n 's/.*"state":"\([^"]*\)".*/\1/p')"

case "$state" in
  OK)
    exit 0 ;;
  RELAY_UNREACHABLE)
    {
      echo "[$(date '+%F %T')] state=$state, 尝试恢复（不开 QuickFox 优先）"
      "${ROOT_DIR}/bin/doctor.sh" --fix 2>&1 | sed 's/^/    /'

      # 复测；如果链路恢复且 QuickFox 是 doctor 开的，就关掉它
      after="$("${ROOT_DIR}/bin/doctor.sh" --json 2>/dev/null)"
      after_state="$(printf '%s' "$after" | sed -n 's/.*"state":"\([^"]*\)".*/\1/p')"
      if [ "$after_state" = "OK" ]; then
        "${ROOT_DIR}/bin/doctor.sh" --quickfox-off 2>&1 | sed 's/^/    /'
      fi
      echo
    } >>"$LOG"
    exit 0 ;;
  TUNNEL_DEAD)
    {
      echo "[$(date '+%F %T')] state=$state, 尝试自动修复"
      "${ROOT_DIR}/bin/doctor.sh" --fix 2>&1 | sed 's/^/    /'
      echo
    } >>"$LOG"
    exit 0 ;;
  *)
    echo "[$(date '+%F %T')] state=${state:-未知}, 需人工处理: $(printf '%s' "$out")" >>"$LOG"
    exit 0 ;;
esac
