# Prime Raster 与提前退避的轻载对照

## 改动

5.1 同时测试两项调度改动：

1. 根据运行时 `cpu_capacity` 单独推导 prime mask。Launcher `1.raster` 固定使用 prime；默认设置下，`1.ui`、Rust 主线程、`IplrVkResMgr` 和 `IplrVkFenceWait` 使用去掉 prime 的 performance 集合。SurfaceFlinger affinity 不变。
2. `launcher-logwatch` 收到 Launcher 转场起点后，先把来源 PID 写入 background cpuset/cpuctl，再执行逐 TID affinity 事务。这样来源进程先退出前台资源组，线程枚举、状态保存和 affinity 写入随后完成。

在 Sheng 上推导得到：

```text
all=ff  perf=f8  mid=78  little=07  prime=80
1.raster: CPU7
1.ui / rt-launcher-main / ResMgr / FenceWait: CPU3-6
```

短时 `boost-duration-ms` 只控制 uclamp。基础 affinity 不随该计时器复位，因而覆盖完整 Launcher 动画。

## 测试方法

设备为 Sheng HyperOS 4，轻载来源应用为文件管理。每轮执行相同操作：重新启动文件管理，等待 1.4 秒，使用 480 ms 屏幕三指手势进入最近任务，等待约 2 秒，点击当前卡片返回。

对照组通过 KernelSU 禁用整个模块并重启，确认守护进程和 `launcher-logwatch` 均不存在，共采集三轮。5.1 组跨两次启用启动共采集六轮。两组使用同一 Perfetto 配置，记录 sched、CPU 频率、FrameTimeline、Launcher、SystemUI 和 SurfaceFlinger 图形切片；测试完成后恢复常亮设置并停止采集。

两组不是逐轮交替重启，结果适合判断稳定的大方向，不用于解释单个 FrameTimeline 离群。

## 结果

下表为各轮中位数，时间单位为 ms。采集窗口从手势前到进入最近任务后的 800 ms。

| 指标 | 模块关闭 | 5.1 | 变化 |
|---|---:|---:|---:|
| 来源应用 performance CPU 时间 | 24.721 | 11.110 | -55.1% |
| 来源应用总 CPU 时间 | 55.688 | 84.165 | +51.1% |
| Launcher 总 CPU 时间 | 1322.407 | 1258.856 | -4.8% |
| Raster Running | 466.736 | 401.983 | -13.9% |
| Raster Runnable 等待 | 47.196 | 28.820 | -38.9% |
| Raster Draw 总墙钟 | 779.404 | 458.893 | -41.1% |
| 最长 Raster Draw | 20.702 | 12.738 | -38.5% |
| 超过 144 Hz 预算的 Draw 数 | 65 | 4.5 | -93.1% |
| SurfaceFlinger CPU 时间 | 1003.723 | 998.032 | -0.6% |
| SystemUI CPU 时间 | 302.190 | 324.956 | +7.5% |
| Full FrameTimeline 标记 | 4 | 6.5 | +2.5 |
| 其中 SystemUI Full 标记 | 2 | 5.5 | +3.5 |

来源应用总 CPU 时间增加，是相同收尾工作在低容量 CPU 上需要更多 task-clock 的直接结果；它在 performance CPU 上的占用则下降一半以上。该策略的目的属于资源隔离，不是减少来源应用的计算量。

Raster 固定 prime 后，六轮的 Runnable 中位数和最长 Draw 均明显下降，说明 CPU 放置解决了 Launcher Raster 的一部分就绪等待和执行速度问题。SurfaceFlinger 总 CPU 时间基本不变，符合本轮未修改 SF 的边界。

FrameTimeline 的全局结果没有同步改善。增加的 Full 标记主要来自 SystemUI 状态栏和导航栏的 `App Resynced Jitter`、`SurfaceFlinger Stuffing`，在 5.1 各轮为 0–10 个，离群范围较大。因此本测试能确认 Launcher 局部关键路径改善，不能证明轻载端到端动画比模块关闭更稳定。

## cgroup 快路径

代表样本中，两次 background cgroup 写入在 2.018 ms 内完成，随后逐 TID affinity 事务用时 17.540 ms。调整顺序使来源应用提前约 15.5 ms 离开前台 cgroup。

这里的 2.018 ms 从 Launcher `gestureStart` 日志被监听器收到后开始计算。物理手势开始到 Launcher 发出该事件仍约为 160–180 ms，不属于 cgroup 写入耗时。

## 结论

5.1 的两项改动达到了预定的局部目标：来源应用更早退出前台资源组，Raster 与 UI/Rust 不再共享 prime，Raster 的运行量和就绪等待下降。

轻载下没有得到“整体流畅度稳定优于模块关闭”的结论。来源应用总 task-clock 增加，SystemUI/SF 交接仍存在独立离群。后续若继续优化，应针对来源应用负载做自适应退避，或单独定位 SystemUI/SF 的交接帧，不能用 Launcher Raster 的局部改善代替全链路结论。
