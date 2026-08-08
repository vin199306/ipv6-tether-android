# IPv6 Tethering for Android 4.4

让 Android 4.4 设备通过 USB 共享 / WiFi 热点向客户端分发 IPv6，支持访问纯 IPv6 网站。

## 工作原理

Android 4.4 原生不支持将移动数据 IPv6 分发给 tethering 客户端。本方案通过三个组件实现：

```
移动数据(rmnet_data0)  ←──IPv6前缀───  运营商
        │
    NDP Proxy 代理  ←──转发邻居发现───┐
        │                            │
    bridge1 (USB+WiFi桥接)           │
        │                            │
    ┌───┴───┐                         │
    │RA发送│──组播RA→ 客户端(SLAAC获取地址)
    │DHCPv6│──分发DNS+默认路由
    └───────┘
```

- **send_ra**：发送 Router Advertisement，让客户端通过 SLAAC 自动配置 IPv6 地址、默认路由和 DNS
- **dhcp6_server**：提供 DHCPv6 服务，补充分发 DNS 和路由（可选）
- **NDP Proxy**：代理客户端的邻居发现请求，让运营商网关能看到客户端

## 系统要求

| 项目 | 要求 |
|------|------|
| 系统 | Android 4.4 (已测试)，理论兼容 4.x ~ 7.x |
| Root | **必须**（需 Magisk 或 SuperSU） |
| busybox | **必须**（Magisk 自带） |
| 运营商 | 需支持 IPv6（电信/联通/移动 4G 多数支持） |
| 架构 | ARMv7（二进制已预编译，覆盖绝大多数设备） |

## 快速部署

### 1. 准备工作

