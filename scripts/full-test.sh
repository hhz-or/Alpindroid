#!/bin/sh
# Alpindroid 全量功能测试 / 设备状态快照
# 用法: sh full-test.sh [unix_epoch]   （epoch 用于校正 1970 时间，使 apk 可用）
PW=alpine
S() { echo "$PW" | sudo -S -p '' "$@"; }
EPOCH="$1"

sep() { echo; echo "================================================================"; echo " $*"; echo "================================================================"; }

# ---------- 0. 准备 ----------
if [ -n "$EPOCH" ]; then
    S date -s "@$EPOCH" >/dev/null 2>&1
    S hwclock -w >/dev/null 2>&1
fi

sep "0. 系统概况"
echo "  kernel   : $(uname -r)  $(uname -m)"
echo "  model    : $(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
echo "  alpine   : $(cat /etc/alpine-release)"
echo "  hostname : $(cat /etc/hostname)"
echo "  时间     : $(date)"
echo "  uptime   : $(uptime | sed 's/.*up //;s/,.*//')"
echo "  负载     : $(cat /proc/loadavg)"

# ---------- 1. 电源 / PMIC ----------
sep "1. 电源 / PMIC（AXP313A）"
if command -v i2cget >/dev/null 2>&1; then
    S apk add --no-cache i2c-tools >/dev/null 2>&1 || apk add --no-cache i2c-tools >/dev/null 2>&1
fi
if command -v i2cget >/dev/null 2>&1; then
    echo "  PMIC 识别:"
    dmesg 2>/dev/null | grep -iE "axp20x.*variant|axp20x.*driver loaded" | sed 's/^/    /'
    echo "  寄存器实测（bus3 0x36, -f）："
    for reg in 13 14 15 16 17; do
        v=$(S i2cget -y -f 3 0x36 0x$reg 2>/dev/null)
        [ -z "$v" ] && { echo "    0x$reg = <fail>"; continue; }
        dec=$((v)); idx=$(( dec & 0x7f ))
        if [ $reg = "16" ] || [ $reg = "17" ]; then
            mv=$(( 500 + idx * 100 ))
            case $reg in 16) nm="LDO1";; 17) nm="LDO2";; esac
        else
            if [ $idx -le 70 ]; then mv=$(( 500 + idx * 10 )); else mv=$(( 1220 + (idx - 71) * 20 )); fi
            case $reg in 13) nm="DCDC1(GPU+SYS)";; 14) nm="DCDC2(CPU)";; 15) nm="DCDC3(DRAM)";; esac
        fi
        printf '    0x%s %-14s raw=%s -> %s mV\n' "$reg" "$nm" "$v" "$mv"
    done
    v=$(S i2cget -y -f 3 0x36 0x10 2>/dev/null)
    [ -n "$v" ] && echo "    0x10 OUTPUT_CONTROL = $v"
else
    echo "  (i2c-tools 不可用，跳过寄存器读取)"
fi
echo "  regulator 视图:"
for d in /sys/class/regulator/regulator.*; do
    [ -d "$d" ] || continue
    n=$(cat "$d/name" 2>/dev/null)
    printf '    %-16s %-9s %s\n' "$n" "$(cat $d/microvolts 2>/dev/null)" "$(cat $d/state 2>/dev/null)"
done

# ---------- 2. CPU 调频 ----------
sep "2. CPU 调频（DVFS）"
if [ -d /sys/devices/system/cpu/cpufreq/policy0 ]; then
    P=/sys/devices/system/cpu/cpufreq/policy0
    echo "  ✓ policy0 已注册"
    echo "    driver    : $(cat $P/scaling_driver 2>/dev/null)"
    echo "    governor  : $(cat $P/scaling_governor 2>/dev/null)"
    echo "    可用频率  : $(cat $P/scaling_available_frequencies 2>/dev/null)"
    echo "    可用调速器: $(cat $P/scaling_available_governors 2>/dev/null)"
    echo "    当前频率  : $(cat $P/scaling_cur_freq 2>/dev/null)  min=$(cat $P/scaling_min_freq 2>/dev/null) max=$(cat $P/scaling_max_freq 2>/dev/null)"
    echo "    每核频率  :"
    for c in /sys/devices/system/cpu/cpu[0-9]*; do
        [ -d "$c" ] || continue
        echo "      $(basename $c): $(cat $c/cpufreq/scaling_cur_freq 2>/dev/null)"
    done
else
    echo "  ✗ policy0 不存在（调频未注册）"
fi

# ---------- 3. 热管理 ----------
sep "3. 热管理（Thermal）"
for z in /sys/class/thermal/thermal_zone*; do
    [ -d "$z" ] || continue
    t=$(cat "$z/type" 2>/dev/null); temp=$(cat "$z/temp" 2>/dev/null)
    printf '  %-14s %6s mC (%s.%s C)\n' "$t" "$temp" "$((temp/1000))" "$(( (temp%1000)/100 ))"
    for tp in "$z"/trip_point_*_temp; do
        [ -r "$tp" ] || continue
        v=$(cat "$tp" 2>/dev/null)
        printf '     %-22s %s mC (%s C)\n' "$(basename $tp)" "$v" "$((v/1000))"
    done
    [ -r "$z/polling_delay" ] && printf '     polling_delay          %s\n' "$(cat $z/polling_delay)"
