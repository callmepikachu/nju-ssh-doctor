#!/usr/bin/env bash
# lib/probe.sh —— 各段探测函数。
# 设计：每个函数只负责“测一个事实”，不打印结论，不改系统状态。
#       所有函数在成功时返回 0，失败时返回 1。
#
# 依赖：nc, ping, ssh, ipconfig/ifconfig, netstat (macOS)

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------

# 带超时的 TCP 连通性探测
# 用法：probe_tcp <host> <port> [timeout_sec]
probe_tcp() {
  local host="$1" port="$2" timeout="${3:-$NJU_CONNECT_TIMEOUT}"
  if command -v nc >/dev/null 2>&1; then
    if nc -vz -G "$timeout" "$host" "$port" >/dev/null 2>&1; then
      return 0
    fi
    # 不同 nc 实现标志不同，回退到不带 -G 的版本
    if nc -z -w "$timeout" "$host" "$port" >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi
  return 1
}

# 带超时的 ICMP 探测
# 用法：probe_ping <host> [timeout_sec] [count]
probe_ping() {
  local host="$1" timeout="${2:-3}" count="${3:-2}"
  if ping -c "$count" -t "$timeout" "$host" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# 取 ping 的 RTT（用于判断是否绕远路）
# 输出：例如 "123.4ms"，失败时输出 "-"
probe_ping_rtt() {
  local host="$1" timeout="${2:-3}"
  local out
  out="$(ping -c 2 -t "$timeout" "$host" 2>/dev/null | awk -F'[= ]+' '/rtt|round-trip/ {print $(NF-1); exit}')"
  if [ -n "$out" ] && printf '%s' "$out" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
    printf '%.1fms' "$out"
  else
    echo "-"
  fi
}

# ---------------------------------------------------------------------------
# macmini 跳板探测（通过 ssh，不修改远端状态）
# ---------------------------------------------------------------------------

# 跳板是否可达（ssh 层面）
probe_jump_reachable() {
  ssh -o ConnectTimeout="$NJU_CONNECT_TIMEOUT" -o BatchMode=yes \
      "$NJU_JUMP_HOST" 'exit 0' >/dev/null 2>&1
}

# 在跳板上执行一条命令，超时保护
# 用法：jump_exec "<command>"
jump_exec() {
  ssh -o ConnectTimeout="$NJU_CONNECT_TIMEOUT" -o BatchMode=yes \
      -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
      "$NJU_JUMP_HOST" "$1" 2>/dev/null
}

# utun4 是否建立（beyond 的隧道网卡）
# 输出：是 "up" 或 "down"
probe_jump_utun() {
  local out
  out="$(jump_exec "ifconfig utun4 2>/dev/null | grep -q 'inet ${NJU_TUN_ADDR}' && echo up || echo down")"
  [ "$out" = "up" ]
}

# 跳板上 NJU 网段的路由是否指向 utun4
probe_jump_route() {
  local out
  out="$(jump_exec "netstat -rn -f inet 2>/dev/null | grep -E '^172\.16\.66' | awk '{print \$NF}' | head -1")"
  [ "$out" = "utun4" ]
}

# 跳板到中转节点是否可达（A 类故障的分界线）
probe_jump_relay() {
  jump_exec "nc -z -G ${NJU_CONNECT_TIMEOUT} ${NJU_RELAY_IP} ${NJU_RELAY_PORT} >/dev/null 2>&1 && echo ok || echo fail" \
    | grep -q ok
}

# 跳板到 NJU 目标是否可达（最终判断）
probe_jump_to_target() {
  jump_exec "nc -z -G ${NJU_CONNECT_TIMEOUT} ${NJU_TARGET_IP} ${NJU_TARGET_PORT} >/dev/null 2>&1 && echo ok || echo fail" \
    | grep -q ok
}

# 跳板上 beyond 隧道子进程是否在跑（B 类故障的分界线）
probe_jump_tunnel_process() {
  jump_exec "pgrep -f 'tunnel_for_darwin_arm64' >/dev/null && echo ok || echo fail" | grep -q ok
}

# 跳板上 QuickFox 是否在跑
probe_jump_quickfox() {
  jump_exec "pgrep -f 'QuickFox.app/Contents/MacOS/QuickFox' >/dev/null && echo ok || echo fail" | grep -q ok
}

# 跳板上 QuickFox 的 root 助手是否在跑（真正接管流量的是它）
probe_jump_quickfox_helper() {
  jump_exec "pgrep -f 'com.quickfox.tund' >/dev/null && echo ok || echo fail" | grep -q ok
}

# ---------------------------------------------------------------------------
# 端到端：本机 → 跳板 → NJU 的 ssh 本身
# ---------------------------------------------------------------------------

# 用 ssh config 里的别名做一次完整的 banner 交换测试
# 用法：probe_ssh_alias [alias]
probe_ssh_alias() {
  local alias="${1:-$NJU_TARGET_HOST}"
  ssh -o ConnectTimeout="$NJU_CONNECT_TIMEOUT" -o BatchMode=yes \
      -o ConnectionAttempts=1 -o LogLevel=ERROR \
      "$alias" 'echo ok' 2>/dev/null | grep -q '^ok$'
}

# 本机直连（不经跳板）NJU 目标——用来判断「是不是整个 VPN 都没了」
# 通常应该失败（NJU 在内网），失败是预期的
probe_local_direct_target() {
  probe_tcp "$NJU_TARGET_IP" "$NJU_TARGET_PORT"
}
