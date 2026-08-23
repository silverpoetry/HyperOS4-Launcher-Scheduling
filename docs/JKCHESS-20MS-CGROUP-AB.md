# 金铲铲最近任务动画 20 ms cgroup 重写实验

## 目的

验证在 Launcher 动画期间每 20 ms 将来源应用重新写入 `background` cpuset/cpuctl，能否阻止 ActivityManager 或厂商调度再次把高负载应用提升到性能核心。

测试设备为 Sheng。来源应用为 `com.tencent.jkchess`，测试期间主进程 PID 始终为 `23251`。每组执行四轮相同操作：屏幕三指上滑进入最近任务、点击当前卡片返回应用，再立即开始下一轮。A/B 均为暖态进程，不清除应用数据、不重启应用进程。

## 实现

实验版在原生 `launcher-logwatch` 中增加一个条件变量守护线程：

- 进入动画：从 `gestureStart` 持续到 `enterOverviewState`、`gestureToHome` 或取消；
- 返回动画：从 `exitOverviewState` / `openingRemoteAnimationOpen` 持续到 `openingRemoteAnimationClose`；
- 动画外线程阻塞，不轮询；
- 动画内将缓存的 source PID 及出现后的 pending PID 写入 `background` 的 cpuset/cpuctl；
- 测试了相对睡眠 20 ms 和绝对时钟 20 ms 两种实现。

## 数据

| 指标 | v3.5 单次写入 | 20 ms 相对睡眠 | 20 ms 绝对节拍 |
|---|---:|---:|---:|
| 压力段时长 | 13.86 s | 13.89 s | 13.82 s |
| 四次进入窗口：游戏小核运行 | 1109.3 ms | 1149.4 ms | 1075.2 ms |
| 四次进入窗口：游戏性能核运行 | 1136.4 ms | 1181.1 ms | 1109.8 ms |
| 游戏性能核运行占比 | 50.6% | 50.7% | 50.8% |
| Launcher `CALLBACK_ANIMATION` 超过 8.33 ms | 16 | 17 | 16 |
| Launcher `CALLBACK_ANIMATION` 超过 16.67 ms | 14 | 13 | 14 |
| Full/Partial FrameTimeline jank | 10 | 9 | 11 |
| 原生监听进程 CPU 时间 | 333.2 ms | 366.4 ms | 387.3 ms |

绝对节拍候选在八段进入/返回动画中执行了 228 个周期、240 次 PID 重写。cgroup 写入累计墙钟时间 220.83 ms，平均每个 PID 0.920 ms，最慢一次 23.898 ms。监听进程相对 v3.5 增加约 54.1 ms CPU 时间，折合压力段内约 0.39% 的单核占用。

## 结论

20 ms 重写的用户态 CPU 开销较小，但没有降低游戏在性能核心上的运行比例，也没有减少 Launcher 长回调或 FrameTimeline jank。调度记录显示 `UnityMain`、`UnityGfxDeviceW`、主线程、Job Worker 和 MediaCodec 线程仍会在相邻两次写入之间回到 CPU3–7。

因此问题不是一次性 cgroup 写入缺少足够高的重复频率。系统或厂商调度会持续对游戏线程应用新的 task profile；反复写进程级 `cgroup.procs` 只是在两个控制器之间争夺状态。个别 cgroup 写入已经超过 20 ms 周期，继续提高频率会增加 cgroup 锁和迁移成本。

本实验候选不进入正式版本。后续若继续处理，应针对实际高负载 TID 的调度来源和 task profile 进行定位，而不是提高进程级 cgroup 重写频率。

## 原始记录

- v3.5 暖态基线：`test-results/sheng-jkchess-recents-warm-20260823-174534`
- 20 ms 相对睡眠：`test-results/sheng-jkchess-recents-warm-20260823-174634`
- 20 ms 绝对节拍：`test-results/sheng-jkchess-recents-warm-20260823-175049`
