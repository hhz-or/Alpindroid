#!/bin/sh
# HDMI / DRM / fbcon 显示链路诊断
PW=alpine
S() { echo "$PW" | sudo -S -p '' "$@"; }

echo "=== 1. 设备节点 ==="
ls -l /dev/dri/ 2>&1 | sed 's/^/  /'
ls -l /dev/fb* 2>&1 | sed 's/^/  /'

echo
echo "=== 2. DRM 连接器状态（HPD / 是否检测到显示器）==="
for c in /sys/class/drm/card*/card*-*/status /sys/class/drm/card*-*/status; do
    [ -f "$c" ] || continue
    printf '  %-45s %s\n' "$c" "$(cat "$c" 2>/dev/null)"
done
echo "  --- enabled 状态 ---"
for c in /sys/class/drm/card*/card*-*/enabled; do
    [ -f "$c" ] || continue
    printf '  %-45s %s\n' "$c" "$(cat "$c" 2>/dev/null)"
done
echo "  --- EDID 是否读到 ---"
for c in /sys/class/drm/card*/card*-*/edid; do
    [ -f "$c" ] || continue
    sz=$(wc -c < "$c" 2>/dev/null)
    printf '  %-45s %s bytes\n' "$c" "$sz"
done

echo
echo "=== 3. fbcon / vtconsole 绑定情况 ==="
ls -l /sys/class/vtconsole/ 2>&1 | sed 's/^/  /'
for v in /sys/class/vtconsole/vtcon*/name /sys/class/vtconsole/vtcon*/bind; do
    [ -f "$v" ] || continue
    printf '  %-45s %s\n' "$v" "$(cat "$v" 2>/dev/null)"
done
echo "  --- 当前 console ---"
cat /sys/class/tty/console/active 2>/dev/null | sed 's/^/  /'

echo
echo "=== 4. 相关内核模块 ==="
lsmod 2>/dev/null | grep -iE "sun4i|sun8i|hdmi|drm|fbcon|panfrost|display|tcon" | sed 's/^/  /'

echo
echo "=== 5. dmesg 中的显示相关日志（含错误）==="
dmesg 2>/dev/null | grep -iE "sun4i|sun8i|hdmi|drm|fbcon|display|tcon|panfrost|cec" | head -40 | sed 's/^/  /'

echo
echo "=== 6. 启动阶段是否有 component/probe 失败 ==="
dmesg 2>/dev/null | grep -iE "deferred|component|probe.*fail|-ENODEV|-EPROBE|not found" | head -25 | sed 's/^/  /'

echo
echo "=== 7. 帧缓冲信息 ==="
cat /proc/fb 2>/dev/null | sed 's/^/  /'
cat /sys/class/graphics/fb0/virtual_size 2>/dev/null | sed 's/^/  virtual_size: /'
cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null | sed 's/^/  bpp: /'

echo
echo "=== 8. 与 v0.2c 对比：PMIC 是否真的切到 AXP313a ==="
dmesg 2>/dev/null | grep -iE "axp20x|AXP313|AXP806" | sed 's/^/  /'
echo "  --- cpufreq ---"
ls /sys/devices/system/cpu/cpufreq/ 2>&1 | sed 's/^/  /'
for p in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$p" ] || continue
    echo "  $p: governor=$(cat $p/scaling_governor 2>/dev/null) cur=$(cat $p/scaling_cur_freq 2>/dev/null)"
done
