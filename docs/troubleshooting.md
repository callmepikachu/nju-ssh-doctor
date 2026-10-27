# 排查记录：从 `ssh -v NJU-vscode` 到根因

本文档是 `nju-ssh-doctor` 的原始排查过程，按时间顺序记录每一轮证据。目的是让后来的人（或半年后的自己）能复现每一步，而不是只看到「结论」。

## 环境

```text
本机          KeqindeMac-mini (macOS 26.5)  →  ssh NJU-vscode
跳板          macmini 10.127.124.33 (keqinpeng)
底 层出口     beyond tunnel / QuickFox
同网段        172.16.66.0/24，目标 172.16.66.158:22
```

`~/.ssh/config` 相关条目：

```sshconfig
Host NJU-vscode
    HostName 172.16.66.158
    User keqin
    Port 22
    ProxyJump macmini
    IdentityFile ~/.ssh/id_ed25519
```

---

## 第一轮：`ssh -v NJU-vscode`

```
debug1: Connecting to 10.127.124.33 [10.127.124.33] port 22.     ✅
debug1: Authenticated to 10.127.124.33 ... using "publickey".     ✅
debug1: channel_connect_stdio_fwd: 172.16.66.158:22               ✅ 通道建立
Connection timed out during banner exchange                       ❌ 卡在 ProxyJump 段内
```

**结论**：TCP 没到达 NJU 的 22 端口，远端机器根本没参与认证。问题在 macmini 到 172.16.66.158 这一跳，不是密钥/账号。

**排除的噪音**：`known_hosts2: No such file or directory`、`no identity pubkey loaded from id_ed25519` 都是 OpenSSH 10 的常规提示，与此故障无关。

---

## 第二轮：macmini 侧网络状态

```
route -n get 172.16.66.158  → destination: default, gateway: 10.127.120.1, interface: en1
netstat -rn                 → 172.16.66/24 → 100.64.0.249, utun4      (路由还在)
```

然后出现关键矛盾：**路由还在，但 ping 自己的隧道地址都超时**：

```
ping 100.64.0.249 → 100.0% packet loss
```

第一版结论（后来证实是错的）：

> 「macmini 的 Tailscale（utun4）断线了」

**错在哪**：先入为主假设快速通道 = 某个市面上的 VPN，然后对号入座。`utun4` 实际是 beyond tunnel 创建的。**教训：先看进程，再猜工具。**

---

## 第三轮：看进程（转折点）

```bash
# macmini 上
ps aux | grep -iE "beyond|tunel|tunnel|wg|clash|..." | grep -v grep
```

发现：

```
 435   keqinpeng  /Applications/beyond_tunnel.app/Contents/MacOS/beyond_tunnel
67445  root       /Applications/beyond_tunnel.app/Contents/MacOS/tunnel_for_darwin_arm64 -ppid 435
```

两个进程都活着，分别跑了 41 天 / 40 天。所以不是「进程没起」。

---

## 第四轮：进程活着但没动作 —— 看日志

日志路径：`~/Library/Logs/beyond_tunnel/main.log`

```
2026-10-26 20:23:39  testNodeConnection 43.242.74.145 51820
2026-10-26 20:23:44  TCP连接测试超时
2026-10-26 20:23:49  TCP连接测试超时
2026-10-26 20:23:54  TCP连接测试超时
2026-10-26 20:23:59  TCP连接测试超时
2026-10-26 20:24:05  [Network] 发起请求: .../smartwan/user/peers
2026-10-26 20:24:10  on mainWindow close
2026-10-26 20:36:54  断开连接，重置计时
```

20:36 断开之后，**日志里连续一个多小时一条「重连」记录都没有**，只有每 2 秒的 `隧道进程未运行` 刷屏（那时 App 主进程状态错乱，误判子进程不在）。

**结论**：客户端在 20:36 静默卡死，进程活着但没有任何重连逻辑触发。

---

## 第五轮：重启 App 反而制造了新故障

`kill` App → `open -a beyond_tunnel.app` 之后：

```
[2026-10-26 22:35:35] 使用sudo-prompt启动macOS隧道服务
[2026-10-26 22:35:35] 执行命令: ".../tunnel_for_darwin_arm64" -ppid 32651
[2026-10-26 22:35:37] 隧道进程未运行
[2026-10-26 22:35:39] 隧道进程未运行
...（每 2 秒一次，一直刷）
```

`tunnel_for_darwin_arm64` 没起来，于是连 `utun4` 都没了。这是 **B 类故障**（需要 sudo 授权）。

