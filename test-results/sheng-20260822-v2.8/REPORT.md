# Sheng v2.8 现场报告

日期：2026-08-22

设备：Xiaomi Pad 6S Pro 12.4（sheng）

系统：HyperOS 4

模块：HyperOS 4 Launcher Scheduling v2.8

## 结论

快滑、慢滑、取消、桌面打开应用和最近任务打开同一应用均按设计执行。最终桌面态下 source、壁纸和 MIMD 位于 background，Launcher 位于 top-app；稳定应用态下目标应用位于 top-app。

## 取消

```text
78.13  source-yield; entering
78.29  first guarded reassert
78.49  second guarded reassert
78.52  source-restored after epoch invalidation
78.83  app
```

取消两秒后 KernelSU 仍为：

```text
cpuset:/top-app
cpu:/top-app
```

## 慢滑与最近任务打开应用

```text
92.26  source-yield; entering
92.73  home / Launcher resumed
93.10  recents
94.30  leaving
94.41  pending-source cached
94.42  same-PID target restored
95.38  app
```

稳定最近任务中 source 为 background；点 KernelSU 卡片后目标为 top-app。此次路径没有 `launcher-transition-canceled`，证明 `gesture.active` 正确区分了上滑取消和卡片选择。

## 快滑后的桌面态

```text
KernelSU source                    cpuset/background  cpu/background
com.miui.home                      cpuset/top-app     cpu/top-app
com.miui.miwallpaper               cpuset/background  cpu/background
vendor.xiaomi.hardware.mimd@2.0    cpuset/background  cpu/background
```

进程结构：

```text
service.sh
├─ launcher-logwatch
└─ service.sh pipeline reader
```

不存在旧 logcat 监听器或第二个模块守护。
