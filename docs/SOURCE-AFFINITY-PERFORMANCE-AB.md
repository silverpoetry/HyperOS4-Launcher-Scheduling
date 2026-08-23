# 来源应用 affinity 性能 A/B

## 测试方法

设备为 Sheng，来源应用为 `com.tencent.jkchess`。每组连续执行四轮相同动作：应用前台三指上滑进入最近任务，等待后点击当前卡片返回应用。Perfetto 记录 compact sched、FrameTimeline、Launcher/SystemUI 图形事件和 CPU 频率。

正式组与对照组均使用 v4.0 的 Launcher 线程策略、状态机和 cgroup 策略。对照组仅临时去掉 `source-affinityctl` 的执行权限，因此唯一差异是来源应用逐线程 affinity 事务是否生效。测试结束后已恢复权限。

另采集 Settings 作为低来源负载参考。它用于比较 Launcher 自身的等待和尾部延迟，不把 Settings、状态栏或 Display HAL 自身的 jank 数直接当作 Launcher 基线。

## 同负载开关对比

四次进入窗口合计约 7 秒：

| 指标 | affinity 关闭 | affinity 开启 | 变化 |
|---|---:|---:|---:|
| 来源应用 CPU 时间 | 4007.1 ms | 3925.0 ms | -2.0%，负载可比 |
| 来源应用在 CPU3–7 的占比 | 35.7% | 15.8% | -19.9 个百分点 |
| 来源应用在 CPU3–7 的时间 | 1430.5 ms | 618.4 ms | -56.8% |
| Launcher CPU 时间 | 5808.2 ms | 5747.7 ms | -1.0% |
| Launcher 关键线程 runnable 等待 | 1723.6 ms | 1607.0 ms | -6.8% |
| Launcher 帧 p95 | 19.57 ms | 18.16 ms | -7.2% |
| Launcher 最大帧 | 69.46 ms | 64.53 ms | -7.1% |
| `CALLBACK_ANIMATION` 最大值 | 167.46 ms | 60.92 ms | -63.6% |
| `CALLBACK_ANIMATION` 超过 16.67 ms | 16 | 13 | -18.8% |
| 全链路 Full/Partial | 28 | 14 | -50.0% |

关闭 affinity 时出现多组 57–69 ms 的 Launcher、Floating Dock 和两个 task transition leash 同步 deadline miss。开启后的第二次样本中没有 Launcher 或 task transition leash 的 Full/Partial jank；剩余事件来自 Miui Caption、DockAssistantView、状态栏和 Display HAL。

两次开启样本的尾部并不完全一致。第一次开启样本中仍出现 Floating Dock 82.4 ms Full jank，并伴随 Launcher Dart `ConcurrentMark` 约 50 ms、TaskSnapshot 写队列约 507 ms 和长 UI callback。逐线程退避消除了来源应用的大核竞争，但不会消除 Launcher GC、任务快照或辅助窗口的偶发工作。

## 触发后的实际 CPU 放置

第二次开启样本的四个入口事件中，控制器完成后的以下三个区间都只记录到 CPU0–2：

```text
0–100 ms
100–300 ms
300–600 ms
```

完整入口窗口中仍有 15.8% 来源 CPU 时间位于 CPU3–7，主要发生在手势开始到 Launcher 发出 `gestureStart` 之间约 0.2 秒。模块不监听原始第三触点；只有应用窗口真正开始卡片化时才退避，避免应用内三指手势误触发。

## 与低负载参考的距离

低负载 Settings 样本中，Launcher 关键线程 runnable 等待为 887.8 ms；高负载游戏开启 affinity 后仍为 1607.0 ms，高约 81%。`CALLBACK_ANIMATION` 超过 16.67 ms 的次数分别为 11 和 13，已经接近；最大值分别为 41.46 ms 和 60.92 ms，尾部仍有差距。

因此可以认为常见 Launcher/transition-leash 卡顿已明显接近低负载状态，但不能认为整条显示链已经稳定等同于无负载。剩余瓶颈是：

1. `system_server` 的 TaskSnapshot、窗口动画和 binder 工作；
2. Launcher Dart UI/Raster 与偶发 GC；
3. SystemUI 的 Miui Caption 小窗按钮；
4. SecurityCenter 的 DockAssistantView；
5. SurfaceFlinger、Display HAL 和来源应用仍然存在的 GPU/内存带宽竞争。

CPU affinity 不会停止来源应用提交 GPU 工作，也不会隔离共享内存带宽。下一阶段若继续优化，应针对最近任务动画期的 Caption、DockAssistantView、Floating Dock 和 TaskSnapshot 分别做开关 A/B，不再继续压低来源应用 CPU 权重。
