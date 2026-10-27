#!/usr/bin/env bash
# lib/verdict.sh —— 把探测结果映射到状态、结论和建议。
# 依赖 probe.sh 已 source。
#
# 用法：
#   verdict_run            # 一次完整探测，结果写入全局变量
#   verdict_print          # 打印人类可读报告
#   verdict_json           # 打印机器可读 JSON

# 全局状态（由 verdict_run 填充）
V_STATE=""
V_JUMP=""
V_UTUN=""
V_ROUTE=""
V_RELAY=""
V_TUNPROC=""
V_QF=""
V_QF_HELPER=""
V_TARGET=""
V_SSH_ALIAS=""
V_RTT=""

# ---------------------------------------------------------------------------
# 一、探测并填充全局变量
# ---------------------------------------------------------------------------
verdict_run() {
  V_JUMP="$(probe_jump_reachable && echo ok || echo fail)"

  if [ "$V_JUMP" = "ok" ]; then
    # 一次 ssh 取回所有远端事实，减少往返
    local remote
    remote="$(jump_exec '
      printf "utun=%s\n" "$(ifconfig utun4 2>/dev/null | grep -q "inet '"${NJU_TUN_ADDR}"'" && echo up || echo down)"
      printf "route=%s\n" "$(netstat -rn -f inet 2>/dev/null | grep -E "^172\.16\.66" | awk "{print \$NF}" | head -1)"
      printf "tunproc=%s\n" "$(pgrep -f tunnel_for_darwin_arm64 >/dev/null && echo ok || echo fail)"
      printf "relay=%s\n" "$(nc -z -G '"${NJU_CONNECT_TIMEOUT}"' '"${NJU_RELAY_IP}"' '"${NJU_RELAY_PORT}"' >/dev/null 2>&1 && echo ok || echo fail)"
      printf "target=%s\n" "$(nc -z -G '"${NJU_CONNECT_TIMEOUT}"' '"${NJU_TARGET_IP}"' '"${NJU_TARGET_PORT}"' >/dev/null 2>&1 && echo ok || echo fail)"
      printf "qf=%s\n" "$(pgrep -f "QuickFox.app/Contents/MacOS/QuickFox" >/dev/null && echo ok || echo fail)"
      printf "qfhelper=%s\n" "$(pgrep -f com.quickfox.tund >/dev/null && echo ok || echo fail)"
    ')"

    V_UTUN="$(printf '%s\n' "$remote" | sed -n 's/^utun=//p')"
    V_ROUTE="$(printf '%s\n' "$remote" | sed -n 's/^route=//p')"
    V_TUNPROC="$(printf '%s\n' "$remote" | sed -n 's/^tunproc=//p')"
    V_RELAY="$(printf '%s\n' "$remote" | sed -n 's/^relay=//p')"
    V_TARGET="$(printf '%s\n' "$remote" | sed -n 's/^target=//p')"
    V_QF="$(printf '%s\n' "$remote" | sed -n 's/^qf=//p')"
    V_QF_HELPER="$(printf '%s\n' "$remote" | sed -n 's/^qfhelper=//p')"
  else
    V_UTUN="unknown"; V_ROUTE="unknown"; V_TUNPROC="unknown"
    V_RELAY="unknown"; V_TARGET="unknown"; V_QF="unknown"; V_QF_HELPER="unknown"
  fi

  # 网卡和路由是互相独立的两个事实，但结论只用 utun
  [ "$V_ROUTE" = "" ] && V_ROUTE="none"
  V_RTT="$( [ "$V_TARGET" = "ok" ] && probe_ping_rtt "$NJU_TARGET_IP" 3 || echo "-" )"
  V_SSH_ALIAS="$(probe_ssh_alias && echo ok || echo fail)"

  # ---------------------------------------------------------------------
  # 二、状态判定（顺序很重要：先排除不可能的，再细分）
  # ---------------------------------------------------------------------
  if [ "$V_JUMP" != "ok" ]; then
    V_STATE="JUMP_DOWN"          # 连跳板都进不去
  elif [ "$V_TUNPROC" != "ok" ] || [ "$V_UTUN" != "up" ]; then
    V_STATE="TUNNEL_DEAD"        # B 类：beyond 隧道进程/网卡都没了
  elif [ "$V_TARGET" = "ok" ]; then
    V_STATE="OK"                 # 目标通了
  elif [ "$V_RELAY" != "ok" ]; then
    V_STATE="RELAY_UNREACHABLE"  # A 类：中转节点不可达
  else
    V_STATE="TUNNEL_STALLED"     # 节点通、目标不通：隧道建立了但没转发
  fi
}

# ---------------------------------------------------------------------------
# 三、状态 → 一句话结论 + 建议动作
# ---------------------------------------------------------------------------
verdict_summary() {
  case "$V_STATE" in
    OK)
      if [ "$V_QF_HELPER" = "ok" ] || [ "$V_QF" = "ok" ]; then
        echo "✅ 链路正常（注意：QuickFox 正开着，会接管 DNS 和公网出口，可以关掉）"
      else
        echo "✅ 链路正常，只需要 beyond，不需要 QuickFox"
      fi
      ;;
    JUMP_DOWN)
      echo "❌ 连跳板 ${NJU_JUMP_HOST} 都失败 → 不是 NJU/beyond 的问题，先查本机网络或跳板机"
      ;;
    TUNNEL_DEAD)
      echo "❌ 故障 B：beyond 隧道进程/网卡不在了 → 重启 beyond App 并确认 sudo 授权（QuickFox 没用）"
      ;;
    RELAY_UNREACHABLE)
      echo "⚠️  故障 A：beyond 中转节点 ${NJU_RELAY_IP}:${NJU_RELAY_PORT} 不可达 → 开 QuickFox 当 beyond 的底层出口"
      ;;
    TUNNEL_STALLED)
      echo "⚠️  中转节点通但目标不通 → 可能是 NJU 侧机器/路由问题，或隧道处于假连接状态，尝试重连 beyond"
      ;;
  esac
}

