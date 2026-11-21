#!/bin/sh
# PMIC 寄存器强制读取（0x36 被 axp20x 驱动占用，需 -f）
PW=alpine
S() { echo "$PW" | sudo -S -p '' "$@"; }

echo "=== 强制读取 PMIC 寄存器（bus 3, 0x36, -f 绕过驱动占用）==="
for reg in 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 15 16 17 18 19 1a 1b; do
    v=$(S i2cget -y -f 3 0x36 0x$reg 2>/dev/null)
    if [ -n "$v" ]; then
        printf '  0x%s = %s\n' "$reg" "$v"
    else
        printf '  0x%s = <fail>\n' "$reg"
    fi
done

echo
echo "=== 按 AXP313A 公式换算（若数值合理则反证芯片为 AXP313A）==="
for reg in 13 14 15; do
    v=$(S i2cget -y -f 3 0x36 0x$reg 2>/dev/null)
    [ -z "$v" ] && { echo "  0x$reg 读取失败"; continue; }
    dec=$((v))
    idx=$(( dec & 0x7f ))
    if [ $idx -le 70 ]; then
        mv=$(( 500 + idx * 10 ))
    else
        mv=$(( 1220 + (idx - 71) * 20 ))
    fi
    case $reg in
        13) name="DCDC1 vdd-gpu-sys";;
        14) name="DCDC2 vdd-cpu";;
        15) name="DCDC3 vdd-dram";;
    esac
    printf '  0x%s %-22s raw=%s index=%s -> %s mV\n' "$reg" "$name" "$v" "$idx" "$mv"
done

echo
echo "=== 0x10 输出使能位（AXP313A: bit0=DCDC1 bit1=DCDC2 bit2=DCDC3 bit3=LDO1 bit4=LDO2）==="
v=$(S i2cget -y -f 3 0x36 0x10 2>/dev/null)
if [ -n "$v" ]; then
    dec=$((v))
    echo "  raw=$v"
    echo "  bit0(DCDC1)=$(( (dec>>0)&1 ))  bit1(DCDC2)=$(( (dec>>1)&1 ))  bit2(DCDC3)=$(( (dec>>2)&1 ))"
    echo "  bit3(LDO1)=$(( (dec>>3)&1 ))   bit4(LDO2)=$(( (dec>>4)&1 ))"
fi

echo
echo "=== 对照：当前内核报告的 DCDC 类 regulator（AXP806 错映射视角）==="
for d in /sys/class/regulator/regulator.*; do
    n=$(cat "$d/name" 2>/dev/null)
    case "$n" in
        dcdca|dcdcb|dcdcc|dcdcd|dcdce|aldo1|bldo2|sw)
            printf '  %-10s now=%s\n' "$n" "$(cat $d/microvolts 2>/dev/null)";;
    esac
done
