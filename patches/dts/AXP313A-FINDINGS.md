# AXP313A PMIC — findings and measurements

Hardware measurement log for the AXP313A PMIC (U3) on the WalnutPi ZeroW (H618).
All values captured from the running board via `i2cget` / `/sys/class/regulator/`.

---

## 1. The core problem

The vendor DTS declares the PMIC as **AXP806**:

```dts
pmic@36 {
    compatible = "x-powers,axp806";   /* wrong */
    ...
};
```

AXP806 and AXP313A are different chips with different register maps and different
regulator names:

| Chip | DC-DC rails |
|---|---|
| AXP806 | `dcdca` `dcdcb` `dcdcc` `dcdcd` `dcdce`, plus `aldo1/2`, `bldo1`, `cldo1` |
| AXP313A | `dcdc1` `dcdc2` `dcdc3`, plus `aldo1`, `dldo1` |

The board DTS defines regulators as `dcdc1` / `dcdc2` / `dcdc3`. With the PMIC
misidentified as AXP806 the kernel creates `dcdca`…`dcdce` instead, so **every**
`<&reg_dcdc1>` style reference fails to resolve.

**Consequences observed on hardware:**

```
cpufreq-dt: deferred probe pending      # cpu-supply = <&reg_dcdc2> unresolved
mali-supply: probe deferred             # GPU rail unresolved
```

**Fix:** one line in the DT overlay:

```dts
fragment@0 {
    target-path = "/soc/i2c@7081400/pmic@36";
    __overlay__ { compatible = "x-powers,axp313a"; };
};
```

After reboot: `dmesg | grep -i axp` → `axp313a found`, and the regulator tree appears.

---

## 2. Regulator roles (measured)

| Rail | Name in DTS | Measured | Role |
|---|---|---|---|
| `dcdc1` | `vdd-gpu-sys` | 900 mV (min 900, max 1160) | **GPU + SYS, shared** |
| `dcdc2` | `vdd-cpu` | 900 mV (min 810, max 1080) | CPU (cpufreq) |
| `dcdc3` | `vdd-dram` | 1100 mV | DRAM |
| `vcc33-wifi` | — | 3300000 µV | WiFi/BT 3.3 V (fixed regulator) |
| `vcc-wifi-io` | — | 1800000 µV | WiFi/BT IO 1.8 V (fixed regulator) |

### Readings from the board

```
$ for r in /sys/class/regulator/regulator.*/; do
    echo "$(cat $r/name): $(cat $r/microvolts 2>/dev/null)"
  done

vdd-gpu-sys   : 900000
vdd-cpu       : 900000
vdd-dram      : 1100000
vcc33-wifi    : 3300000
vcc-wifi-io   : 1800000
```

### The vendor DTS is wrong in two places

**① `dcdc3` declared as fixed 1.3 V**

```dts
reg_dcdc3: dcdc3 {
    regulator-min-microvolt = <1300000>;
    regulator-max-microvolt = <1300000>;
};
```

Actual silicon reads 1.1 V. The mainline `orangepi-zero3` / `zero2w` DTS files also use 1.1 V.
Overlay fragment 3 corrects it to `min = max = 1100000`.

**② `mali-supply` points at `dcdc3`**

```dts
&gpu {
    mali-supply = <&reg_dcdc3>;   /* dcdc3 is vdd-dram! */
};
```

`dcdc3` is the DRAM rail, fixed at 1.3 V. The GPU rail is `dcdc1` (`vdd-gpu-sys`).
The board DTS now says:

```dts
&gpu { mali-supply = <&reg_dcdc1>; };
```

---

## 3. What `dcdc1` can and cannot do

`dcdc1` supplies **both** the GPU and the system rail. This has a hard consequence:

- With a multi-point OPP table, Panfrost will request 810 mV at the lowest frequency.
- Dropping `vdd-gpu-sys` to 810 mV browns out the system.

**Measured in v0.4:** setting `mali-supply` to `dcdc1` with the vendor three-point
OPP table caused the board to fail to boot. A multimeter on VGPU showed 0.9 V → 0.8 V.

**Current approach:** a single OPP at 432 MHz @ 900 mV, with `dcdc1` `min-microvolt`
raised to 900000. GPU DVFS is disabled (`panfrost_devfreq_init` returns early).
This keeps the system stable at the cost of not scaling GPU frequency.

Lifting this restriction requires backporting the PLL reparent fix
(CVE-2025-38041, upstream `eb963d79`).

---

## 4. Register-level check of the PPU (GPU power domain)

The PPU lives in the PRCM block at `0x07010250`. The GPU gate is `0x07010254` bit 0.

```sh
# read (needs devmem2; busybox has no devmem applet on Alpine)
apk add devmem2
devmem2 0x07010254 w     # -> 0x00000001 when the domain is off (FLAG_PPU_NEGATED)
devmem2 0x07010250 w     # -> 0x00000010 (ANA bit4 = 1, on)
```

Interpretation for H616 (`sun50i_h616_ppus[]` in the driver):

| Domain | Register | Mask | Flags |
|---|---|---|---|
| PLL | `0x250` | `BIT(2)` | `ALWAYS_ON \| NEGATED` |
| ANA | `0x250` | `BIT(4)` | `ALWAYS_ON` |
| GPU | `0x254` | `BIT(0)` | `NEGATED` (domain 2) |

`NEGATED` means **clearing the bit powers the domain on**. Reading `0x1` means the
GPU domain is currently unpowered, which is correct while the device is runtime-suspended.

> **Diagnostic note:** writing this register by hand while the GPU is suspended will
> hard-lock the bus (no printk, requires power cycling). Do not experiment on a live
> system unless you intend to reboot.

---

## 5. Thermal zone defects

The vendor DTS has two mistakes in the thermal zones:

| Zone | Vendor value | Problem | Fixed to |
|---|---|---|---|
| `cpu-crit` trip | `temperature = <300000>` | 300 °C — the board would cook before this triggers | `115000` (115 °C) |
| `cpu-thermal` polling | `polling-delay = <0>` | Zero means polling disabled, so the zone never updates | `1000` ms |
| `gpu-crit` trip | `type = "passive"` | A critical trip must be `critical`, otherwise it throttles instead of shutting down | `"critical"` |

These do not affect GPU bring-up but do affect long-run stability under load.

---

## 6. HDMI `hvcc-supply`

The board DTS references a regulator that AXP313A does not have:

```dts
&hdmi {
    hvcc-supply = <&reg_bldo1>;   /* bldo1 is AXP806-only */
};
```

The vendor patched this at runtime through the overlay with a hardcoded phandle,
which broke as soon as the DTB was rebuilt (phandle drift pointed it at `vcc33-wifi`
instead of `vcc-wifi-io`, so HDMI stole the WiFi supply).

Now fixed in the board DTS with a label:

```dts
&hdmi { hvcc-supply = <&reg_vcc_wifi_io>; };
```

---

## 7. Verification commands

```sh
# PMIC identified correctly?
cat /proc/device-tree/soc/i2c@7081400/pmic@36/compatible; echo

# Regulator tree present?
for r in /sys/class/regulator/regulator.*/; do
  echo "$(cat $r/name): $(cat $r/microvolts 2>/dev/null) uV"
done

# CPU frequency scaling working?
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq

# Thermal zones sane?
for z in /sys/class/thermal/thermal_zone*/; do
  echo "$(cat $z/type): $(( $(cat $z/temp) / 1000 )) C"
done

# PPU domain state
cat /sys/kernel/debug/pm_genpd/pm_genpd_summary | grep -i gpu
```