#!/usr/bin/env bash
# lib/fix.sh —— 幂等修复动作。
# 原则：只做“能自动做对”的事；需要人工授权或判断的动作只打印提示，不硬来。
#
# 策略（2026-10 修订，用户要求「如无必要不开 QuickFox」）：
#   QuickFox 会接管 DNS 和公网出口，常开有副作用（DNS 超时、公网变慢）。
#   所以默认「不开」，按需才开，而且只开一小会儿：
#     1. 故障 A 时先重启 beyond，让它重新握手 —— 能好就不再往下走
#     2. 仍不通才临时开 QuickFox（需显式 NJU_ENABLE_QUICKFOX=1）
#     3. 链路恢复后立即关闭 QuickFox 本身（只关 App，不碰 root 助手）
#   由 doctor 启动的 QuickFox 记在 state 文件里；用户自己开的不会被关。
#
# 故障 B（隧道进程死亡）→ 重启 beyond App（需要 App 内 sudo 授权，脚本只负责拉起）

STATE_DIR="${NJU_STATE_DIR:-${HOME}/.cache/nju-ssh-doctor}"
QF_STATE_FILE="${STATE_DIR}/quickfox.started_by_doctor"

# ---------------------------------------------------------------------------
# 通用封装
# ---------------------------------------------------------------------------

# 统一执行：jump 为 "local" 时本机跑，否则通过 ssh 到跳板跑
jump_exec_any() {
  local jump="$1" cmd="$2"
  if [ "$jump" = "local" ]; then
    bash -c "$cmd" >/dev/null 2>&1
  else
    ssh -o ConnectTimeout="$NJU_CONNECT_TIMEOUT" -o BatchMode=yes "$jump" "$cmd" >/dev/null 2>&1
  fi
}

# QuickFox 的 root 助手是否在跑（真正接管流量的是它）
quickfox_helper_running() {
  local jump="$1"
  jump_exec_any "$jump" "pgrep -f 'com.quickfox.tund' >/dev/null"
}

# QuickFox 主 App 是否在跑
quickfox_app_running() {
  local jump="$1"
  jump_exec_any "$jump" "pgrep -f 'QuickFox.app/Contents/MacOS/QuickFox' >/dev/null"
}

# ---------------------------------------------------------------------------
# state：记录“这次是 doctor 开的 QuickFox”
# ---------------------------------------------------------------------------
qf_mark_started_by_doctor() { mkdir -p "$STATE_DIR" && echo "$(date +%s) $1" >"$QF_STATE_FILE"; }
qf_started_by_doctor()      { [ -f "$QF_STATE_FILE" ]; }
qf_clear_mark()             { rm -f "$QF_STATE_FILE"; }

# ---------------------------------------------------------------------------
# 公共：重启 beyond App
# ---------------------------------------------------------------------------
restart_beyond() {
  local jump="$1"
  local cmd="pkill -TERM -f '${NJU_BEYOND_APP}/Contents/MacOS/beyond_tunnel\$' 2>/dev/null; sleep 2; open -a '${NJU_BEYOND_APP}'"
  if [ "$jump" = "local" ]; then
    bash -c "$cmd" >/dev/null 2>&1
  else
    ssh -o ConnectTimeout="$NJU_CONNECT_TIMEOUT" -o BatchMode=yes "$jump" "$cmd" >/dev/null 2>&1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 修复 A：中转节点不可达
# ---------------------------------------------------------------------------
# 参数：$1 = jump（"local" 或主机名）
# 返回：0 = 已恢复；1 = 未恢复
fix_relay_unreachable() {
  local jump="$1" i

  echo "  [步骤 1] 重启 beyond，重新握手（不打开 QuickFox）"
  restart_beyond "$jump"
  for i in 1 2 3; do
    sleep 5
    if probe_relay_any "$jump"; then
      echo "  [成功] 重启 beyond 后节点已可达，不需要 QuickFox"
      return 0
    fi
  done
  echo "  [信息] 重启 beyond 无效，节点仍不可达"

  # 用户手动开的 QuickFox 已经在跑 → 不动它，只提示
  if quickfox_helper_running "$jump"; then
    echo "  [信息] QuickFox 已在运行（非 doctor 启动），请自行在 App 里切换线路"
    return 1
  fi

  if [ "${NJU_ENABLE_QUICKFOX:-0}" != "1" ]; then
    echo "  [建议] 如果必须救急，可以临时用 QuickFox："
    echo "         NJU_ENABLE_QUICKFOX=1 ./bin/doctor.sh --fix"
    return 1
  fi

  if ! jump_exec_any "$jump" "test -d '${NJU_QUICKFOX_APP}'"; then
    echo "  [失败] 找不到 QuickFox: ${NJU_QUICKFOX_APP}"
    return 1
  fi

  echo "  [步骤 2] 临时启用 QuickFox 作为 beyond 底层出口"
  jump_exec_any "$jump" "open -a '${NJU_QUICKFOX_APP}'"
  qf_mark_started_by_doctor "$jump"

  for i in 1 2 3 4 5 6; do
    sleep 5
    if probe_relay_any "$jump"; then
      echo "  [成功] QuickFox 生效（第 ${i} 次探测，约 5 秒内）"
      return 0
    fi
  done

  echo "  [失败] QuickFox 开了 30 秒仍不通，自动关掉它"
  quickfox_stop "$jump"
  return 1
}

# ---------------------------------------------------------------------------
# 修复 B：隧道进程死亡
# ---------------------------------------------------------------------------
fix_tunnel_dead() {
  local jump="$1"

  echo "  [修复] 重启 beyond App: ${NJU_BEYOND_APP}"
  restart_beyond "$jump"
  sleep 12

  if probe_tunnel_process_any "$jump"; then
    echo "  [成功] 隧道进程已起来"
    return 0
  fi
  echo "  [需要人工] 隧道进程仍没起来 —— 到机器前打开 beyond App 点连接，并输入 sudo 密码。"
  return 1
}

# ---------------------------------------------------------------------------
# QuickFox 收尾：只关“doctor 自己开的”，且只关主 App
# ---------------------------------------------------------------------------
quickfox_stop() {
  local jump="$1"

  if ! qf_started_by_doctor; then
    echo "  [跳过] QuickFox 不是 doctor 启动的，不动它"
    return 0
  fi

  echo "  [清理] 关闭 doctor 启动的 QuickFox 主 App"
  jump_exec_any "$jump" \
    "osascript -e 'tell application \"QuickFox\" to quit' >/dev/null 2>&1 || pkill -TERM -f 'QuickFox.app/Contents/MacOS/QuickFox' 2>/dev/null"
  sleep 3
  qf_clear_mark
  return 0
}

# ---------------------------------------------------------------------------
# 探测封装（给 fix 与 watchdog 用）
# ---------------------------------------------------------------------------
probe_relay_any() {
  jump_exec_any "$1" "nc -z -G ${NJU_CONNECT_TIMEOUT} ${NJU_RELAY_IP} ${NJU_RELAY_PORT} >/dev/null 2>&1"
}

probe_tunnel_process_any() {
  jump_exec_any "$1" "pgrep -f 'tunnel_for_darwin_arm64' >/dev/null"
}
