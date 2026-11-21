# H618 / WalnutPi ZeroW 电源管理实测记录（AXP313A / DVFS / Thermal）

本文件记录**从官方 Debian 12 镜像中提取的实际 DTB 与内核 config** 的核查结果，
作为后续 `walnutpi-zerow-power.patch` 的事实依据。

- 数据来源：`walnutpi-1` v2.6.0 官方镜像
  `2026-5-20_V2.6.0_WalnutPi-1B_6.1.31_debian12_server.img`
- 提取对象：
  - p1（boot 分区）`sun50i-h616-walnutpi-1b.dtb`
  - p1 `config-6.1.31`
- 反编译命令：`dtc -I dtb -O dts -f -q sun50i-h616-walnutpi-1b.dtb -o wpi.dts`
- 反编译产物：`work/walnutpi-1b-decoded.dts`（1971 行）

> 结论均来自上述文件的实际内容，不是从论坛转述。凡标注「待实机验证」的项，
> 都需要在板子上跑 `scripts/hw-check.sh` 确认。

---

## 一、内核 config：CPUFreq / Thermal / PMIC 驱动**都已编入**

```
CONFIG_CPU_FREQ=y
CONFIG_CPUFREQ_DT=y
CONFIG_ARM_ALLWINNER_SUN50I_CPUFREQ_NVMEM=y
CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y
CONFIG_CPU_FREQ_GOV_PERFORMANCE=y
CONFIG_CPU_FREQ_GOV_POWERSAVE=y
CONFIG_CPU_FREQ_GOV_SCHEDUTIL=y
CONFIG_CPU_IDLE=y
CONFIG_ARM_PSCI_CPUIDLE=y
CONFIG_MFD_AXP20X=y
CONFIG_MFD_AXP20X_I2C=y
CONFIG_REGULATOR_AXP20X=y
CONFIG_THERMAL=y
CONFIG_THERMAL_OF=y
CONFIG_CPU_THERMAL=y
CONFIG_CPU_FREQ_THERMAL=y
CONFIG_THERMAL_GOV_STEP_WISE=y
CONFIG_SUN8I_THERMAL=m
CONFIG_DRM_PANFROST=m
```

**含义：调频机制本身不缺。** 若实机上 `/sys/devices/system/cpu/cpufreq/policy0`
不存在，问题只能出在设备树或 PMIC 驱动协作，而不是"没编进内核"。

---

## 二、实测 DTB 中确认的三个问题

### 问题 1：PMIC 声明为 AXP305/805/806，没有 AXP313A

```dts
pmic@36 {
    compatible = "x-powers,axp305", "x-powers,axp805", "x-powers,axp806";
    reg = <0x36>;
    ...
};
```

chip BSP 实际使用 AXP313A 时，这会导致 AXP20X MFD 驱动按 axp805/806 的寄存器映射
去操作，部分 regulator 编号/位置不一致 → 可能出现 regulator 注册异常或电压设置错误。

**风险**：`regulator-always-on` 的轨可能仍被"注册成功"，但数值映射错误，
所以不一定表现为报错，而是表现为"电压不对/频率升不上去"。

### 问题 2：`mali-supply` 指向 DDR 电源轨，且该轨**固定 1.3 V**

```dts
cpu@0  { operating-points-v2 = <&opp_table_cpu>; cpu-supply  = <&dcdc2>; }   /* 实测 phandle 0x04 */
gpu    { operating-points-v2 = <&gpu_opp_table>; mali-supply = <&dcdc3>; }   /* 实测 phandle 0x0d */

dcdc2 { regulator-name = "vdd-cpu";  min = 0xc5c10 (0.810 V); max = 0x107ac0 (1.080 V); }
dcdc3 { regulator-name = "vdd-dram"; min = 0x13d620;           max = 0x13d620;  }  /* 1.300 V 固定 */
```

解析结果（phandle 实际指向）：
- `cpu-supply  = <0x04>` → `bldo1/dcdc2`（名称 `vdd-cpu`）
- `mali-supply = <0x0d>` → `dcdc1/dcdc3`（名称 `vdd-dram`）