后来手动在 App 里点连接（22:44）才恢复：

```
2026-10-26 22:44:xx  确认隧道进程正在运行
2026-10-26 22:44:xx  隧道服务授权状态变更: true
```

---

## 第六轮：`utun4` 恢复但仍然不通 —— 定位 A 类故障

```
ifconfig utun4 | grep inet          → 100.64.0.249                ✅
netstat -rn | grep 172.16.66        → 172.16.66/24 → utun4        ✅
nc -zv 172.16.66.158 22             → Operation timed out         ❌
ping 172.16.66.158                  → 100.0% packet loss          ❌
```

再单独测节点：

```
nc -zv 43.242.74.145 51820          → Operation timed out
ping 43.242.74.145                  → 100.0% packet loss
```

**这是 A 类故障**：网卡在、路由在，但中转节点根本不可达。客户端却仍然维持「已连接」的假象。

---

## 第七轮：API 下发的节点全是同一个 IP

日志里的 `nodes` 块：

```text
nodes [
  { id:34, name:'华南电信', ip:'43.242.74.145', port:51820 },
  { id:29, name:'成都',     ip:'43.242.74.145', port:51820 },
  { id:31, name:'武汉',     ip:'43.242.74.145', port:51820 },
  { id:32, name:'北京',     ip:'43.242.74.145', port:51820 }
]
```

四行名字不同、**IP 完全相同**。所以在 App 里「换节点」无效；这不是本机配置问题，而是服务端下发的问题。

同时 `edges`（用户自有网络节点）`last_active` 都是刚刚：

```text
suzhou          10.168.100.0/24   last_active 1793040320
信管100.99       192.168.100.0/24  last_active 1793040298
创业大厦         172.16.77.0/24    last_active 1793040281
陆老师1.1        192.168.1.0/24    last_active 1793040257
172.16.66.0     172.16.66.0/24     last_active 1793040306
```

所以 NJU 侧的机器是活的，问题只在 beyond 的中转节点。

---

## 第八轮：QuickFox 救场

在 macmini 上打开 QuickFox（`/Library/PrivilegedHelperTools/com.quickfox.tund` 起来）后：

```
nc 172.16.66.158:22      → succeeded      ✅
ping 172.16.66.158       → 0% loss, RTT 507~988ms   ✅
nc 43.242.74.145:51820   → succeeded      ✅
```

**机制**：QuickFox 接管了公网出口，把到 `43.242.74.145:51820` 的底层流量绕出去了，beyond 的中转节点才握得上手。所以 QuickFox 在这里的角色不是「第二个 VPN」，而是 **beyond 的底层出口**。

副作用：

```
curl https://api.ipify.org → Resolving timed out   ❌
```

QuickFox 接管了 DNS，本机一些依赖域名解析的工具会受影响。

---

## 最终结论

| 故障 | 判据 | 修复 |
|---|---|---|
| **A. 中转节点不可达** | `utun4` 在、路由在、`43.242.74.145:51820` 超时 | 开 QuickFox 当底层出口 |
| **B. 隧道进程死亡** | `utun4` 不在、无 `tunnel_for_darwin_arm64` | 重启 beyond App 并确认 sudo 授权 |
| 跳板不可达 | 连 `macmini` 都 ssh 失败 | 与本故障无关，先修本机网络 |

「两个 VPN 都开着才通」不是常态，而是 A 类故障下的临时状态。正常情况只需要 beyond。`bin/doctor.sh` 就是把这个判断固化成可执行的检查。
## 第八轮补充：QuickFox 策略改为「如无必要不开」

最初版本让 `--fix` 在 A 类故障时直接启 QuickFox，并且开着不关。实际使用后发现两个问题：

1. QuickFox 会接管 DNS，`curl https://api.ipify.org` 直接 `Resolving timed out`，影响本机其它工具。
2. 它和 beyond 的路由会互相干扰，长时间共存状态不稳定。

于是修正策略（用户要求）：

- **默认 `NJU_ENABLE_QUICKFOX=0`**，`--fix` 遇到 A 类故障先只重启 beyond
- 只有显式设 `NJU_ENABLE_QUICKFOX=1` 才临时启用，最多等 30 秒
- 链路恢复后立即 `quickfox_stop` 关掉主 App
- 用户手动开的 QuickFox，doctor 不碰（用 state 文件区分）

验证：

```
$ ./bin/doctor.sh --quickfox-off        # 无 mark 时
  [跳过] QuickFox 不是 doctor 启动的，不动它
```