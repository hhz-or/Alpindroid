#!/bin/sh
# 板端 PMIC 寄存器实测（需要 sudo）
PW=alpine
S() { echo "$PW" | sudo -S -p '' "$@"; }

echo "=== 安装 i2c-tools ==="
S apk add --no-cache i2c-tools 2>&1 | tail -3

echo
echo "=== i2cdetect bus 3（PMIC 在 0x36）==="
S i2cdetect -y 3 2>&1 | tail -10

echo
echo "=== 原始寄存器读取（bus 3, addr 0x36）==="
for reg in 00 01 02 03 04 05 06 07 10 11 12 13 14 15 16 17 18 19 1a 1b; do
    v=$(S i2cget -y 3 0x36 0x$reg 2>/dev/null)
    if [ -n "$v" ]; then
        printf '  0x%s = %s\n' "$reg" "$v"
    else
        printf '  0x%s = <读失败>\n' "$reg"
    fi
done

echo
echo "=== 按 AXP313A 映射换算 DCDC 电压 ==="
echo "  (公式来自 axp313a_dcdc{1,2,3}_ranges: idx<=70 -> 500+idx*10 mV; idx>=71 -> 1220+(idx-71)*20 mV)"
for reg in 13 14 15; do
    v=$(S i2cget -y 3 0x36 0x$reg 2>/dev/null)
    [ -z "$v" ] && { echo "  0x$reg 读取失败"; continue; }
    dec=$((v))
    idx=$(( dec & 0x7f ))
    if [ $idx -le 70 ]; then
        mv=$(( 500 + idx * 10 ))
    else
        mv=$(( 1220 + (idx - 71) * 20 ))
    fi
    case $reg in
        13) name="DCDC1 (vdd-gpu-sys)";;
        14) name="DCDC2 (vdd-cpu)";;
        15) name="DCDC3 (vdd-dram)";;
    esac
    printf '  0x%s %-20s raw=%s index=%s -> %s mV\n' "$reg" "$name" "$v" "$idx" "$mv"
done

echo
echo "=== 现有 regulator 视图（当前是 AXP806 错映射）==="
for d in /sys/class/regulator/regulator.*; do
    [ -d "$d" ] || continue
    printf '  %-16s now=%-9s min=%-9s max=%s\n' \
        "$(cat $d/name 2>/dev/null)" \
        "$(cat $d/microvolts 2>/dev/null)" \
        "$(cat $d/min_microvolts 2>/dev/null)" \
        "$(cat $d/max_microvolts 2>/dev/null)"
done

echo
echo "=== 其他 i2c 总线上的设备（确认还有哪些）==="
for b in 1 2 4 5; do
    echo "  --- bus $b ---"
    S i2cdetect -y $b 2>/dev/null | tail -8 | sed 's/^/    /'
done
