#!/bin/sh
# Alpindroid 板端电源管理信息采集（只读）
# 用法: sh /tmp/pmic-diag.sh
# 输出可直接贴回分析，不需要 root（dmesg 若受限会自动跳过）

hr() { echo "============================================================"; }

hr
echo " 型号: $(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')"
echo " 内核: $(uname -r)  $(uname -m)"
hr

echo
echo "--- [1] I2C PMIC 设备与驱动绑定 ---"
for d in /sys/bus/i2c/devices/*-0036; do
    [ -d "$d" ] || continue
    echo "设备: $d"
    echo "  name:    $(cat "$d/name" 2>/dev/null)"
    echo "  driver:  $(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null)"
    echo "  modalias:$(cat "$d/modalias" 2>/dev/null)"
    [ -d "$d/of_node" ] && echo "  of_node: 存在"
done

echo
echo "--- [2] Regulator 完整状态 ---"
for d in /sys/class/regulator/regulator.*; do
    [ -d "$d" ] || continue
    n=$(cat "$d/name" 2>/dev/null)
    st=$(cat "$d/state" 2>/dev/null)
    mv=$(cat "$d/microvolts" 2>/dev/null)
    mn=$(cat "$d/min_microvolts" 2>/dev/null)
    mx=$(cat "$d/max_microvolts" 2>/dev/null)
    ty=$(cat "$d/type" 2>/dev/null)
    printf '  %-16s type=%-10s state=%-8s now=%-9s min=%-9s max=%s\n' \
        "$n" "$ty" "$st" "$mv" "$mn" "$mx"
done

echo
echo "--- [3] CPUFreq ---"
if [ -d /sys/devices/system/cpu/cpufreq ]; then
    ls -l /sys/devices/system/cpu/cpufreq/
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$p" ] || continue
        echo "  $p:"
        for f in scaling_driver scaling_governor cpuinfo_max_freq cpuinfo_min_freq scaling_cur_freq; do
            [ -r "$p/$f" ] && echo "    $f = $(cat "$p/$f")"
        done
    done
else
    echo "  !! /sys/devices/system/cpu/cpufreq 不存在"
fi
echo "  当前各核频率（cpufreq 未注册时为 clock 固定值）:"
for c in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -d "$c" ] || continue
    echo "    $(basename "$c"): $(cat "$c/cpufreq/scaling_cur_freq" 2>/dev/null || echo 'n/a')"
done

echo
echo "--- [4] OPP 表（debugfs 需要 root，失败则跳过）---"
if [ -r /sys/kernel/debug/opp/opp_summary ]; then
    head -40 /sys/kernel/debug/opp/opp_summary
else
    echo "  (不可读：/sys/kernel/debug/opp/opp_summary)"
fi

echo
echo "--- [5] PMIC / Regulator / CPUFreq / OPP 内核日志 ---"
dmesg 2>/dev/null | grep -Ei 'axp|pmic|regulator|cpufreq|opp|thermal|sunxi-rsb' | head -60 || echo "  (dmesg 不可读，需要 root)"

echo
echo "--- [6] 设备树关键节点（live tree）---"
if [ -d /proc/device-tree ]; then
    DT=/proc/device-tree
    echo "  pmic 节点路径:"
    find "$DT/soc" -maxdepth 3 -name 'pmic*' -o -maxdepth 3 -name '*0036*' 2>/dev/null | head -5
    echo "  cpus 下的 operating-points / supplies:"
    for f in "$DT"/cpus/cpu@0/operating-points-v2 "$DT"/cpus/cpu@0/cpu-supply; do
        [ -e "$f" ] && echo "    $(basename $f) 存在"
    done
    echo "  gpu 节点 mali-supply:"
    for g in "$DT"/gpu@1800000 "$DT"/gpu; do
        [ -d "$g" ] && ls "$g" 2>/dev/null | tr '\n' ' ' && echo
    done
else
    echo "  !! /proc/device-tree 不存在"
fi

echo
echo "--- [7] 打包 live device-tree（供服务器端 dtc -I fs 转换）---"
if [ -d /proc/device-tree ] && [ -w /tmp ]; then
    tar -czf /tmp/live-devicetree.tar.gz -C /proc device-tree 2>/dev/null \
        && echo "  已生成 /tmp/live-devicetree.tar.gz ($(wc -c < /tmp/live-devicetree.tar.gz) 字节)" \
        || echo "  打包失败（可能需要 root 读某些属性）"
else
    echo "  跳过"
fi

echo
hr
echo " 采集结束"
hr
