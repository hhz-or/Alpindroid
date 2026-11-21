#!/usr/bin/env python3
# 修复厂商树 panfrost 的 suspend/resume 路径
# 根因：resume 未恢复 GPU 复位与时钟，导致 resume 后访问寄存器总线锁死（硬挂死）
import sys

p = "drivers/gpu/drm/panfrost/panfrost_device.c"
s = open(p).read()
orig = s
ok = 0

# ---- 1. 补强 resume ----
old_resume = """int panfrost_device_resume(struct device *dev)
{
\tstruct panfrost_device *pfdev = dev_get_drvdata(dev);

\tpanfrost_device_reset(pfdev);
\tpanfrost_devfreq_resume(pfdev);

\treturn 0;
}"""

new_resume = """int panfrost_device_resume(struct device *dev)
{
\tstruct panfrost_device *pfdev = dev_get_drvdata(dev);
\tint ret;

\t/*
\t * Alpindroid: 对齐主线 panfrost_device_runtime_resume()。
\t * 厂商版本原先只调用 panfrost_device_reset()，既没有解除 GPU 复位，
\t * 也没有重新使能时钟。而 suspend 时 GPU 电源域已被关闭，
\t * genpd 不会替本设备恢复复位/时钟，于是 resume 后第一次访问 GPU
\t * 寄存器就在「复位中 + 无时钟」状态下锁死总线——
\t * 实测表现为硬挂死（串口连 printk 都打不出来，需断电重启）。
\t */
\tret = reset_control_deassert(pfdev->rstc);
\tif (ret) {
\t\tdev_err(pfdev->dev, "resume: deassert reset failed %d\\n", ret);
\t\treturn ret;
\t}

\tret = clk_prepare_enable(pfdev->clock);
\tif (ret) {
\t\tdev_err(pfdev->dev, "resume: enable core clock failed %d\\n", ret);
\t\treset_control_assert(pfdev->rstc);
\t\treturn ret;
\t}

\tif (pfdev->bus_clock) {
\t\tret = clk_prepare_enable(pfdev->bus_clock);
\t\tif (ret) {
\t\t\tdev_err(pfdev->dev, "resume: enable bus clock failed %d\\n", ret);
\t\t\tclk_disable_unprepare(pfdev->clock);
\t\t\treset_control_assert(pfdev->rstc);
\t\t\treturn ret;
\t\t}
\t}

\tpanfrost_device_reset(pfdev);
\tpanfrost_devfreq_resume(pfdev);

\treturn 0;
}"""

if old_resume in s:
    s = s.replace(old_resume, new_resume, 1)
    ok += 1
    print("  [+] resume: 已补 reset_control_deassert + clk_prepare_enable")
else:
    print("  [!] resume 块未匹配，请检查当前内容")

# ---- 2. suspend 对称处理 ----
old_susp = """\tpanfrost_devfreq_suspend(pfdev);
\tpanfrost_gpu_power_off(pfdev);

\treturn 0;
}"""

new_susp = """\tpanfrost_devfreq_suspend(pfdev);
\tpanfrost_gpu_power_off(pfdev);

\t/*
\t * Alpindroid: 与 resume 对称——关闭时钟并断言复位，
\t * 避免 GPU 停在「时钟开着但电源域已关」的中间态被访问。
\t */
\tif (pfdev->bus_clock)
\t\tclk_disable_unprepare(pfdev->bus_clock);
\tclk_disable_unprepare(pfdev->clock);
\treset_control_assert(pfdev->rstc);

\treturn 0;
}"""

if old_susp in s:
    s = s.replace(old_susp, new_susp, 1)
    ok += 1
    print("  [+] suspend: 已补 clk_disable_unprepare + reset_control_assert")
else:
    print("  [!] suspend 块未匹配，请检查当前内容")

if s != orig:
    open(p, "w").write(s)
    print("  [=] 已保存（%d 处修改）" % ok)
else:
    print("  [=] 文件未变化")
    sys.exit(1)
