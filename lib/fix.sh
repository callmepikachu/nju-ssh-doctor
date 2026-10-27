#!/usr/bin/env bash
# lib/fix.sh —— 幂等修复动作。
# 原则：只做“能自动做对”的事；需要人工授权或判断的动作只打印提示，不硬来。
#
# 故障 A（中转节点不可达）→ 在本机/跳板上启动 QuickFox，作为 beyond 的底层出口
# 故障 B（隧道进程死亡）  → 重启 beyond App（需要 App 内 sudo 授权，脚本只负责拉起）

fix_relay_unreachable() {
  local jump="$1"

  if [ "$NJU_ENABLE_QUICKFOX" != "1" ]; then
    echo "  [跳过] NJU_ENABLE_QUICKFOX=0，不自动启 QuickFox"
    return 1
  fi

  if jump_exec_any "$jump" "pgrep -f 'com.quickfox.tund' >/dev/null" ; then
    echo "  [信息] QuickFox 的 root 助手已在运行，但它可能没接管流量。请在 QuickFox 里连接一次。"
    return 0
  fi

  if jump_exec_any "$jump" "test -d '${NJU_QUICKFOX_APP}'"; then
    echo "  [修复] 启动 QuickFox: ${NJU_QUICKFOX_APP}"
    jump_exec_any "$jump" "open -a '${NJU_QUICKFOX_APP}'"
    echo "  [等待] 10 秒让 QuickFox 建立出口..."
    sleep 10
    if probe_jump_relay; then
      echo "  [成功] 中转节点已恢复可达"
      return 0
    fi
    echo "  [警告] QuickFox 起来了，但中转节点仍不可达。可能需要在 QuickFox 里手动点连接。"
    return 1
  fi

  echo "  [失败] 找不到 QuickFox: ${NJU_QUICKFOX_APP}"
  return 1
}

fix_tunnel_dead() {
  local jump="$1"

  if [ "$jump" = "local" ]; then
    echo "  [修复] 重启 beyond App: ${NJU_BEYOND_APP}"
    pkill -TERM -f "${NJU_BEYOND_APP}/Contents/MacOS/beyond_tunnel\$" 2>/dev/null
    sleep 2
    open -a "${NJU_BEYOND_APP}"
    echo "  [等待] 15 秒..."
    sleep 15
  else
    echo "  [修复] 通过 ssh 重启跳板 ${jump} 上的 beyond App"
    jump_exec_any "$jump" "pkill -TERM -f '${NJU_BEYOND_APP}/Contents/MacOS/beyond_tunnel\$'; sleep 2; open -a '${NJU_BEYOND_APP}'"
    echo "  [等待] 15 秒..."
    sleep 15
  fi

  if probe_jump_tunnel_process_any "$jump"; then
    echo "  [成功] 隧道进程已起来"
    return 0
  fi
  echo "  [需要人工] 隧道进程仍没起来 —— 到机器前打开 beyond App 点连接，并输入 sudo 密码。"
  return 1
}

# 统一封装：jump 为 "local" 时直接跑，否则通过 ssh 跑
jump_exec_any() {
  local jump="$1" cmd="$2"
  if [ "$jump" = "local" ]; then
    bash -c "$cmd" >/dev/null 2>&1
  else
    ssh -o ConnectTimeout="$NJU_CONNECT_TIMEOUT" -o BatchMode=yes "$jump" "$cmd" >/dev/null 2>&1
  fi
}

probe_jump_tunnel_process_any() {
  jump_exec_any "$1" "pgrep -f 'tunnel_for_darwin_arm64' >/dev/null"
}
