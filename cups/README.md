# CUPS 打印服务镜像

独立于 cups-web 主应用的 CUPS 打印服务容器，预装大量打印机驱动，通过 `docker-compose.yml` 与 cups-web 组合部署。

## 文件结构

| 文件 | 角色 |
|---|---|
| `Dockerfile` | 镜像构建骨架：Debian 13 Trixie 基础 → 装依赖 → 跑安装脚本 → 配置 cupsd |
| `entrypoint.sh` | 容器启动脚本：创建管理员 → 还原配置 → HP 固件/PPD 修补 → 拉起 avahi/ipp-usb → 启动 cupsd |
| `scripts/` | 10 个独立 shell 脚本，每个处理一种驱动/组件的安装，版本号和 URL 硬编码在脚本内 |

## 构建策略

### 三阶段构建

```
1. apt 安装依赖（编译工具链 + cups-filters 全家桶 + CUPS 打印生态）
2. COPY scripts/ 并依次执行各安装脚本（每个驱动一个 RUN，缓存粒度最优）
3. 修改 cupsd.conf 配置 + 清理编译工具链 + 挂载 VOLUME
```

### CUPS 版本策略

**不 `apt install cups`**，而是让 cups-filters 把 apt 版 cups 作为依赖拉进来——它负责创建 `lp`/`lpadmin` 用户组、`/etc/cups` 目录骨架和 systemd unit 文件。随后用 **OpenPrinting/cups v2.4.19 源码编译** 出的二进制覆盖掉 apt 版（`libcups.so.2`、`cupsd`、cups-client 等），即：

- 保留 Debian 侧的集成脚手架（用户组、目录、PPD 索引）
- 替换成 OpenPrinting 上游最新 CUPS，且 libcups2 ABI 兼容，cups-filters 和所有 printer-driver-\* 继续可用
- v2.4.x 维持 libcups2 ABI 稳定；v3.x 切换到 CMake 构建并移除了经典驱动模型（printer-driver-\* 大量失效），故暂不跟

### 驱动下载策略

所有驱动文件（`.deb`、`.tar.gz`、固件）从 **本仓库自建 GitHub Releases 镜像**（`cups-driver` tag）下载，而非依赖各厂商 CDN，原因是：

- Epson 官方下载中心挂在 Akamai CDN 后，UA/Header/TLS 指纹多维度风控，UUID 定期轮换
- Canon 官方 GDS URL 跟随版本号路径变化，直接下载在 CI 里不稳定
- 柯尼卡美能达原始 `.7z` 来自 IIS 跳 CloudFront 签名 URL
- Sharp 官方 CDN 同有 CI 稳定性问题

所有脚本采用 **fail-fast** 策略：下载或 dpkg 任一步失败立即非零退出，确保发布镜像里不会因为某个 URL 失效而悄悄不含对应驱动。

### 编译工具链清理

编译完成后 `cleanup-build.sh` 做：

1. **保护运行时库**：`apt-mark manual` 标记 cupsd 运行时依赖的动态库（`libgnutls30`、`libldap-*`、`libdbus-1-3` 等），防止 autoremove 把源码编译出的 cupsd 不认识依赖而误删孤儿库
2. **purge -dev 包 + 编译器**：`build-essential`、`autoconf`、`lib*-dev` 等全部清理
3. **apt autoremove + clean**：回收约 500MB 磁盘空间

## 驱动覆盖一览

| 脚本 | 覆盖范围 | 架构 | 安装方式 |
|---|---|---|---|
| `install-cups.sh` | CUPS 本体 v2.4.19 | 全架构 | 源码编译 (`./configure --prefix=/usr`) |
| `install-escpr2.sh` | Epson 新款喷墨（ET-18100/L8050/L8160/WF-7840 等） | amd64/armhf→预编译 deb；arm64→源码编译 | Epson 官方源码，GCC 15 宽容 CFLAGS |
| `install-canon-capt.sh` | Canon LBP2900/LBP2900B（issue #43） | 全架构 | 开源逆向工程（GPL-3.0），纯 C 源码编译 |
| `install-canon-ufr2.sh` | Canon UFR II / UFRII LT 激光机（issue #34） | amd64 + arm64 | Canon 官方闭源 .deb（v6.30），armhf 无二进制 skip |
| `install-konica-bizhub.sh` | 柯尼卡美能达 bizhub 3000MF（issue #35） | amd64 + arm64 | 国产化平台 .deb 重新打包 tar.gz；armhf 无包 skip |
| `install-gutenprint.sh` | Gutenprint 通用打印驱动 | amd64 + arm64 | apt 安装；trixie armhf 无 binary，条件跳过 |
| `install-epson-cn.sh` | Epson 国行私驱（L380/L455 等） | 仅 amd64 | 闭源 .deb，镜像到 GitHub Releases |
| `install-hp-laserjet1020.sh` | HP LaserJet 1020/1020 Plus（issue #40 #48） | 全架构 | 下载固件 + 派生 A4-default PPD |
| `install-sharp.sh` | Sharp MX-C2622R PostScript（issue #39） | 全架构 | PPD 纯文本，无需架构相关二进制 |
| `cleanup-build.sh` | 清理编译工具链 | 全架构 | purge + apt-mark manual 保护运行时库 |