**这是硬冲突**：`gpu-opp-table` 里的档位要求 0.810 ~ 1.080 V，
而 `dcdc3` 是固定 1.300 V 的 DRAM 轨。Panfrost 在 `dev_pm_opp_set_voltage()`
阶段会拿到超出范围的电压 → GPU 初始化失败或退化为无 DVFS。

> 这印证了社区报告的 Mali-G31 供电引用问题。GPU 需要独立的正确轨（AXP313A 上
> 通常是 DCDC2/DCDC3 的不同分配），而不是与 DRAM 共用。

### 问题 3：`cpu-thermal` 的 critical 阈值是 **300 °C**，且所有 zone 都不轮询

```dts
cpu-thermal {
    polling-delay-passive = <0x00>;      /* = 0，不被动轮询 */
    polling-delay         = <0x00>;      /* = 0，完全不轮询采样 */
    thermal-sensors = <0x50 0x02>;
    trips {
        cpu-alert { temperature = <0x14c08>; hysteresis = <0x7d0>; type = "passive"; };  /* 85000 = 85.0 C */
        cpu-crit  { temperature = <0x493e0>; hysteresis = <0x00>;  type = "critical"; }; /* 300000 = 300.0 C */
    };
    ...
};

gpu-thermal { ... gpu-crit  = <0x186a0>; type = "passive"; };   /* 100000 = 100.0 C，且只降频不关机 */
ve-thermal  { ... ve-alert  = <0x14c08>; type = "passive"; };   /* 85.0 C */
ddr-thermal { ... ddr-alert = <0x14c08>; type = "passive"; };   /* 85.0 C */
```

三处异常：
1. `cpu-crit = 300 °C` —— 永远不会触发的过热保护（H618 结温上限远低于此）。
2. 所有 zone 的 `polling-delay` 与 `polling-delay-passive` 都是 **0** ——
   thermal 框架不做周期采样，除非有事件驱动，否则温度不会更新、cooling 不会动作。
3. `gpu-crit` 的 `type` 是 `passive` 而非 `critical`，即 GPU 过热只降频、不保护性关机。

### 问题 4（**已更正**）：OPP 电压与 `dcdc2` 上限**并不冲突**

> 更正说明：本文件早期版本这里写的是"OPP 最高档要求 1.100 V 超过 dcdc2 上限 1.080 V"，
> 那是把 `opp-microvolt-speed0 = <target min max>` 的 **max 列**误当成必需值。
> 实机 `dmesg` 显示 `sun50i-cpufreq-nvmem: will use speed0 CPU OPPs`，
> speed0 的 **target** 电压是 0.9–0.96 V，落在 `dcdc2` 的 0.81–1.08 V 内，**无冲突**。
> AXP313A 的 DCDC2 硬件范围本身是 0.5–1.54 V（见 `axp313a_dcdc2_ranges`），余量充足。

```
axp313a_dcdc2_ranges:
  REGULATOR_LINEAR_RANGE(500000,   0, 70, 10000)   -> 0.50 ~ 1.20 V
  REGULATOR_LINEAR_RANGE(1220000, 71, 87, 20000)   -> 1.22 ~ 1.54 V
```

> 另一个 opp table `gpu-opp-table`（phandle 0x0e）为 125/250/432/600/800 MHz，
> 电压 0.810 ~ 1.080 V —— 与 dcdc3 的固定 1.300 V 同样不匹配（见问题 2）。

---

## 三、对"CPU 锁 480 MHz"的推断

480 MHz 恰好是 `opp-table-cpu` 的档位之一，也是 U-Boot 常见的保守设定值。
结合上面的实测，可能的因果链有三条（**待实机验证**）：

1. **regulator 未正确注册** → `cpufreq-dt` 因拿不到 `cpu-supply` 电压而 probe defer → 无 `policy0`
   → CPU 保持 bootloader 频率（480 MHz）。
2. **PMIC 型号不匹配** → regulator 名称/编号映射错，`dev_pm_opp_set_voltage()` 失败。
3. **OPP 电压超出 regulator 上限**（问题 4）→ 高频档位被剔除，只剩低档。

