#!/usr/bin/env bash
# nju-ssh-doctor 入口
#
# 用法:
#   doctor.sh                 诊断（通过 ssh 到跳板）
#   doctor.sh --fix           诊断 + 自动修复
#   doctor.sh --json          机器可读输出
#   doctor.sh --local         在跳板机本机运行（不经过 ssh）
#   doctor.sh --jump <host>   指定跳板，默认 macmini
#   doctor.sh --target <host> 指定目标，默认 NJU-vscode
#   doctor.sh --help
#
# 退出码: 0 正常 | 1 A 类(节点不通)/跳板不通/隧道假连接 | 2 B 类(隧道进程死亡) | 3 参数/环境错误

set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SELF_DIR}/.." && pwd)"

# ---- 参数 ----
MODE="diagnose"
FIX=0
JSON=0
LOCAL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fix)    FIX=1 ;;
    --json)   JSON=1 ;;
    --local)  LOCAL=1 ;;
    --jump)   NJU_JUMP_HOST="${2:?--jump 需要参数}"; shift ;;
    --target) NJU_TARGET_HOST="${2:?--target 需要参数}"; shift ;;
    --help|-h)
      sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 3 ;;
  esac
  shift
done

# ---- 配置 ----
# shellcheck source=../examples/config.sh
if [ -f "${ROOT_DIR}/examples/config.sh" ]; then
  . "${ROOT_DIR}/examples/config.sh"
fi
if [ -f "${HOME}/.config/nju-ssh-doctor/config.sh" ]; then
  . "${HOME}/.config/nju-ssh-doctor/config.sh"
fi

# ---- 依赖 ----
for c in ssh nc; do
  command -v "$c" >/dev/null 2>&1 || { echo "缺少依赖: $c" >&2; exit 3; }
done

# ---- source ----
. "${ROOT_DIR}/lib/probe.sh"
. "${ROOT_DIR}/lib/verdict.sh"
. "${ROOT_DIR}/lib/fix.sh"

# --local：在跳板上直接跑，把 NJU_JUMP_HOST 改成空，所有 jump_exec 直连本机
if [ "$LOCAL" = "1" ]; then
  NJU_JUMP_HOST="local"
  probe_jump_reachable() { return 0; }
  jump_exec() { bash -c "$1" 2>/dev/null; }
fi

# ---- 主流程 ----
verdict_run

if [ "$JSON" = "1" ]; then
  verdict_json
else
  verdict_print
fi

# ---- 修复 ----
if [ "$FIX" = "1" ]; then
  case "$V_STATE" in
    RELAY_UNREACHABLE) fix_relay_unreachable "$NJU_JUMP_HOST" ;;
    TUNNEL_DEAD)       fix_tunnel_dead "$NJU_JUMP_HOST" ;;
  esac
  echo
  echo ">>> 修复后复测："
  verdict_run
  if [ "$JSON" = "1" ]; then verdict_json; else verdict_print; fi
fi

exit "$(verdict_exit_code)"
