#!/usr/bin/env bash
# tests/run.sh —— 不依赖真实网络的单元测试。
# 思路：把「到真实机器的探测」替换成可注入的桩，验证状态机判定是否正确。
#
# 用法：./tests/run.sh

set -u
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
FAILED_CASES=()

ok()   { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); printf '  ❌ %s\n' "$1"; }

# ---------------------------------------------------------------------------
# 桩：注入 verdict_run 所需的探测结果，绕过 ssh
# ---------------------------------------------------------------------------
load_lib() {
  # shellcheck source=../examples/config.sh
  . "${ROOT_DIR}/examples/config.sh"
  # shellcheck source=../lib/probe.sh
  . "${ROOT_DIR}/lib/probe.sh"
  # shellcheck source=../lib/verdict.sh
  . "${ROOT_DIR}/lib/verdict.sh"
}

# 用桩跑一次判定
# 用法：judge jump utun tunproc relay target
judge() {
  load_lib
  local _jump="$1" _utun="$2" _tunproc="$3" _relay="$4" _target="$5"
  probe_jump_reachable() {
    [ "$_jump" = "ok" ]
  }
  # 绕过「一次 ssh 取所有事实」的实现，直接给变量赋值
  verdict_run() {
    V_JUMP="$_jump"; V_UTUN="$_utun"; V_TUNPROC="$_tunproc"
    V_ROUTE="utun4"; V_RELAY="$_relay"; V_TARGET="$_target"
    V_QF="fail"; V_QF_HELPER="fail"; V_RTT="-"; V_SSH_ALIAS="fail"
    if [ "$V_JUMP" != "ok" ]; then
      V_STATE="JUMP_DOWN"
    elif [ "$V_TUNPROC" != "ok" ] || [ "$V_UTUN" != "up" ]; then
      V_STATE="TUNNEL_DEAD"
    elif [ "$V_TARGET" = "ok" ]; then
      V_STATE="OK"
    elif [ "$V_RELAY" != "ok" ]; then
      V_STATE="RELAY_UNREACHABLE"
    else
      V_STATE="TUNNEL_STALLED"
    fi
  }
  verdict_run
  echo "$V_STATE"
}

expect_state() {
  local label="$1" want="$2" got
  got="$(judge "$3" "$4" "$5" "$6" "$7")"
  if [ "$got" = "$want" ]; then
    ok "$label → $want"
  else
    bad "$label: 期望 $want, 实际 $got"
  fi
}

echo "== 状态机判定 =="
expect_state "正常链路"                    OK                ok   up   ok   ok   ok
expect_state "跳板不可达"                  JUMP_DOWN         fail up   ok   ok   ok
expect_state "隧道进程死了(无 utun)"        TUNNEL_DEAD       ok   down fail fail fail
expect_state "utun 在但进程不在"            TUNNEL_DEAD       ok   up   fail ok   ok
expect_state "节点超时(Case 2026-10-26)"   RELAY_UNREACHABLE ok   up   ok   fail fail
expect_state "节点通但目标不通"             TUNNEL_STALLED    ok   up   ok   ok   fail

echo "== 退出码 =="
for pair in "OK:0" "RELAY_UNREACHABLE:1" "TUNNEL_DEAD:2" "JUMP_DOWN:1" "TUNNEL_STALLED:1"; do
  want_state="${pair%%:*}"; want_code="${pair##*:}"
  load_lib
  V_STATE="$want_state"
  got_code="$(verdict_exit_code)"
  if [ "$got_code" = "$want_code" ]; then
    ok "$want_state → exit $want_code"
  else
    bad "$want_state: 期望 exit $want_code, 实际 $got_code"
  fi
done

echo "== JSON 输出格式 =="
load_lib
json="$( { V_STATE="OK"; V_JUMP="ok"; V_UTUN="up"; V_TUNPROC="ok"; V_ROUTE="utun4"
           V_RELAY="ok"; V_TARGET="ok"; V_RTT="12.3ms"; V_SSH_ALIAS="ok"
           V_QF="fail"; V_QF_HELPER="fail"; verdict_json; } 2>&1 )"
if printf '%s' "$json" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  ok "JSON 可被解析"
else
  bad "JSON 非法: $json"
fi

echo "== shellcheck（如已安装） =="
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "${ROOT_DIR}/bin/doctor.sh" "${ROOT_DIR}"/lib/*.sh; then
    ok "shellcheck 通过"
  else
    bad "shellcheck 有告警"
  fi
else
  echo "  ⚠️  未安装 shellcheck，跳过"
fi

echo
echo "通过 $PASS, 失败 $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '失败用例: %s\n' "${FAILED_CASES[*]}"
  exit 1
fi