实机上用 `scripts/hw-check.sh cpufreq` + `dmesg | grep -Ei 'axp|regulator|cpufreq|opp'`
即可区分。**先看 `dmesg` 里有没有 `cpufreq-dt: failed to probe` 或
`axp20x` 相关报错。**

---

## 四、修复方向（尚未实施，仅记录）

顺序上建议：

1. **先确认实机现状**（`hw-check.sh`），不要盲改 DTB。
2. `pmic@36` 的 `compatible` 改为 `"x-powers,axp313a"`，**但必须同时核对
   regulator 子节点名称与编号**——社区出现过只改 compatible 导致 HDMI 无法初始化的案例。
3. 修正 `mali-supply`：GPU 需要能调压的轨，不能指向固定的 `vdd-dram`。
4. 修正 `dcdc2` 的 `regulator-max-microvolt`（或调整 OPP 表电压），使高频档位可达。
5. 修正 `cpu-crit` 温度（常见 100~115 °C）、给各 zone 设合理的
   `polling-delay-passive`（如 1000 ms），并把 `gpu-crit` 的 type 改为 `critical`。
6. 全部验证通过后，再叠加 BinderFS / namespace 等 Waydroid 所需配置，一次性重编内核。

**重要**：只要重编 `Image`，就必须同步重编并部署所有外部模块
（`sprdwl_ng` / `uwe5622_bsp_sdio` / `sprdbt_tty`），并检查 `vermagic` 是否一致，
否则会直接丢掉 Wi-Fi 与 SSH。

---

## 五、相关文件
| 文件 | 说明 |
|---|---|
| `work/walnutpi-1b-decoded.dts` | 官方镜像 DTB 的反编译结果（1971 行，实测依据） |
| `work/debian-rootfs/boot/config-6.1.31` | 官方内核配置 |
| `work/debian-rootfs/lib/modules/6.1.31/` | 官方模块（含 uwe5622 系列） |
| `scripts/hw-check.sh` | 板端只读检查脚本（cpufreq/thermal/regulator/net/display/dmesg） |
| `patches/dts/pmic-axp313a.dts` | 修复 overlay（compatible + ramp-delay），编译产物 `.dtbo` 注入 boot 分区 |
| `scripts/pmic-diag.sh` | 板端 PMIC 采集脚本（I2C/regulator/cpufreq/设备树打包） |

---

## 六、实机验证（v0.2 上采集，2026-11-21）

在 WalnutPi ZeroW（Alpindroid v0.2，kernel 6.1.31）上通过 SSH 实测：

```
[    0.772025] axp20x-i2c 3-0036: AXP20x variant AXP806 found
[    0.783391] axp20x-i2c 3-0036: AXP20X driver loaded
[    1.891378] sun50i-cpufreq-nvmem: will use speed0 CPU OPPs
[   20.701990] platform cpufreq-dt: deferred probe pending      <<< 关键
```

I2C 设备：`name=axp305`，`driver=axp20x-i2c`，
`modalias=of:NpmicT(null)Cx-powers,axp305Cx-powers,axp805Cx-powers,axp806`

regulator 实际注册情况（AXP806 命名，且 **min/max 全为 0**）：

```
dcdca  state=enabled  now=600000    min=0  max=0
dcdcb  state=enabled  now=1400000   min=0  max=0
dcdcc  state=enabled  now=1000000   min=0  max=0
dcdcd  state=enabled  now=3000000   min=0  max=0
dcdce  state=enabled  now=2400000   min=0  max=0
aldo1..3 / bldo2..4 / cldo1..3   state=disabled  min=max=0
```

**结论**：`cpufreq-dt` 不是失败而是 `deferred probe pending`——它在等
`cpu-supply=<&dcdc2>` 的 regulator，而驱动创建的是 `dcdca~dcdce`，永远等不到。
这与第二节问题 1 的推断完全一致。

另外实测确认：`/sys/devices/system/cpu/cpufreq/` 存在但**没有任何 `policy*`**；
thermal 的 `cpu-crit = 300000`（300 °C）在运行时 DTB 中依然存在；
cooling device 列表为空（因 cpufreq 未注册）。

