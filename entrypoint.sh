#!/bin/bash
set -e

# ══════════════════════════════════════════════════════════════
# 1. Restore persisted drivers
# ══════════════════════════════════════════════════════════════
# 驱动恢复是"尽力而为"的操作：快照目录可能只读、可能是旧版本写坏的快照、
# 目标路径可能已被别的包占用成目录。这些都不该阻塞 cupsd / cups-web 启动
# （否则容器起不来，用户连 Web UI 都进不去，无法自救删掉坏驱动）。
# restore-drivers 自身已不使用 set -e 并会汇总失败数，这里再加一层 `|| true`
# 语义的兜底，防止它因意外信号/非零退出把 set -e 的 entrypoint 带崩。
/usr/local/bin/restore-drivers || echo "[entrypoint] WARN: restore-drivers 部分失败，继续启动"

# ══════════════════════════════════════════════════════════════
# 2. CUPS admin user setup (from cups/entrypoint.sh)
# ══════════════════════════════════════════════════════════════
if [ $(grep -ci $CUPSADMIN /etc/shadow) -eq 0 ]; then
    useradd -r -G lpadmin -M $CUPSADMIN

    # add password
    echo $CUPSADMIN:$CUPSPASSWORD | chpasswd

    # add tzdata
    ln -fs /usr/share/zoneinfo/$TZ /etc/localtime
    dpkg-reconfigure --frontend noninteractive tzdata
fi