done
echo "  cooling devices:"
found=0
for c in /sys/class/thermal/cooling_device*; do
    [ -d "$c" ] || continue
    found=1
    echo "    $(basename $c): type=$(cat $c/type 2>/dev/null) cur=$(cat $c/cur_state 2>/dev/null)/max=$(cat $c/max_state 2>/dev/null)"
done
[ "$found" = 0 ] && echo "    （无）"

# ---------- 4. GPU / DRM / 显示 ----------
sep "4. GPU / DRM / 显示"
echo "  设备节点:"
ls -l /dev/dri/ 2>/dev/null | sed 's/^/    /' || echo "    ✗ /dev/dri 不存在"
ls -l /dev/fb* 2>/dev/null | sed 's/^/    /' || echo "    ✗ /dev/fb* 不存在"
echo "  DRM 连接器:"
for c in /sys/class/drm/card*/card*-*/status; do
    [ -f "$c" ] || continue
    printf '    %-42s %s\n' "$(echo $c | sed 's|/sys/class/drm/||')" "$(cat $c 2>/dev/null)"
done
echo "  EDID:"
for c in /sys/class/drm/card*/card*-*/edid; do
    [ -f "$c" ] || continue
    printf '    %-42s %s bytes\n' "$(echo $c | sed 's|/sys/class/drm/||')" "$(wc -c < $c 2>/dev/null)"
done
echo "  fbcon:"
for v in /sys/class/vtconsole/vtcon*/name; do
    [ -f "$v" ] || continue
    printf '    %s\n' "$(cat $v 2>/dev/null)"
done
echo "  framebuffer:"
cat /proc/fb 2>/dev/null | sed 's/^/    /' || echo "    （无）"
cat /sys/class/graphics/fb0/virtual_size 2>/dev/null | sed 's/^/    virtual_size: /'
echo "  相关模块:"
lsmod 2>/dev/null | grep -iE "panfrost|sun4i|sun8i|drm|display_connector|dw_hdmi" | sed 's/^/    /'
echo "  DRM/HDMI 日志:"
dmesg 2>/dev/null | grep -iE "sun4i-drm|6000000.hdmi|panfrost|dw-hdmi" | tail -12 | sed 's/^/    /'

# ---------- 5. 网络 ----------
sep "5. 网络（WiFi）"
ip -br link 2>/dev/null | sed 's/^/  /'
echo "  地址:"
ip -br addr 2>/dev/null | sed 's/^/    /'
echo "  无线模块:"
lsmod 2>/dev/null | grep -iE "sprdwl|uwe5622|sprdbt|cfg80211" | sed 's/^/    /'
echo "  DHCP/DNS:"
cat /etc/resolv.conf 2>/dev/null | grep -v "^#" | sed 's/^/    /'
echo "  连通性:"
ping -c 2 -W 3 192.168.137.1 >/dev/null 2>&1 && echo "    网关 ok" || echo "    网关 失败"
if command -v nmcli >/dev/null 2>&1; then
    echo "  nmcli device:"
    nmcli device status 2>/dev/null | sed 's/^/    /'
    echo "  nmcli 当前连接:"
    nmcli -t -f NAME,DEVICE,STATE connection show --active 2>/dev/null | sed 's/^/    /'
fi

# ---------- 6. USB / 输入 ----------
sep "6. USB / 输入设备"
if command -v lsusb >/dev/null 2>&1; then lsusb 2>/dev/null | sed 's/^/  /'; else echo "  (无 lsusb)"; fi
echo "  输入设备:"
cat /proc/bus/input/devices 2>/dev/null | grep -E '^N:' | sed 's/^/    /'

# ---------- 7. 存储 ----------
sep "7. 存储"
df -h 2>/dev/null | sed 's/^/  /'
echo "  分区:"
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null | sed 's/^/    /'
echo "  fstab:"
grep -v "^#" /etc/fstab 2>/dev/null | grep -v "^$" | sed 's/^/    /'

# ---------- 8. OpenRC 服务 ----------
sep "8. OpenRC 服务状态"
rc-status 2>/dev/null | sed 's/^/  /' || \
for lv in sysinit boot default; do
    echo "  [$lv]"
    for s in /etc/runlevels/$lv/*; do
        [ -e "$s" ] || continue
        echo "    $(basename $s)"
    done
done

# ---------- 9. 内核异常汇总 ----------
sep "9. 内核日志异常汇总"
echo "  错误 / 失败 / 警告:"
dmesg 2>/dev/null | grep -iE "error|fail|warn|cannot|unable|timeout|denied" | grep -viE "not found, using dummy|regulatory" | tail -25 | sed 's/^/    /'
echo "  deferred probe:"
dmesg 2>/dev/null | grep -i "deferred" | tail -8 | sed 's/^/    /'
echo "  当前温度 / 电压点:"
for z in /sys/class/thermal/thermal_zone*; do
    [ -d "$z" ] || continue
    printf '    %s = %s C\n' "$(cat $z/type)" "$(( $(cat $z/temp) / 1000 ))"
done

sep "测试结束"