---

## 七、关键补充：AXP313A 缺少 `ramp_delay`（DVFS 稳定性风险）

上游补丁 `[PATCH] regulator: axp20x: AXP313A: set ramp_delay`
（Jernej Skrabec，2025-11-15）指出：AXP313A 的 DCDC 电压变化需要时间，
但驱动没有报告爬升速率，导致 CPUFreq 可能在电压未到位时就升频，
在 H616/H618 同类平台上观察到内核异常甚至整机卡死。参考速率 **400 µV/µs**。

本项目实测确认这一缺失：

| 检查项 | 结果 |
|---|---|
| `axp313a_regulators[]` 是否自带 `ramp_delay` | **没有** |
| 官方 DTB 是否有 `regulator-ramp-delay` | **没有**（`grep` 无结果） |
| 6.1.31 框架是否解析该属性 | **支持**：`of_regulator.c` 中 `of_property_read_u32(np, "regulator-ramp-delay", &pval)` |
| 后果 | 框架认为爬升时间 = 0，升压后立即升频 |

因此可以在**不重编内核**的前提下，用设备树补齐：

```dts
&{/soc/i2c@7081400/pmic@36/regulators/dcdc2} {
	regulator-ramp-delay = <400>;   /* uV/us，约每 10 mV 等 25 us */
};
```

本项目给 **dcdc1（GPU+SYS）与 dcdc2（CPU）** 两路都加了该属性；
`dcdc3`（vdd-dram）在 DTB 中 `min==max==1.3V` 固定、不调压，无需该属性。

> 注意：`regulator_set_voltage()` 本身不睡眠等待，等待时间由 OPP 框架用
> `regulator_set_voltage_time()` 算出后 `udelay`。所以 ramp_delay 必须让框架能读到，
> 否则等待时间为 0。

---

## 八、v0.3-pm 的修复方式（overlay，不改原 DTB、不重编内核）

`patches/dts/pmic-axp313a.dts` 编译为 `sun50i-h616-pmic-axp313a.dtbo`，
放入 boot 分区 `overlays/`，并在 `config.txt` 的 `overlays=` 追加 `pmic-axp313a`。
`boot.cmd` 会依次 `fdt apply`，且 apply 失败时自动回滚到原 DTB。

三个 fragment：

| fragment | target-path | 内容 |
|---|---|---|
| 0 | `/soc/i2c@7081400/pmic@36` | `compatible = "x-powers,axp313a"` |
| 1 | `.../regulators/dcdc2` | `regulator-ramp-delay = <400>` |
| 2 | `.../regulators/dcdc1` | `regulator-ramp-delay = <400>` |

注入前后原 DTB 的 md5 未变（`67164bec…` / `2a946d14…`），
内核 `Image`、U-Boot、`boot.scr`、`initrd` 全部未改。

**回退**：从 `config.txt` 的 `overlays=` 去掉 `pmic-axp313a` 即恢复官方行为。
boot 分区是 FAT32，可直接在 Windows 上编辑。

---

## 九、DCDC3（vdd-dram）1.3 V 疑点 —— 首次启动前必须核实

### 9.1 交叉对照：主线同芯片板子是 1.1 V

| 来源 | dcdc3 定义 |
|---|---|
| 核桃派 `sun50i-h616-walnutpi-1b.dts` | `min = max = <1300000>`（vdd-dram） |
| 主线 `sun50i-h618-orangepi-zero3.dts` | `min = max = <1100000>`（vdd-dram） |
| 主线 `sun50i-h618-orangepi-zero2w.dts` | `min = max = <1100000>`（vdd-dram） |

LPDDR4 的 VDD2 标准值是 **1.1 V**，1.3 V 超出常规额定范围。
核桃派 DTS 里这个 1.3 V 没有任何注释解释，**很可能是遗留错误**。

### 9.2 为什么"只加 compatible"就可能烧板

regulator 框架注册 pmic 的 regulator 时会调用 `machine_constraints_voltage()`：
**若当前电压落在 DTS 约束范围之外，会强制把电压调到范围内。**

