# Tailscale 看门狗 (tailscale-guard)

飞牛 fnOS（fnOS/TRIM）应用：通过探测局域网内"哨兵设备"（手机、平板等随身设备）的在线状态，自动启停 Tailscale。

- 哨兵全部离线 → 推断主人已出门 → **自动启动 Tailscale**，便于外部远程访问 NAS
- 哨兵恢复在线 → 推断主人已回家 → **自动停止 Tailscale**，减少对外暴露面

## 工作原理

守护进程按固定间隔探测哨兵设备（IP 或 MAC），采用三级探测保证准确：

1. ICMP ping（容忍首包丢失）
2. ARP 表兜底（广播 ping 刷新 ARP 后查表，MAC 已解析即认为在线）
3. arping 直接发送 ARP 请求

探测结果汇入一个状态机，避免误判导致 VPN 频繁开关：

```
idle ──(连续 START_THRESHOLD 次满足启动条件)──▶ active
 │ ▲                                              │
 └─ retry(快速复测) ◀─────────────────────────────┘
      │                                           │
      └ 中途条件失效回 idle                (连续 STOP_THRESHOLD 次满足停止条件)
```

| 阶段 | 含义 | 探测间隔 |
|------|------|---------|
| `idle` | 正常待命 | `NORMAL_INTERVAL`（默认 600s） |
| `retry` | 疑似离线，快速复测 | `RETRY_INTERVAL`（默认 180s） |
| `active` | Tailscale 已启动，等待恢复 | `NORMAL_INTERVAL` |
| `paused` | 不在生效时段，不动 Tailscale | `NORMAL_INTERVAL` |

## 功能特性

- 哨兵设备支持 IP 或 MAC，可配置多个
- 启动/停止条件可配置：`all_offline` / `any_offline` / `all_online` / `any_online`
- 生效时段（支持跨天，如 `23:00-06:00`），时段外不干预
- 阈值防抖：连续 N 次命中才动作，避免网络抖动误触发
- 网页管理界面：实时状态、实时日志、配置、手动启停
- 配置修改即时生效（USR1 信号热重载）

## 目录结构

```
.
├── app/guard.sh          # 守护进程：哨兵探测 + Tailscale 自动启停（核心逻辑）
├── cmd/main              # 守护进程启停入口 {start|stop|restart|status}
├── cmd/*_init / *_callback  # fnOS 应用中心生命周期钩子（安装/卸载/升级/配置）
├── config/privilege      # 运行权限声明（root）
├── manifest              # fnOS 应用元数据（名称/版本/图标/描述）
├── ui/                   # 应用中心接入（iframe 入口、Web 管理页 CGI）
│   ├── config            # 应用中心入口描述（类型/图标/URL）
│   └── index.cgi         # Web 后端：/api/* 接口 + 静态文件路由
├── wizard/               # 安装向导（JSON 定义）
│   ├── install           # 安装向导：哨兵设备/时段/条件
│   └── uninstall         # 卸载向导：是否清除数据
├── www/index.html        # Web 管理界面（前端）
├── install.sh            # 手动安装脚本（免打包）
└── build.sh              # 构建脚本（生成 .fpk 发布包）
```

## 安装

### 方式一：应用中心安装（.fpk）

在源码根目录执行构建，得到发布包：

```bash
bash build.sh        # 生成 app.tgz 与 tailscale-guard-<版本>.fpk
```

然后在飞牛 NAS 应用中心 → 手动安装，选择生成的 `.fpk` 即可。

### 方式二：手动安装脚本

```bash
bash install.sh      # 需 root，且已安装 Tailscale 应用
```

脚本会把文件拷贝到系统对应路径并生成默认配置，之后刷新应用中心即可看到应用。

> 前置依赖：必须先通过飞牛应用中心安装 [Tailscale](https://tailscale.com/) 应用。

## 配置项

配置文件位于 `/vol1/@appdata/tailscale-guard/guard.conf`，也可在网页界面上修改。

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `SENTINELS` | `192.168.1.20` | 哨兵设备，IP 或 MAC，逗号分隔 |
| `NORMAL_INTERVAL` | `600` | 正常态探测间隔（秒） |
| `RETRY_INTERVAL` | `180` | 疑似离线复测间隔（秒） |
| `START_THRESHOLD` | `3` | 连续满足启动条件的次数，达到才启动 Tailscale |
| `START_CONDITION` | `all_offline` | 启动条件 |
| `STOP_THRESHOLD` | `1` | 连续满足停止条件的次数，达到才停止 Tailscale |
| `STOP_CONDITION` | `any_online` | 停止条件 |
| `EFFECTIVE_TIME` | 空 | 生效时段 `HHMM-HHMM`，留空=全天 |
| `LAN_IFACE` | `enp6s18` | 局域网网卡（ARP 探测用，按实际网卡修改） |

## 常见问题

**哨兵设备总是显示离线？**
先确认能 ping 通设备；手机锁屏/省电模式可能忽略 ping，建议改用设备的固定 IP 并关闭"仅 Wi-Fi 省电"。MAC 探测依赖 ARP 表，需设备与 NAS 在同一局域网。

**局域网网卡不对？**
`LAN_IFACE` 默认 `enp6s18`，请改成 NAS 实际局域网网卡（`ip addr` 查看），否则广播 ping/ARP 探测可能失败。

**改动配置后需要重启吗？**
不需要，保存后守护进程会收到 USR1 信号热重载。

**Tailscale 手动停止后又被自动启动？**
生效时段内只要满足启动条件守护进程就会拉起 Tailscale，这是预期行为。可把生效时段设为你外出的时间段。

## 版本历史

- **1.0.0**（首版）：双态探测、阈值控制、网页配置与日志查看；完整源码注释与构建脚本。

## 许可

第三方应用，基于 [Tailscale](https://tailscale.com/) 生态编写，本仓库仅提供应用编排逻辑，不含 Tailscale 本体。