verdict_actions() {
  case "$V_STATE" in
    OK)                 echo "无需操作" ;;
    JUMP_DOWN)          echo "1) 检查本机网络  2) ping/ssh ${NJU_JUMP_HOST}  3) 检查本机 Tailscale/路由" ;;
    TUNNEL_DEAD)        echo "open -a ${NJU_BEYOND_APP}  # 然后在 App 里点连接，允许 sudo 授权" ;;
    RELAY_UNREACHABLE)  echo "open -a ${NJU_QUICKFOX_APP}  # 等 QuickFox 连上后复测" ;;
    TUNNEL_STALLED)     echo "在 beyond App 里断开重连；若仍不通，检查 NJU 侧 172.16.66.158 是否在线" ;;
  esac
}

verdict_exit_code() {
  case "$V_STATE" in
    OK)                 echo 0 ;;
    RELAY_UNREACHABLE)  echo 1 ;;
    TUNNEL_DEAD)        echo 2 ;;
    JUMP_DOWN)          echo 1 ;;
    TUNNEL_STALLED)     echo 1 ;;
    *)                  echo 3 ;;
  esac
}

# ---------------------------------------------------------------------------
# 四、输出
# ---------------------------------------------------------------------------
# 按「显示宽度」对齐（中文占 2 列），避免 printf %-14s 把中文挤歪。
_p() {
  local label="$1" value="$2" target=14 width=0 i=0 ch
  while [ "$i" -lt "${#label}" ]; do
    ch="${label:$i:1}"
    case "$ch" in
      [!\ -~]) width=$((width + 2)) ;;
      *)       width=$((width + 1)) ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$label"
  while [ "$width" -lt "$target" ]; do
    printf ' '
    width=$((width + 1))
  done
  printf '  %s\n' "$value"
}

verdict_print() {
  echo "=============================================="
  echo " nju-ssh-doctor  $(date '+%F %T')"
  echo " 跳板: ${NJU_JUMP_HOST}   目标: ${NJU_TARGET_HOST} (${NJU_TARGET_IP}:${NJU_TARGET_PORT})"
  echo "=============================================="

  case "$V_JUMP" in   ok) _p "跳板 ssh"  "✅ 可达" ;;   *) _p "跳板 ssh" "❌ 不可达" ;; esac
  case "$V_UTUN" in   up) _p "beyond 网卡" "✅ utun4 = ${NJU_TUN_ADDR}" ;;  down) _p "beyond 网卡" "❌ 没有 utun4" ;; *) _p "beyond 网卡" "— 未测" ;; esac
  case "$V_TUNPROC" in ok) _p "隧道进程" "✅ 在跑" ;; fail) _p "隧道进程" "❌ 没有 tunnel_for_darwin_arm64" ;; *) _p "隧道进程" "— 未测" ;; esac
  case "$V_ROUTE" in   utun4) _p "NJU 路由" "✅ 172.16.66/24 → utun4" ;; *) _p "NJU 路由" "❌ → ${V_ROUTE}" ;; esac
  case "$V_RELAY" in   ok) _p "中转节点" "✅ ${NJU_RELAY_IP}:${NJU_RELAY_PORT}" ;; fail) _p "中转节点" "❌ 超时" ;; *) _p "中转节点" "— 未测" ;; esac
  case "$V_TARGET" in  ok) _p "NJU 目标" "✅ ${NJU_TARGET_IP}:${NJU_TARGET_PORT}  (RTT ${V_RTT})" ;; fail) _p "NJU 目标" "❌ 超时" ;; *) _p "NJU 目标" "— 未测" ;; esac
  case "$V_SSH_ALIAS" in ok) _p "ssh aliased" "✅ ssh ${NJU_TARGET_HOST} 可用" ;; *) _p "ssh aliased" "❌ ssh ${NJU_TARGET_HOST} 失败" ;; esac
  case "$V_QF_HELPER" in ok) _p "QuickFox" "⚠️  正在运行（接管 DNS/出口）" ;; fail) _p "QuickFox" "未运行（正常）" ;; *) _p "QuickFox" "— 未测" ;; esac

  echo "----------------------------------------------"
  verdict_summary
  echo "→ 建议: $(verdict_actions)"
  echo "=============================================="
}

verdict_json() {
  printf '{'
  printf '"time":"%s",' "$(date +%s)"
  printf '"state":"%s",' "$V_STATE"
  printf '"jump":"%s",' "$V_JUMP"
  printf '"utun":"%s",' "$V_UTUN"
  printf '"tunnel_process":"%s",' "$V_TUNPROC"
  printf '"route":"%s",' "$V_ROUTE"
  printf '"relay":"%s",' "$V_RELAY"
  printf '"target":"%s",' "$V_TARGET"
  printf '"target_rtt":"%s",' "$V_RTT"
  printf '"ssh_alias":"%s",' "$V_SSH_ALIAS"
  printf '"quickfox":"%s",' "$V_QF"
  printf '"quickfox_helper":"%s"' "$V_QF_HELPER"
  printf '}\n'
}