- **现在**（PMIC 被当 AXP806）：DTB 的 `dcdc1/2/3` 节点匹配不到任何 regulator，
  约束全部无效 → DCDC3 电压是 U-Boot / 芯片默认值（板子长期正常运行，
  反证实际电压**不是** 1.3 V，大概率 1.1 V）
- **切到 AXP313A 后**：约束生效 → 若当前是 1.1 V 而约束是 `min=max=1.3V`，
  框架会把 DRAM 拉到 1.3 V → **有损坏风险**

### 9.3 已采取的保护（不做任何"设电压"动作，只是不干涉）

1. **`dcdc3` 约束放宽到硬件全量程** `500000 ~ 1840000`
   （对应 `axp313a_dcdc3_ranges` 的 0.5–1.84 V）。
   当前电压必定落在范围内 → 框架不做任何调整。
   > 没有使用 `/delete-property/`：实测 `dtc` 在 overlay 里会把它丢弃
   > （编译后 `__overlay__` 为空），且 libfdt/U-Boot 的 `fdt_overlay_apply`
   > 只保证复制属性、不保证支持删除。
2. **通过 overlay 禁用 Mali GPU**（`/soc/gpu@1800000 { status = "disabled"; }`）：
   DTB 中 `mali-supply = <&dcdc3>` 指向 DRAM 轨，切到 AXP313A 后这个错误引用
   会第一次真正绑定到 DRAM 电源，Panfrost 若请求调压会影响 DRAM。
   HDMI 文本终端走 `DRM_SUN4I` display engine + fbdev，**不依赖 Mali 3D**，不受影响。

### 9.4 如何确定性读出当前 DCDC3 实际电压（烧 v0.2c 后执行）

AXP313A 寄存器（`include/linux/mfd/axp20x.h`）：

```
AXP313A_OUTPUT_CONTROL  0x10     各路输出使能位
AXP313A_DCDC1_CONRTOL   0x13
AXP313A_DCDC2_CONRTOL   0x14
AXP313A_DCDC3_CONRTOL   0x15     <-- DRAM
电压字段掩码 AXP313A_DCDC_V_OUT_MASK = GENMASK(6, 0)（低 7 位）
```

读法（I2C bus 3，地址 0x36）：

```sh
sudo apk add i2c-tools
sudo i2cdetect -y 3
for reg in 0x10 0x13 0x14 0x15; do
    v=$(sudo i2cget -y 3 0x36 $reg)
    idx=$(( v & 0x7f ))
    if [ $idx -le 70 ]; then mv=$(( 500 + idx * 10 )); else mv=$(( 1220 + (idx - 71) * 20 )); fi
    echo "$reg = $v  index=$idx  -> ${mv} mV"
done
```

换算依据 `axp313a_dcdc2_ranges` / `axp313a_dcdc3_ranges`：
`REGULATOR_LINEAR_RANGE(500000, 0, 70, 10000)` 与
`REGULATOR_LINEAR_RANGE(1220000, 71, 87|102, 20000)`。

### 9.5 验收判据修正

1. **regulator 名字不一定显示 `dcdc1/2/3`**：`/sys/class/regulator/regulator.X/name`
   优先显示 DTS 里的 `regulator-name`，所以修复后应看到
   `vdd-gpu-sys` / `vdd-cpu` / `vdd-dram` —— 这**才是正确**的表现。
2. **dmesg 里残留的 `deferred probe pending` 不一定代表失败**：驱动后续可能已成功。
   应以 `/sys/devices/system/cpu/cpufreq/policy0` 是否出现、以及
   `/sys/bus/i2c/devices/3-0036/driver` 的最终绑定为准。
3. **ramp-delay 是否进入运行时设备树**，直接读伪文件（需 root）：

```sh
for rail in dcdc1 dcdc2; do
    f="/proc/device-tree/soc/i2c@7081400/pmic@36/regulators/$rail/regulator-ramp-delay"
    echo "$rail:"; [ -f "$f" ] && od -An -tx1 "$f" || echo "  属性不存在"
done
# 期望两路都输出: 00 00 01 90   (= 400 uV/us)
```
