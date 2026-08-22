# Shennong A/B 测试记录

## 环境

```text
设备：Xiaomi 14 Pro / shennong
系统：HyperOS 4.0 / Android 17
SoC：Snapdragon 8 Gen 3
background cpuset：0-1,5-6
测试源应用：com.tencent.mm
```

测试期间临时切换到三键导航，以便使用 `KEYCODE_APP_SWITCH` 重复产生同一最近任务入口。测试完成后恢复手势导航。

## 验证中发现并修复的问题

### 进入状态永久卡住

旧实现要求收到 `exitOverviewState` 才清除 `in_recents`。某些退出路径没有这条日志，导致后续进入信号被永久忽略。

修复后按进入时间做 750 ms 去重。新的主进入信号不再依赖上一轮退出日志。

### ActivityManager 覆盖首次退避

首次写入后台组后约 100-110 ms，ActivityManager 会把源应用再次提升为 `foreground`。旧实现因此只退避约 80 ms。

修复后在 120 ms 和 320 ms 重复确认源应用位于后台组，并通过 generation 与前台恢复令牌阻止过期任务影响已经恢复的应用。

### 重启模块遗留监听器

旧操作脚本只终止主守护进程，管道中的监听子进程可能被重新托管到 PID 1。现场同时存在三套监听器，并争用同一个临时文件。

修复后模块启动时清理自己遗留的守护、EventLog 监听器和桌面日志监听器；操作和卸载使用强制终止；活动缓存临时文件带监听进程 PID。

## cgroup 时序

两轮有效启用样本显示：

```text
进入信号到整组操作完成：A/B 样本为 30-50 ms，附加高负载验证最高 110 ms
首次写入 source/background：信号后约 0-20 ms
ActivityManager 提升回 foreground：约 100-110 ms
第一次重新写入 background：120 ms
第二次重新写入 background：320 ms
```

禁用模块时，ActivityManager 在约 670-750 ms 后才把源应用自然放入 `background`。

## 源应用 CPU 分布

2 秒全窗口包括进入前 200 ms，数据如下：

| 状态 | 样本 | 全核心 CPU 时间 | CPU 2-4,7 时间 |
|---|---:|---:|---:|
| 启用 | 1 | 379.855 ms | 33.957 ms |
| 启用 | 2 | 263.748 ms | 23.002 ms |
| 禁用 | 1 | 246.800 ms | 22.920 ms |
| 禁用 | 2 | 353.217 ms | 32.320 ms |

总 CPU 时间受应用后台活动影响，波动明显。启用平均约 321.8 ms，禁用平均约 300.0 ms，不能证明模块降低了总负载。

进入后 250-750 ms 是退避差异最明确的窗口：

| 状态 | 样本 | CPU 2-4,7 时间 |
|---|---:|---:|
| 启用 | 1 | 0.000 ms |
| 启用 | 2 | 0.000 ms |
| 禁用 | 1 | 5.304 ms |
| 禁用 | 2 | 4.130 ms |

禁用平均为 4.717 ms。模块在这个 500 ms 窗口中完全消除了源应用在后台组以外核心上的运行时间。

## 模块自身开销

空闲 10 秒时，所有常驻进程均为 0 CPU tick。

连续三次进入和退出最近任务：

```text
常驻进程合计：42 ticks，约 420 ms CPU
桌面 main 日志过滤器：38 ticks，约 380 ms CPU
其它常驻 shell：4 ticks，约 40 ms CPU
```

这些进程全部位于 `background` cgroup，因此不会运行在 CPU `2-4,7`；但会增加后台核心负载和功耗。当前结果说明模块减少的是性能核心竞争，不是系统总 CPU 消耗。

## 采用的原始数据

```text
enabled_fixed_1.txt
enabled_fixed_2.txt
disabled_1.txt
disabled_2.txt
enabled_perf_1.csv
enabled_perf_2.csv
disabled_perf_1.csv
disabled_perf_2.csv
enabled_window_1.csv
enabled_window_2.csv
disabled_window_1.csv
disabled_window_2.csv
```

天气首次启动被系统隐私确认页拦截，最初一轮天气样本无效，没有纳入结论。合成手势被识别为返回桌面的样本也没有纳入结论。