### apt 预装的额外驱动

Dockerfile 通过 `apt install` 还预装了：

- **printer-driver-all**：Debian 官方打印机驱动全家桶
- **printer-driver-foo2zjs**：基于 foo2zjs 的通用激光驱动（HP 1020 / 1018 / 1005 / P100x 等 host-based 机型）
- **printer-driver-brlaser**：社区维护的 Brother 激光机驱动（HL-L2300D 等老机型）
- **ipp-usb + avahi-daemon**：USB 直连 IPP Everywhere 发现（Brother DCP-T425W 等新墨仓机型走 driverless 路径）

### 架构覆盖总结

| 架构 | 覆盖情况 |
|---|---|
| **amd64** | 全驱动覆盖（含 Epson 国行、Canon UFR II、柯尼卡美能达等仅 amd64 有包的驱动） |
| **arm64** | 主力驱动覆盖（树莓派 4/5、Apple Silicon），仅 Epson 国行闭源驱动缺失 |
| **armhf** (32-bit ARM) | 基础覆盖；gutenprint/Canon UFR II/Epson 国行/柯尼卡美能达因缺少 32-bit ARM 二进制而跳过 |

## cupsd.conf 配置

Dockerfile 中对 `/etc/cups/cupsd.conf` 做了以下修改：

- `Listen localhost:631` → `Listen 0.0.0.0:631`：接受来自其他容器的 IPP 请求
- `Browsing Off` → `Browsing On`：启用打印机共享广播
- 管理路径（`/`、`/admin`、`/admin/conf`）添加 `Allow All`
- `ServerAlias *`：允许任意 Host 头访问
- `DefaultEncryption Never`：关闭默认加密

构建时备份到 `/etc/cups-bak`，容器首次启动时若挂载卷为空则从备份还原。

## entrypoint.sh 启动流程

启动时按顺序执行：

### 1. 创建 CUPS 管理员

```bash
useradd -r -G lpadmin -M $CUPSADMIN   # 默认 print
echo $CUPSADMIN:$CUPSPASSWORD | chpasswd  # 默认 print
```

环境变量 `CUPSADMIN` / `CUPSPASSWORD` 可覆盖默认值。

### 2. 还原默认配置

如果挂载卷 `/etc/cups` 中没有 `cupsd.conf`（首次启动），从 `/etc/cups-bak` 恢复。

### 3. HP 1020 存量 PPD Letter → A4 修补（Issue #48）

遍历 `/etc/cups/ppd/*.ppd`，对同时满足以下条件的 PPD 做原地修补：

- `*Product: "(HP LaserJet 1020)"`
- `*FoomaticIDs: HP-LaserJet_1020 foo2zjs-z1`
- 当前 `*DefaultPageSize` 是 Letter（用户未改过）
- `*PageSize` 列表里包含 A4

将四组 `*Default*: Letter` 改为 A4（PageSize / PageRegion / ImageableArea / PaperDimension），修改前备份为 `.bak-cupsweb-issue48`。

> 背景：foo2zjs 上游 HP 1020 PPD 默认纸张为 Letter，苹果 AirPrint 按 `media-default` 渲染首屏纸张选项时会把 A4 折叠/隐藏。

### 4. HP host-based 打印机固件上传（Issue #40 #48）

HP LaserJet 1020 / 1018 / 1005 / P100x / P1505 等 GDI/host-based 机型每次上电需由主机上传固件（`sihp1020.dl` 等）才能进入工作状态。物理机上由 udev 规则触发，容器内无 udev daemon，因此手动调用 `/usr/lib/udev/hplj1020`。

后台执行、不阻塞 cupsd 启动；固件上传完成后打印机切到 ready 态。

### 5. 拉起 avahi-daemon + ipp-usb

- **avahi-daemon**：mDNS 服务发现（Bonjour/AirPrint 协议栈必需）
- **ipp-usb**：把 USB 直连的 IPP Everywhere 打印机暴露为本地 HTTP IPP 端点（Brother DCP-T425W 等新机型依赖此通道）

两者均允许缺失（某些架构可能未安装相关包），失败不影响 cupsd 启动。

### 6. 启动 cupsd

```bash
exec /usr/sbin/cupsd -f
```

前台运行，保证容器不退出。

## 已知问题：USB 打印机断电重连后不继续打印

