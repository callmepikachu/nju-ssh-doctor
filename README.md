# nju-ssh-doctor

诊断并自动修复「经过 beyond tunnel 从 macmini 跳板到 NJU 内网（`172.16.66.0/24`）」这条 SSH 链路的工具。

> 背景：`ssh NJU-vscode` 报 `Connection timed out during banner exchange`，看日志根本看不出是哪一环坏了。这个仓库把整条链路拆成可检测的几段，每一段都有明确的状态和修复动作，而不是每次靠人眼翻 verbose 日志。

## 链路长什么样

```text
本机 (Mac)                                    macmini (跳板)                      NJU
┌──────────────┐     ssh macmini       ┌────────────────────────┐    beyond    ┌────────────────┐
│ ssh NJU-vscode│──────────────────────▶│ 10.127.124.33:22       │──────────────▶│ 172.16.66.158:22│
└──────────────┘                       │   └─ ProxyJump 到 utun4 │  utun4 100.64.0.249  └────────────────┘
                                       │   QuickFox (救急才用，用完即关) │
                                       └────────────────────────┘
```

关键中间件是 macmini 上 beyond tunnel 建立的 `utun4` 网卡（`100.64.0.249`）和对应静态路由（`172.16.66/24 → utun4`）。这条链路有两种独立故障，修复方式完全不同，**必须分开判断**。

## 两种故障

| 故障 | 症状 | 根因 | 修复 |
|---|---|---|---|
| **A. 中转节点不可达** | `utun4` 还在、路由还在；`43.242.74.145:51820` 超时；`172.16.66.158:22` 超时 | beyond 的节点 IP 被墙/过载；客户端不会自动 fallback | 先重启 beyond 重握手；仍不通才临时用 QuickFox，恢复后立刻关掉 |
| **B. 隧道进程死亡** | 连 `utun4` 都没有；日志持续输出 `隧道进程未运行` | beyond App 重启后 root 隧道子进程没被 sudo-prompt 拉起 | 重启 beyond App 并确认 sudo 授权；QuickFox 救不了 |

**判断口诀**：先看 `utun4` 在不在，再看 `43.242.74.145:51820` 通不通，最后看 `172.16.66.158:22` 通不通。

- `utun4` 不在 → B 类，重启 App
- `utun4` 在但节点超时 → A 类，先重启 beyond；仍不通才考虑 QuickFox
- 目标通 → 正常，**不要开 QuickFox**（它会接管 DNS 和公网出口，有副作用）

### QuickFox 策略：如无必要不开

QuickFox 在本链路里不是「第二个 VPN」，而是 beyond 的**底层传输出口**。它能救 A 类故障，但代价是：

- 接管 DNS → 本机域名解析可能超时
- 公网出口整体变慢
- 长时间开着容易和 beyond 的路由互相干扰

所以本项目默认 `NJU_ENABLE_QUICKFOX=0`：

1. `--fix` 遇到 A 类故障，**先只重启 beyond**（多数情况到此就好）
2. 仍不通才提示你可以开 QuickFox，但**不会自动开**
3. 你若显式设 `NJU_ENABLE_QUICKFOX=1`，doctor 会临时开它，最多等 30 秒；**链路一恢复就自动关掉**
4. 用户自己手动开的 QuickFox，doctor 一律不动

`bin/doctor.sh --quickfox-off` 可以单独执行「关闭 doctor 开过的 QuickFox」。

## 用法

对**本机**跑（默认跳板 `macmini`，目标 `NJU-vscode`）：

```bash
./bin/doctor.sh                 # 一键诊断，输出状态表和结论
./bin/doctor.sh --fix            # 诊断 + 自动修复（优先重启 beyond，不轻易开 QuickFox）
./bin/doctor.sh --quickfox-off   # 关闭 doctor 之前临时启动的 QuickFox
./bin/doctor.sh --json           # 机器可读输出，方便接别的监控
./bin/doctor.sh --jump macmini --target NJU-vscode
```

对 **macmini 本机**跑（不经过 ssh）：

```bash
./bin/doctor.sh --local
```

退出码：`0` 正常；`1` 故障 A（或跳板不通、隧道假连接）；`2` 故障 B；`3` 配置错误。

实际输出示例（2026-10-27 实测）：