# ══════════════════════════════════════════════════════════════
# 3. CUPS config restore (from cups/entrypoint.sh)
# ══════════════════════════════════════════════════════════════
# restore default cups config in case user does not have any
if [ ! -f /etc/cups/cupsd.conf ]; then
    cp -rpn /etc/cups-bak/* /etc/cups/
fi

# ── 下面两条对**存量卷**做幂等修补 ────────────────────────────────────────
# ⚠️ 上面那个 if 只看 cupsd.conf 一个文件。挂载的 ./.etc 卷里如果已经有一份（旧版本
# 留下的、或用户从别处拷来的）cupsd.conf，整块还原就被跳过 —— 于是新版镜像在基线里
# 加的东西，存量用户永远拿不到。所以需要在 if **之外**单独补。

# ① ssl 目录：cupsd 自己不会建（见 Dockerfile 里的说明），缺了它 ipps/AirPrint
#    握手会失败并在 error_log 刷 "Unable to create server credentials"。
#    无条件保证存在，代价只是一次 mkdir。
mkdir -p /etc/cups/ssl 2>/dev/null || true
chmod 700 /etc/cups/ssl 2>/dev/null || true

# ② ReadyPaperSizes：iPhone AirPrint 面板的纸张列表读 IPP media-ready，而 CUPS 的
#    media-ready 只由 ReadyPaperSizes ∩ PPD 尺寸决定（跟 media-default 无关，所以
#    `lpadmin -o media=` 修不了它）。不配时按 locale 兜底成 Letter,Legal,... → A4
#    永远不出现（issue #82）。
#    只在用户完全没写过这一项时追加，绝不覆盖用户的显式配置。
if [ -f /etc/cups/cupsd.conf ] && ! grep -qiE '^[[:space:]]*ReadyPaperSizes' /etc/cups/cupsd.conf; then
    echo "ReadyPaperSizes A4,A3,A5,A6,EnvDL" >> /etc/cups/cupsd.conf
    echo "[entrypoint] 已为存量配置追加 ReadyPaperSizes（A4 系列），让 AirPrint 面板能选到 A4（issue #82）"
fi

# ══════════════════════════════════════════════════════════════
# 4. HP 1020 PPD Letter→A4 patch (from cups/entrypoint.sh)
# ══════════════════════════════════════════════════════════════
# ── 已添加 HP 1020 打印机的默认纸张 Letter → A4 一次性修补 ──
# issue #48：foo2zjs 上游 HP-LaserJet_1020 PPD 的 *DefaultPageSize 是 Letter。
# 苹果设备走 AirPrint（IPP）时按 media-default 渲染首屏纸张，Letter 默认会让
# 国内常用的 A4 在 iPhone 打印面板里被折叠/隐藏，用户反映"无 A4 选项"。
#
# 已通过 install-hp-laserjet1020.sh 在 /usr/share/cups/model/HP/ 安装了 A4-default
# 变体 PPD，新加的打印机可以直接选这版。但已经按"(recommended)"加好的存量打印机
# 不会自动迁移——它们的 PPD 副本在 /etc/cups/ppd/<printer>.ppd，仍是 Letter 默认。
#
# 这里在 cupsd 启动前对存量副本做一次性原地修补：
#   - 仅处理 foo2zjs HP 1020 PPD（用 *Product 和 *FoomaticIDs 双重指纹）
#   - 仅当当前 *DefaultPageSize 是 Letter（用户没在 CUPS UI 里改过默认纸张）
#   - 仅当 *PageSize 列表里确实声明了 A4
#   - 三个条件都满足才把四组 *Default*: Letter 同步改成 A4
# 任何一条不满足就跳过，不会覆盖用户的显式选择，也不会处理非 HP 1020 的 PPD。
# 修改前先备份成 .bak-cupsweb-issue48，方便用户回退。
if [ -d /etc/cups/ppd ]; then
    for ppd in /etc/cups/ppd/*.ppd; do
        [ -f "$ppd" ] || continue
        grep -q '^\*Product:[[:space:]]*"(HP LaserJet 1020)"' "$ppd" || continue
        grep -q '^\*FoomaticIDs:[[:space:]]\+HP-LaserJet_1020[[:space:]]\+foo2zjs-z1' "$ppd" || continue
        grep -q '^\*DefaultPageSize:[[:space:]]\+Letter[[:space:]]*$' "$ppd" || continue
        grep -q '^\*PageSize A4' "$ppd" || continue

        cp -p "$ppd" "${ppd}.bak-cupsweb-issue48"
        sed -i -E '
            s/^\*DefaultPageSize:[[:space:]]+Letter[[:space:]]*$/\*DefaultPageSize: A4/;
            s/^\*DefaultPageRegion:[[:space:]]+Letter[[:space:]]*$/\*DefaultPageRegion: A4/;
            s/^\*DefaultImageableArea:[[:space:]]+Letter[[:space:]]*$/\*DefaultImageableArea: A4/;
            s/^\*DefaultPaperDimension:[[:space:]]+Letter[[:space:]]*$/\*DefaultPaperDimension: A4/
        ' "$ppd"
        echo "[entrypoint] patched $ppd: HP 1020 default paper Letter → A4 (issue #48; backup at ${ppd}.bak-cupsweb-issue48)"
    done
fi

# ══════════════════════════════════════════════════════════════
# 5. HP host-based firmware upload (from cups/entrypoint.sh)
# ══════════════════════════════════════════════════════════════
# ── HP host-based 打印机固件上传（issue #48 真正的修复点） ────────────
# HP LaserJet 1020 / 1018 / 1005 / 1000 / P100x / P1505 等"GDI / host-based"
# 机型每次上电都要先由主机把固件写入 /dev/usb/lpN 才能进入工作状态。物理机上
# 由 foo2zjs 安装的 udev 规则（/usr/lib/udev/rules.d/85-hplj10xx.rules）
# 根据 USB 产品字串匹配后 RUN+="hpljNNNN"，触发同包提供的
# /usr/lib/udev/hpljNNNN 脚本——脚本内部走 CUPS USB backend 把
# /lib/firmware/hp/sihpNNNN.dl 上传到打印机。
#
# 容器内没有 udev daemon、kernel uevent 也不会自动传进来，原生 udev 规则
# 不会触发。这里复用 foo2zjs 上游同一个脚本——手动给它喂上 SUBSYSTEM 环境
# 变量让防御性检查通过。CUPS backend 自己通过 libusb 枚举设备 ID 里带对应
# 型号字串的打印机并上传固件。
#
# 后台跑：上游脚本里有 `sleep 3`（避开 udev 探测竞态），同步调用会拖慢
# cupsd 启动。后台跑既不阻塞 cupsd，也不影响 USB backend。
#
# 覆盖型号：hplj1000/1005/1018/1020（foo2zjs）+ hpljP1005/P1006/P1505（foo2xqx）。
# 仅对固件文件存在且 udev 脚本可执行的型号调用。
HPLJ_LOADERS="hplj1000 hplj1005 hplj1018 hplj1020 hpljP1005 hpljP1006 hpljP1505"
HPLJ_FW_LOG=/var/log/cups/hp-firmware.log
mkdir -p /var/log/cups
for loader_name in $HPLJ_LOADERS; do
    loader_path="/usr/lib/udev/${loader_name}"
    if [ -x "$loader_path" ]; then
        echo "[entrypoint] dispatching ${loader_name} in background; log: ${HPLJ_FW_LOG}"
        (
            set +x
            SUBSYSTEM=usb "$loader_path" >>"$HPLJ_FW_LOG" 2>&1 || true
        ) &
    fi
done

# ══════════════════════════════════════════════════════════════
# 6. Start dbus + avahi + ipp-usb (from cups/entrypoint.sh)
# ══════════════════════════════════════════════════════════════
# ── 后台拉起 avahi-daemon 与 ipp-usb：用于 driverless / IPP Everywhere 发现 ──
# 其中 ipp-usb 负责把 USB 直连的 IPP Everywhere 打印机（如 Brother DCP-T425W）
# 暴露成本地 http://localhost 的 IPP 端点，让 CUPS 能把它识别为
# "IPP Everywhere (color)" 机型。两者均允许缺失（某些架构 ipp-usb 可能未安装，
# 或容器未拿到 USB 设备），失败不影响 cupsd 启动。
if command -v avahi-daemon >/dev/null 2>&1; then
    # 不存在 dbus 时 avahi-daemon 会失败，用 --no-rlimits --no-drop-root 简化容器内启动；
    # 如宿主 dbus 不可用则静默跳过。
    mkdir -p /var/run/dbus
    (dbus-daemon --system --fork 2>/dev/null || true)
    (avahi-daemon --daemonize --no-chroot 2>/dev/null || true)
fi
if command -v ipp-usb >/dev/null 2>&1; then
    # ipp-usb 默认走 systemd，容器里直接前台 --no-fork 失败，用后台模式；
    # 拿不到 USB（未挂 /dev/bus/usb）时会自动退出，不影响 cupsd。
    mkdir -p /var/log/ipp-usb /var/lock/ipp-usb
    (ipp-usb >/var/log/ipp-usb/ipp-usb.log 2>&1 &) || true
fi

# ══════════════════════════════════════════════════════════════
# 7. Start cupsd in background with auto-restart watchdog
# ══════════════════════════════════════════════════════════════
# ── 为什么 cupsd 必须在 watchdog 子 shell **内部**前台启动 ────────────────
# bash 的 `wait` 只能等待**当前 shell 自己的子进程**。如果在主 shell 里
# `cupsd -f &` 拿到 PID，再在子 shell 里 `wait $CUPSD_PID`，那个 PID 对子
# shell 来说是"兄弟进程"而不是子进程，bash 会立刻返回 127（not a child of
# this shell）而不是阻塞等待。老实现用 `|| true` 把这个错误吞掉，于是
# 循环立即往下走 → sleep 2 → 再拉一个 cupsd → 631 端口已被占用，新进程
# 秒退 → 每 2 秒 fork 一次，形成重启风暴、日志刷满。
#
# 正确做法：让 cupsd 在 watchdog 子 shell 内以**前台**方式运行。这样它就是
# 子 shell 的直接子进程，子 shell 会在 cupsd 真正退出时才继续，`$?` 也是
# cupsd 的真实退出码。整个子 shell 再 `&` 到后台，不阻塞后续启动步骤。
# ⚠️ 后人修改注意：不要把 `/usr/sbin/cupsd -f` 挪到子 shell 外面再配
# `wait`，那会退回到上面描述的 127 死循环。
#
# ── 失败退避（防止配置错误导致无限刷屏）────────────────────────────────
# cupsd 若因配置错误（cupsd.conf 语法错、端口被宿主占用、权限问题）启动即退，
# 无限重试只会刷满日志。这里统计"短命退出"（存活 < CUPSD_MIN_UPTIME 秒）的
# 连续次数，达到 CUPSD_MAX_FAST_FAILS 次就打印醒目错误并彻底放弃重启；
# 只要有一次存活超过阈值（说明是偶发崩溃而非配置问题）就把计数器清零。
CUPSD_MIN_UPTIME=5
CUPSD_MAX_FAST_FAILS=5
(
    fast_fails=0
    while true; do
        start_ts=$SECONDS
        /usr/sbin/cupsd -f
        rc=$?
        uptime=$((SECONDS - start_ts))

        if [ "$uptime" -lt "$CUPSD_MIN_UPTIME" ]; then
            fast_fails=$((fast_fails + 1))
        else
            fast_fails=0
        fi

        if [ "$fast_fails" -ge "$CUPSD_MAX_FAST_FAILS" ]; then
            echo "[entrypoint] ERROR: cupsd exited ${fast_fails} times within ${CUPSD_MIN_UPTIME}s (last rc=${rc})."
            echo "[entrypoint] ERROR: 这通常是 cupsd 配置错误（/etc/cups/cupsd.conf）或 631 端口被占用，"
            echo "[entrypoint] ERROR: 而不是偶发崩溃。放弃自动重启，请检查上方 cupsd 日志后重启容器。"
            break
        fi

        echo "[entrypoint] cupsd exited (rc=${rc}, uptime=${uptime}s), restarting in 2s..."
        sleep 2
    done
) &

# ══════════════════════════════════════════════════════════════
# 8. Wait for cupsd to be ready (max 30s)
# ══════════════════════════════════════════════════════════════
for i in $(seq 1 30); do
    lpstat -r >/dev/null 2>&1 && break
    sleep 1
done

# ══════════════════════════════════════════════════════════════
# 8b. PdftopsRenderer: PDF→PostScript 渲染器改用 Ghostscript (issue #105)
# ══════════════════════════════════════════════════════════════
# cups-filters 的 pdftops 滤镜默认用 Poppler 渲染 PDF→PostScript，对某些 PDF
# 会失败导致任务卡在 processing。这里分两步修复：
#   ① 修补存量卷中缺失 PdftopsRenderer 的 cups-browsed.conf（影响新发现的队列）
#   ② 对所有已存在的打印机队列设置 pdftops-renderer=gs（影响存量队列）
# 幂等：已设过则跳过。失败不阻塞启动。

# ① 存量卷修补：Dockerfile 已在镜像基线写入 PdftopsRenderer gs，但挂载的
#   ./.etc 卷可能还是旧配置，这里补上。
if [ -f /etc/cups/cups-browsed.conf ] && ! grep -q '^[[:space:]]*PdftopsRenderer' /etc/cups/cups-browsed.conf; then
    echo "" >> /etc/cups/cups-browsed.conf
    echo "# Use Ghostscript for PDF->PostScript conversion (issue #105)" >> /etc/cups/cups-browsed.conf
    echo "PdftopsRenderer gs" >> /etc/cups/cups-browsed.conf
    echo "[entrypoint] 已为存量 cups-browsed.conf 追加 PdftopsRenderer gs（issue #105）"
fi

# ② 对所有已存在的打印机队列设置 pdftops-renderer=gs
#    lpoptions -p NAME -o pdftops-renderer=gs 写入 per-printer 默认选项，
#    对手动通过 CUPS Web UI / lpadmin 添加的本地队列生效。
(
    set +x
    for p in $(lpstat -e 2>/dev/null); do
        current=$(lpoptions -p "$p" -l 2>/dev/null | grep 'pdftops-renderer' | head -1)
        if ! echo "$current" | grep -q '\bgs\b'; then
            if lpoptions -p "$p" -o pdftops-renderer=gs 2>/dev/null; then
                echo "[entrypoint] set pdftops-renderer=gs on $p (issue #105)"
            else
                echo "[entrypoint] WARN: failed to set pdftops-renderer=gs on $p (issue #105)"
            fi
        fi
    done
) &

# ══════════════════════════════════════════════════════════════
# 9. AirPrint A4 media-ready patch (from cups/entrypoint.sh)
# ══════════════════════════════════════════════════════════════
# ── 把 HP 1020 队列的默认纸张设成 A4 ────────────────────────────────────
# issue #48 把 PPD 的 *DefaultPageSize 改成 A4；这里再把**队列**的默认媒体
# (IPP media-default) 也设成 A4，让 iOS 打印面板打开时预选 A4 而不是 Letter。
#
# ⚠️ 更正一处长期的误解：本段注释以前写着"CUPS 随之把 media-ready 通告成 A4"，
# **这句不成立**。按 CUPS 源码（scheduler/printers.c 的 load_ppd），`media-ready`
# 的唯一写入点是拿 `ReadyPaperSizes` 去和 PPD 支持的尺寸求交集，跟 media-default
# 完全无关。`lpadmin -o media=` 只写 media-default。
# 也就是说 issue #82 抱怨的"iPhone 纸张列表里没有 A4"并不是靠这一句修好的——
# 真正起作用的是 cupsd.conf 里的 `ReadyPaperSizes`（见本脚本第 3 步与 Dockerfile）。
# 这一句保留，因为它确实负责"面板默认勾选 A4"这件事，只是别再把它当成
# media-ready 的解法。
#
# 手法：cupsd 起来后对存量 HP 1020 队列执行
#   lpadmin -p NAME -o media=iso_a4_210x297mm
# lpadmin 需要 cupsd 在线(走 IPP)，所以放后台等 cupsd 就绪后执行，
# 不阻塞启动；exec 替换父进程不会杀掉已 fork 的后台子 shell。
# 命中条件与 issue #48 的一次性 PPD 修补一致(HP 1020 foo2zjs 双重指纹 +
# PageSize 列表含 A4)，队列名由 /etc/cups/ppd/<printer>.ppd 文件名反推。
# 仅当当前默认纸张仍是 A4(即用户没在 CUPS UI 里显式改过)时才动，避免覆盖
# 用户的手动选择。任何一台失败只告警不影响其他队列与 cupsd。
(
    set +x
    if [ -d /etc/cups/ppd ]; then
        for ppd in /etc/cups/ppd/*.ppd; do
            [ -f "$ppd" ] || continue
            grep -q '^\*Product:[[:space:]]*"(HP LaserJet 1020)"' "$ppd" || continue
            grep -q '^\*FoomaticIDs:[[:space:]]\+HP-LaserJet_1020[[:space:]]\+foo2zjs-z1' "$ppd" || continue
            grep -q '^\*PageSize A4' "$ppd" || continue
            grep -q '^\*DefaultPageSize:[[:space:]]\+A4[[:space:]]*$' "$ppd" || continue
            printer_name="$(basename "$ppd" .ppd)"
            if lpadmin -p "$printer_name" -o media=iso_a4_210x297mm 2>/dev/null; then
                echo "[entrypoint] set media-default=A4 on $printer_name (issue #48/#82)"
            else
                echo "[entrypoint] WARN: failed to set media-default=A4 on $printer_name (issue #48/#82)"
            fi
        done
    fi
) &

# ══════════════════════════════════════════════════════════════
# 10. Start cups-web as foreground process (PID 1)
# ══════════════════════════════════════════════════════════════
exec /cups-web