### 现象

打印机断电 → `lsusb` 无设备 → 打印任务卡在 "processing" → 重新上电 → `lsusb` 有设备 → 但任务不会自动恢复 → 重启 cupsd 后才继续打印。

### 根因

CUPS 的 `usb` backend 是 **被动模式**——只在有任务提交时才 `open()` 设备节点。设备断电后当前任务持有的 fd 失效，CUPS 默认 `printer-error-policy` 是 `stop-printer`——backend 连续失败时 CUPS 把打印机标记为 stopped，后续任务排队不发送。即使设备重新上线，stopped 状态的打印机不会自动恢复。CUPS 也没有主动轮询 USB 设备是否重新出现的机制。

### 解决方案

**方案 1（推荐）：修改打印机的 ErrorPolicy**

```bash
lpadmin -p <打印机名> -o printer-error-policy=retry-this-job
```

这样 USB backend 失败时不会 stop 打印机，而是持续重试当前作业。打印机重新上电后下一次重试就会成功。

CUPS 支持的 error policy：
- `stop-printer`（默认）：失败就停打印机
- `retry-this-job`：无限重试当前作业，不阻塞队列
- `abort-job`：直接丢弃失败作业，继续下一个

**方案 2：容器内加设备节点监听 watchdog**

在 entrypoint.sh 中 cupsd 启动后，加一个后台脚本检查 stopped 打印机的设备节点是否重新出现，自动 `cupsenable`：

```bash
(
    while true; do
        sleep 5
        for p in $(lpstat -p 2>/dev/null | grep -E 'disabled|Unable to locate' | awk '{print $2}'); do
            uri=$(lpstat -v "$p" 2>/dev/null | awk '{print $NF}')
            if echo "$uri" | grep -q '^usb://'; then
                devfile=$(echo "$uri" | sed 's|usb://[^/]*/||')
                if [ -e "/dev/usb/$devfile" ] || [ -e "/dev/$devfile" ]; then
                    echo "[watchdog] re-enabling $p (device node reappeared)"
                    cupsenable "$p" 2>/dev/null
                fi
            fi
        done
    done
) &
```

**方案 3：用 `lpstat -e` + `lsusb` 做更可靠的自动恢复**

方案 2 依赖设备节点路径精确匹配（`/dev/usb/lp0` 等），但某些内核/USB 子系统在设备重连后可能分配不同的设备节点路径。`lpstat -e` 是 CUPS 自带的"枚举所有可用设备"命令——它会调用各 backend 的发现模式直接扫描硬件，不受设备节点路径变化的影响。用它与 `lsusb` 交叉验证更可靠：

```bash
(
    while true; do
        sleep 10
        # 收集当前所有 USB 打印机设备 ID（vendor:product），用于和 lsusb 交叉验证
        AVAILABLE_IDS=""
        while IFS= read -r devline; do
            # lpstat -e 输出 usb:// 行
            if echo "$devline" | grep -q '^usb://'; then
                # 从 usb://VID%2FPID%2Fserial?... 提取 VID:PID
                vidpid=$(echo "$devline" | sed 's|usb://\([^?]*\).*|\1|' | sed 's|%2F|:|g')
                AVAILABLE_IDS="$AVAILABLE_IDS $vidpid"
            fi
        done <<EOF
$(lpstat -e 2>/dev/null)
EOF

        # 遍历所有 stopped 的 USB 打印机，检查其设备是否在可用列表中
        for p in $(lpstat -a 2>/dev/null | grep 'not accepting' | awk '{print $1}'); do
            uri=$(lpstat -v "$p" 2>/dev/null | awk '{print $NF}')
            if echo "$uri" | grep -q '^usb://'; then
                vidpid=$(echo "$uri" | sed 's|usb://\([^?]*\).*|\1|' | sed 's|%2F|:|g')
                if echo "$AVAILABLE_IDS" | grep -qi "$vidpid"; then
                    echo "[watchdog] re-enabling $p (USB device $vidpid reappeared via lpstat -e)"
                    cupsenable "$p" 2>/dev/null
                    accept "$p" 2>/dev/null
                fi
            fi
        done
    done
) &
```

方案 3 比方案 2 更健壮的原因：

- **不依赖设备节点路径**：`lpstat -e` 直接调用 CUPS usb backend 的发现模式（`libusb` 枚举），不关心 `/dev/usb/lp0` 还是 `/dev/bus/usb/001/003`
- **Vendor:Product ID 精确匹配**：用 USB VID:PID 指纹比对打印机，不会误匹配同品牌的键盘/鼠标等 HID 设备
- **无需 root 或 `--device` 挂载特定节点**：libusb 走 `/dev/bus/usb/` 的 usbfs 接口，只要容器挂载了 `/dev/bus/usb` 就能扫描全总线