```text
==============================================
 nju-ssh-doctor  2026-10-27 10:08:33
 跳板: macmini   目标: NJU-vscode (172.16.66.158:22)
==============================================
跳板 ssh        ✅ 可达
beyond 网卡     ✅ utun4 = 100.64.0.249
隧道进程        ✅ 在跑
NJU 路由        ✅ 172.16.66/24 → utun4
中转节点        ✅ 43.242.74.145:51820
NJU 目标        ✅ 172.16.66.158:22  (RTT -)
ssh aliased     ✅ ssh NJU-vscode 可用
QuickFox        ⚠️  正在运行（接管 DNS/出口）
----------------------------------------------
✅ 链路正常（顺便：QuickFox 正开着，会接管 DNS 和公网出口；如非必要建议关掉）
→ 建议: 无需操作
==============================================
```

## 定时体检（可选）

```bash
sed -i '' "s#REPO_PATH#$(pwd)#" launchd/com.callmepikachu.nju-ssh-doctor.plist
cp launchd/com.callmepikachu.nju-ssh-doctor.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.callmepikachu.nju-ssh-doctor.plist
```

每 5 分钟跑一次 `bin/watchdog.sh`：正常时安静退出；故障 A 先尝试重启 beyond（开 QuickFox 需显式 `NJU_ENABLE_QUICKFOX=1`，且恢复后会关掉）；故障 B 自动重启 beyond App。日志在 `~/Library/Logs/nju-ssh-doctor.log`。

## 测试

```bash
./tests/run.sh
```

不依赖真实网络：用桩替换探测函数，覆盖 6 种状态判定、退出码映射和 JSON 合法性（12 项）。装了 `shellcheck` 会额外做静态检查。

## 目录结构

```text
nju-ssh-doctor/
├── bin/
│   ├── doctor.sh          入口（诊断 / --fix / --json / --local）
│   └── watchdog.sh        定时体检，供 launchd 调用
├── lib/
│   ├── probe.sh           各段探测（可单测）
│   ├── verdict.sh         状态 → 结论 → 建议
│   └── fix.sh             修复动作（幂等）
├── tests/run.sh           无网络单测
├── docs/
│   ├── troubleshooting.md 每个故障的完整排查日志与证据
│   └── case-study.md      本次事故复盘（2026-10-26）
├── examples/config.sh     默认参数（可用 ~/.config/nju-ssh-doctor/config.sh 覆盖）
└── launchd/               可选：定时体检
```

## 配置

所有参数都可用环境变量覆盖，常见几个：

```bash
NJU_JUMP_HOST=macmini           # 跳板别名
NJU_TARGET_HOST=NJU-vscode      # 目标别名
NJU_RELAY_IP=43.242.74.145      # beyond 中转节点（换节点时改这里）
NJU_TUN_ADDR=100.64.0.249       # utun4 地址
NJU_ENABLE_QUICKFOX=0           # 默认 0；设为 1 才允许 --fix 临时启用 QuickFox
```

也可以写在 `~/.config/nju-ssh-doctor/config.sh`，优先级高于仓库里的 `examples/config.sh`。

## 已知局限

- relay IP 是硬编码的默认值；beyond 换节点后需要改配置（不会自动从日志里抓）。
- `--fix` 对故障 B 只能拉起 App，sudo 授权仍需人工确认。
- QuickFox 接管 DNS 会影响本机其它依赖域名解析的工具；因此默认不自动启用，启用后也会用完即关。
- `quickfox_stop` 只退出 QuickFox 主 App，不主动杀 root 助手 `com.quickfox.tund`（避免误伤用户手动开的实例）。
- 只覆盖 macOS；Linux 下 `nc -G` / `ifconfig utun4` 的行为不同。

## 为什么不是一个大而全的脚本

这个链路跨越三台机器、两个 VPN 客户端、至少四种故障模式。单脚本能跑，但没法解释「为什么这么判」，也没法在故障演化后维护。仓库把它们拆成：探测（probe）→ 判定（verdict）→ 修复（fix）三层，任何一层都能单独替换或单测。

## 环境假设

- 本机：macOS，OpenSSH，`~/.ssh/config` 里已有 `macmini` 和 `NJU-vscode` 条目
- macmini：macOS，装了 beyond tunnel（`/Applications/beyond_tunnel.app`），可选 QuickFox（`/Applications/QuickFox.app`）
- NJU：`172.16.66.158:22`，公钥 `~/.ssh/id_ed25519`

## License

MIT
