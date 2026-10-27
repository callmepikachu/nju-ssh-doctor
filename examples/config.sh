#!/usr/bin/env bash
# 默认参数。可以在 ~/.config/nju-ssh-doctor/config.sh 里覆盖，或通过环境变量覆盖。
# 所有变量都支持环境变量优先：NJU_JUMP_HOST / NJU_TARGET_HOST 等。

# 本机 ssh config 里的跳板别名
: "${NJU_JUMP_HOST:=macmini}"

# 本机 ssh config 里的最终目标别名
: "${NJU_TARGET_HOST:=NJU-vscode}"

# NJU 内网的机器 IP（用于在跳板上直接探测，绕开 ssh config）
: "${NJU_TARGET_IP:=172.16.66.158}"
: "${NJU_TARGET_PORT:=22}"

# beyond tunnel 的中转节点（从 beyond_tunnel 日志里抓的）
: "${NJU_RELAY_IP:=43.242.74.145}"
: "${NJU_RELAY_PORT:=51820}"

# beyond 隧道建立后 utun4 的地址
: "${NJU_TUN_ADDR:=100.64.0.249}"

# 探测超时（秒），必须比 ssh ConnectTimeout 短
: "${NJU_CONNECT_TIMEOUT:=5}"

# 可选：把 QuickFox 当作 beyond 的底层出口
: "${NJU_ENABLE_QUICKFOX:=1}"
: "${NJU_QUICKFOX_APP:=/Applications/QuickFox.app}"

# 可选：把 beyond 的 App 路径（重启时用）
: "${NJU_BEYOND_APP:=/Applications/beyond_tunnel.app}"