- 确保手机已 Root 并安装 Magisk
- 确保手机移动数据已获取 IPv6（可在手机拨号 `*#*#4636#*#*` 查看网络信息）
- PC 安装 [Android Platform Tools](https://developer.android.com/studio/releases/platform-tools)（含 adb）
- 用 USB 连接手机，开启 USB 调试并授权 PC

### 2. 一键安装

双击运行 `install.bat`，脚本会自动：
1. 检查 adb 和设备连接
2. 推送所有文件到 `/data/local/tmp/`
3. 提权执行部署脚本（请在手机上授权 root）
4. 安装 Magisk 开机自启
5. 启动 IPv6 共享服务

### 3. 验证

**手机端验证：**
```bash
adb shell "su -c 'sh /data/local/tmp/ipv6_tether.sh status'"
```
应看到 RA sender / DHCPv6 / NDP loop 三个服务 Running，且有 bridge1 IPv6 地址。

**客户端验证：**
1. PC 通过 USB 共享或手机开启 WiFi 热点连接
2. 打开浏览器访问 https://test-ipv6.com/
3. 应获得 **10/10** 评分，显示公网 IPv6 地址

## 文件说明

```
ipv6_tether_pack/
├── send_ra              # RA 发送器（ARM 二进制）
├── dhcp6_server         # DHCPv6 服务器（ARM 二进制）
├── ipv6_tether.sh       # 主控脚本（start/stop/status）
├── ipv6_tether_boot.sh  # Magisk 开机自启脚本
├── deploy.sh            # 设备端部署脚本
├── config.conf          # 配置文件
├── install.bat          # PC 端一键安装（Windows）
├── uninstall.bat        # PC 端一键卸载（Windows）
└── README.md            # 本文档
```

## 配置说明

编辑 `config.conf`，修改后重新部署或重启服务：

```bash
# 修改配置后重启服务生效
adb shell "su -c 'sh /data/local/tmp/ipv6_tether.sh restart'"
```

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `IFACE_WAN` | `rmnet_data0` | 上行网卡（移动数据），电信/联通/移动通用 |
| `IFACE_UP` | `bridge1` | 下行桥接接口（USB共享+WiFi热点） |
| `RA_INTERVAL` | `3` | RA 发送间隔（秒） |
| `RA_MTU` | `1280` | RA 宣告的 MTU（修改需重新编译） |
| `DNS_SERVERS` | `2400:3200::1,...` | 分发的 IPv6 DNS |
| `DHCP6_ENABLE` | `1` | 是否启用 DHCPv6 |
| `NDP_INTERVAL` | `5` | NDP 代理扫描间隔（秒） |
| `BOOT_AUTOSTART` | `1` | 是否安装开机自启 |

### 不同运营商的接口名

如默认 `rmnet_data0` 不工作，可通过以下命令查看实际上行接口：
```bash
adb shell "ip -6 addr show | grep 'scope global'"
```
常见接口名：
- 高通平台：`rmnet_data0` / `rmnet0`
- MTK平台：`ccmni0`
- 某些机型：`tun0`（若走了 VPN）

## 命令手册

| 操作 | 命令 |
|------|------|
| 查看状态 | `adb shell "su -c 'sh /data/local/tmp/ipv6_tether.sh status'"` |
| 启动服务 | `adb shell "su -c 'sh /data/local/tmp/ipv6_tether.sh start'"` |
| 停止服务 | `adb shell "su -c 'sh /data/local/tmp/ipv6_tether.sh stop'"` |
| 重启服务 | `adb shell "su -c 'sh /data/local/tmp/ipv6_tether.sh restart'"` |
| 查看前缀 | `adb shell "su -c 'sh /data/local/tmp/ipv6_tether.sh _getprefix'"` |

## 开机自启

部署时若 `config.conf` 中 `BOOT_AUTOSTART=1`，会自动安装到 Magisk 的 `/data/adb/service.d/`，开机后：

1. 等待移动数据 IPv6 就绪（最长 200 秒）
2. 自动启动 IPv6 共享服务
3. 持续监控：前缀变化或服务崩溃时自动重启

如需手动安装/卸载自启：
```bash
# 安装
adb shell "su -c 'cp /data/local/tmp/ipv6_tether_boot.sh /data/adb/service.d/ && chmod 755 /data/adb/service.d/ipv6_tether_boot.sh'"

# 卸载
adb shell "su -c 'rm -f /data/adb/service.d/ipv6_tether_boot.sh'"
```

## 卸载

双击 `uninstall.bat`，会停止服务并删除所有文件和开机自启项。

## 常见问题

### Q: 客户端获取不到 IPv6 地址？

排查步骤：
1. 确认手机自身有 IPv6：`adb shell "ip -6 addr show rmnet_data0 | grep scope\ global"`
2. 确认服务运行：`status` 命令查看三个服务是否 Running
3. 确认 bridge1 有地址：`status` 输出中 `bridge1 IPv6` 应有 `${PREFIX}::1`
4. 确认 multicast_snooping=0：`status` 输出中 `mcast_snoop` 应为 0
5. 重启客户端网卡（禁用再启用），强制重新请求 RA

### Q: 评分只有 1/10，提示"较大数据包传输失败"？

这是 MTU 不匹配问题。RA 宣告的 MTU=1280 已预置，若仍失败：
- 检查客户端是否应用了 RA MTU（Windows: `Get-NetIPInterface -AddressFamily IPv6`）
- 若客户端忽略 RA MTU，可手动设置：`netsh interface ipv6 set subinterface "WLAN" mtu=1280`

### Q: 客户端能 ping 通网关但无法上网？

路由冲突问题，脚本已自动处理（删除 WAN 的 /64 路由）。若仍异常：
```bash
adb shell "su -c 'ip -6 route show'"
```
确认 `default via` 指向 `rmnet_data0` 的链路本地网关。

### Q: 重启手机后服务没启动？

1. 确认 Magisk 已安装：`adb shell "su -c 'ls /data/adb/service.d/'"`
2. 确认自启脚本存在：应看到 `ipv6_tether_boot.sh`
3. 查看 Magisk 日志：`adb shell "su -c 'cat /data/adb/magisk.log | grep ipv6'"`

### Q: 不是 ARM 架构怎么办？

本包二进制为 ARMv7。如设备是 x86（如部分模拟器）或 ARM64 但不支持 32 位，需自行交叉编译：
```bash
# ARM64
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o send_ra send_ra.go
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o dhcp6_server dhcp6_server.go

# x86
GOOS=linux GOARCH=386 CGO_ENABLED=0 go build -o send_ra send_ra.go
GOOS=linux GOARCH=386 CGO_ENABLED=0 go build -o dhcp6_server dhcp6_server.go
```

### Q: 不同运营商 DNS 推荐？

| 运营商 | 主 DNS | 备 DNS |
|--------|--------|--------|
| 通用(阿里) | `2400:3200::1` | `2400:3200:baba::1` |
| 电信 | `240e::1` | `240e:a::1` |
| 联通 | `2408:8899::8` | `2408:8888::8` |
| 移动 | `2409:8080::a0a0` | `2409:8080:2000::a0a0` |
| Google | `2001:4860:4860::8888` | `2001:4860:4860::8844` |

## 技术细节

### RA 报文关键参数

- **Flags**: M=0, O=0（纯 SLAAC，地址/路由/DNS 全由 RA 下发）
- **Hop Limit**: 255（RFC 4861 要求，否则 Windows 忽略 RA）
- **Prefix Info**: L=1, A=1（链路本地+自动配置），preferred=14400s, valid=86400s
- **MTU**: 1280（IPv6 最小值，规避移动网络 1432 MTU 的分片问题）
- **RDNSS**: 携带 DNS 服务器（RFC 8106）

### 关键内核参数

| 参数 | 值 | 作用 |
|------|----|------|
| `conf/all/forwarding` | 1 | 开启 IPv6 转发 |
| `conf/rmnet_data0/proxy_ndp` | 1 | 开启 NDP 代理 |
| `bridge/multicast_snooping` | 0 | 关闭组播窥探，放行 RA |
| `bridge-nf-call-ip6tables` | 0 | 避免 bridge 流量被 ip6tables 拦截 |

### 为什么用 NDP Proxy 而非 NAT66？

Android 4.4 内核不支持 ip6tables NAT（ip6t_NAT 模块缺失），无法做 NAT66。NDP Proxy 让客户端地址直接出现在运营商 /64 前缀内，无需地址转换，更符合 IPv6 设计理念。

### 为什么删除 WAN 的 /64 路由？

bridge1 和 rmnet_data0 共享同一 /64 前缀，若两者都有 /64 on-link 路由，返回包会走错接口导致丢包。删除 WAN 的 /64 路由，让所有 /64 流量走 bridge1。
