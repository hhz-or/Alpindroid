#!/bin/sh
# Alpindroid 板端硬件只读检查脚本
#
# 用途：在烧录好的 Alpindroid（或官方 Debian 12）板子上运行，只读、不改任何配置。
#       用于区分「驱动未编入」「PMIC 未识别」「OPP 不可用」「thermal 配置错误」等问题。
#
# 用法：
#   sudo sh hw-check.sh            # 全部检查
#   sudo sh hw-check.sh cpufreq    # 只查 CPUFreq
#   sudo sh hw-check.sh thermal
#   sudo sh hw-check.sh regulator
#   sudo sh hw-check.sh net
#   sudo sh hw-check.sh display
#   sudo sh hw-check.sh dmesg
#
# 说明：脚本用 POSIX sh 编写，Alpine(busybox ash) 与 Debian(bash/dash) 都能跑。

SECTION="${1:-all}"

hr() { echo "============================================================"; }
want() { [ "$SECTION" = all ] || [ "$SECTION" = "$1" ]; }

MODEL=unknown
[ -r /proc/device-tree/model ] && MODEL=$(tr -d '\0' < /proc/device-tree/model)

hr
echo " Alpindroid 硬件检查  $(date 2>/dev/null)"
echo " kernel: $(uname -r)   arch: $(uname -m)"
echo " 型号:   $MODEL"
hr

# ---------------------------------------------------------------- CPUFreq
if want cpufreq; then
    echo
    echo "--- [1] CPUFreq ---"
    if [ -d /sys/devices/system/cpu/cpufreq ]; then
        ls -l /sys/devices/system/cpu/cpufreq/
        found=0
        for p in /sys/devices/system/cpu/cpufreq/policy*; do
            [ -d "$p" ] || continue
            found=1
            echo ">> $p"
            for f in scaling_driver scaling_governor scaling_available_governors \
                     scaling_cur_freq scaling_min_freq scaling_max_freq \
                     cpuinfo_cur_freq cpuinfo_max_freq cpuinfo_min_freq \
                     scaling_available_frequencies; do
                if [ -r "$p/$f" ]; then
                    printf '   %-30s %s\n' "$f" "$(cat "$p/$f" 2>/dev/null | tr '\n' ' ')"
                fi
            done
        done
        [ "$found" = 1 ] || echo "   !! 有 cpufreq 目录但没有 policy* —— 调频未注册"
    else
        echo "   !! /sys/devices/system/cpu/cpufreq 不存在"
        echo "      => CPU 未启用 DVFS，频率被固定在 bootloader 设定值（常见 480MHz）"
    fi
    echo
    echo "   OPP 表状态:"
    if [ -r /sys/kernel/debug/opp/opp_summary ]; then
        cat /sys/kernel/debug/opp/opp_summary 2>/dev/null | head -40
    else
        echo "   (debugfs 未挂载或无 opp_summary，可尝试: mount -t debugfs none /sys/kernel/debug)"
    fi
fi

# ---------------------------------------------------------------- Thermal
if want thermal; then
    echo
    echo "--- [2] Thermal ---"
    for z in /sys/class/thermal/thermal_zone*; do
        [ -d "$z" ] || continue
        echo ">> $z  type=$(cat "$z/type" 2>/dev/null)  temp=$(cat "$z/temp" 2>/dev/null) (milli-C)"
        for t in "$z"/trip_point_*_temp; do
            [ -r "$t" ] || continue
            v=$(cat "$t" 2>/dev/null)
            printf '   %-28s %s  (%s C)\n' "$(basename "$t")" "$v" "$(awk "BEGIN{printf \"%.1f\", $v/1000}")"
        done
        [ -r "$z/polling_delay" ] && printf '   %-28s %s\n' polling_delay "$(cat "$z/polling_delay")"
    done
    echo
    echo "   cooling devices:"
    for c in /sys/class/thermal/cooling_device*; do
        [ -d "$c" ] || continue
        echo "   $(basename "$c"): type=$(cat "$c/type" 2>/dev/null) cur=$(cat "$c/cur_state" 2>/dev/null)/max=$(cat "$c/max_state" 2>/dev/null)"
    done
fi

# ---------------------------------------------------------------- Regulator
if want regulator; then
    echo
    echo "--- [3] Regulators ---"
    if [ -d /sys/class/regulator ]; then
        for r in /sys/class/regulator/regulator.*; do
            [ -d "$r" ] || continue
            printf '   %-42s %-22s %s\n' \
                "$(cat "$r/name" 2>/dev/null)" \
                "$(cat "$r/type" 2>/dev/null)" \
                "$(cat "$r/microvolts" 2>/dev/null) uV"
        done
    else
        echo "   !! /sys/class/regulator 不存在 —— AXP 驱动未注册"
    fi
    echo
    echo "   PMIC 相关内核消息:"
    dmesg 2>/dev/null | grep -Ei 'axp|regulator' | tail -20
fi

# ---------------------------------------------------------------- 网络
if want net; then
    echo
    echo "--- [4] 网络 ---"
    ip -br link 2>/dev/null || ifconfig -a 2>/dev/null
    echo
    echo "   接口详情:"
    ip -br addr 2>/dev/null
    echo
    echo "   无线相关模块:"
    for m in sprdwl_ng uwe5622_bsp_sdio cfg80211 mac80211 rfkill; do
        if lsmod 2>/dev/null | grep -q "^$m"; then
            echo "   [已加载] $m  $(lsmod 2>/dev/null | grep "^$m" | awk '{print "size="$2" refs="$3}')"
        else
            echo "   [未加载] $m"
        fi
    done
    echo
    if command -v nmcli >/dev/null 2>&1; then
        echo "   nmcli device status:"
        nmcli device status 2>/dev/null | sed 's/^/   /'
        echo "   nmcli wifi list (前5):"
        nmcli device wifi list 2>/dev/null | head -6 | sed 's/^/   /'
    else
        echo "   (无 nmcli)"
    fi
    echo
    echo "   无线相关内核消息:"
    dmesg 2>/dev/null | grep -Ei 'uwe5622|sprdwl|sprdbt|cfg80211' | tail -20
fi

# ---------------------------------------------------------------- 显示/USB
if want display; then
    echo
    echo "--- [5] 显示与输入 ---"
    echo "   DRM:"
    ls -l /dev/dri 2>/dev/null || echo "   !! /dev/dri 不存在"
    echo "   帧缓冲:"
    ls -l /dev/fb* 2>/dev/null || echo "   !! /dev/fb0 不存在（fbcon 无法显示到 HDMI）"
    echo "   fbcon 模块:"
    lsmod 2>/dev/null | grep -E "^fbcon|^drm|^sun4i" | sed 's/^/     /'
    echo "   USB:"
    if command -v lsusb >/dev/null 2>&1; then lsusb 2>/dev/null | sed 's/^/     /'; fi
    echo "   输入设备:"
    cat /proc/bus/input/devices 2>/dev/null | grep -E '^(N:|H:)' | head -20 | sed 's/^/     /'
    echo
    echo "   显示相关内核消息:"
    dmesg 2>/dev/null | grep -Ei 'sun4i|hdmi|drm|fbcon|panfrost' | tail -20
fi

# ---------------------------------------------------------------- dmesg 汇总
if want dmesg; then
    echo
    echo "--- [6] 电源管理相关内核日志（关键部分）---"
    dmesg 2>/dev/null | grep -Ei 'axp|regulator|cpufreq|opp|thermal|sun8i|panfrost|mali' | tail -80
fi

echo
hr
echo " 检查结束。重点关注带 !! 的项。"
hr
