#!/bin/bash -ex

if [ $(grep -ci $CUPSADMIN /etc/shadow) -eq 0 ]; then
    useradd -r -G lpadmin -M $CUPSADMIN

    # add password
    echo $CUPSADMIN:$CUPSPASSWORD | chpasswd

    # add tzdata
    ln -fs /usr/share/zoneinfo/$TZ /etc/localtime
    dpkg-reconfigure --frontend noninteractive tzdata
fi

# restore default cups config in case user does not have any
if [ ! -f /etc/cups/cupsd.conf ]; then
    cp -rpn /etc/cups-bak/* /etc/cups/
fi

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

# ── USB 打印机断电重连自动恢复（后台，不阻塞 cupsd） ──
# 详见 usb-watchdog.sh；从 entrypoint.sh 删除下面这行即可禁用。
/usr/local/bin/usb-watchdog.sh &

exec /usr/sbin/cupsd -f
