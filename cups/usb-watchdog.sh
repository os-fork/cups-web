#!/usr/bin/env bash
# USB 打印机断电重连自动恢复 watchdog（方案 3：lpstat -e + VID:PID 指纹比对）
#
# 问题：USB 打印机断电后 cupsd 持有的 usb backend fd 失效，当前任务卡在
# "processing"，CUPS 默认 printer-error-policy=stop-printer 把打印机标记为
# stopped。重新上电后 cupsd 不会主动检测设备回归，必须重启 cupsd 才能恢复。
#
# 本脚本用 lpstat -e（CUPS backend 发现模式，libusb 枚举硬件）定时扫描实际
# 在线的 USB 打印机，与 lpstat -a 中 stopped 状态的打印机做 USB VID:PID 指纹
# 交叉比对，匹配到"已上线但被停用"的打印机时自动 cupsenable + accept 恢复。
#
# 相比检查 /dev/usb/lpX 节点路径的方式，lpstat -e 不依赖设备节点路径稳定性
# （某些内核重连后路径会变），且 VID:PID 精确匹配不会误触其他 USB 设备。
#
# 用法：被 entrypoint.sh 以 /usr/local/bin/usb-watchdog.sh & 后台调用，
#       也可在运行中的容器里手动执行（会持续运行直到被 kill）。
# 日志：WATCHDOG_LOG 环境变量可覆盖，默认 /var/log/cups/usb-watchdog.log。
# 禁用：从 entrypoint.sh 删除调用行，或 `docker exec ... pkill -f usb-watchdog`。

set -euo pipefail

WATCHDOG_LOG="${WATCHDOG_LOG:-/var/log/cups/usb-watchdog.log}"
mkdir -p "$(dirname "${WATCHDOG_LOG}")"

# 给 cupsd 启动和初始化 backend 的窗口期
sleep 10

echo "[usb-watchdog] $(date '+%Y-%m-%d %H:%M:%S') started, log=${WATCHDOG_LOG}"

SCAN_COUNT=0
HEARTBEAT_INTERVAL=60  # 每 60 次扫描（10 分钟）输出一次心跳

while true; do
    SCAN_COUNT=$((SCAN_COUNT + 1))

    # ── 通过 lpstat -e 扫描当前所有在线的 USB 打印机 ──
    # lpstat -e 输出格式示例：
    #   usb://EPSON%2FL380%20Series?serial=...&interface=1
    #   usb://Canon%2FLBP2900?serial=...
    # 提取 usb:// 行中 ? 之前的部分作为设备指纹（make%2Fmodel）
    AVAILABLE_IDS=""
    while IFS= read -r devline; do
        case "${devline}" in
            usb://*)
                vidpid="${devline#usb://}"
                vidpid="${vidpid%%\?*}"
                AVAILABLE_IDS="${AVAILABLE_IDS} ${vidpid}"
                ;;
        esac
    done <<< "$(lpstat -e 2>/dev/null)"

    # ── 遍历所有 stopped 的 USB 打印机 ──
    # lpstat -a 输出示例：
    #   EPSON_L380 accepting requests since ...
    #   EPSON_L380 not accepting requests since ...  ← 卡住的
    STOPPED_COUNT=0
    RECOVERED=0
    for p in $(lpstat -a 2>/dev/null | grep 'not accepting' | awk '{print $1}'); do
        STOPPED_COUNT=$((STOPPED_COUNT + 1))
        uri=$(lpstat -v "$p" 2>/dev/null | awk '{print $NF}')
        case "${uri}" in
            usb://*)
                uri_vidpid="${uri#usb://}"
                uri_vidpid="${uri_vidpid%%\?*}"
                # 在可用设备列表中查找该 VID:PID
                if echo "${AVAILABLE_IDS}" | grep -qiF "${uri_vidpid}"; then
                    echo "[usb-watchdog] $(date '+%Y-%m-%d %H:%M:%S') re-enabling $p (USB device ${uri_vidpid} reappeared)"
                    cupsenable "$p" 2>/dev/null || true
                    accept "$p" 2>/dev/null || true
                    RECOVERED=$((RECOVERED + 1))
                fi
                ;;
        esac
    done

    # 定期心跳：确认 watchdog 仍在运行，同时汇报当前状态
    if [ $((SCAN_COUNT % HEARTBEAT_INTERVAL)) -eq 0 ]; then
        echo "[usb-watchdog] $(date '+%Y-%m-%d %H:%M:%S') heartbeat #${SCAN_COUNT} | online devices: $(echo "${AVAILABLE_IDS}" | wc -w) | stopped printers: ${STOPPED_COUNT} | recovered this cycle: ${RECOVERED}"
    fi

    sleep 10
done >>"${WATCHDOG_LOG}" 2>&1
