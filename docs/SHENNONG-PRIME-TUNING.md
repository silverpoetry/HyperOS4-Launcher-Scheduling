# Shennong 动画期 prime 调度验证

## 问题

Shennong 恢复官方调度后，全局 cpuset 为：

```text
top-app:    0-7
foreground: 0-7
background: 0-1,5-6
```

模块 3.0 据此得到：

```text
perf:   9c  # CPU2-4,7
mid:    1c  # CPU2-4
little: 03  # CPU0-1
```

CPU7 已包含在 Raster/UI 的亲和掩码中，但不代表调度器必须使用它。CPU2-4 的 `cpu_capacity` 为 923，而 3.0 的 Raster/UI uclamp minimum 只有 768/640。EAS 可以在 CPU2-4 满足需求，为降低能耗会减少使用 capacity 1024 的 CPU7。

## 候选策略

测试了三种策略：

1. 3.0 基线：Raster、UI 和 Rust 共享 `perf`，Raster/UI uclamp 为 768/640。
2. Raster 强绑 prime：动画期 Raster 只允许动态识别出的最高 capacity 核。
3. prime 倾向并允许回退：动画期 Raster 保持 `perf`，uclamp 提高到 928；UI/Rust 进入 `mid`。

第二种策略让 Raster 的 CPU7 占比达到 85%–94%，但同时增加 SurfaceFlinger deadline miss。Launcher Raster 与 SurfaceFlinger 都可能在动画末端需要 prime，固定亲和会使二者在同一个 CPU 上排队，因此没有采用。

第三种策略只给调度器表达优先级：Raster 仍可在 CPU2-4,7 迁移。CPU7 空闲时，928 的 uclamp 会使 Raster 更倾向 CPU7；SurfaceFlinger 占用 CPU7 时，Raster 仍可在 CPU2-4 运行。UI/Rust 放到 `mid`，避免 Launcher 自身多个串行阶段同时争 prime。

## A/B 方法

测试使用同一模块守护和同一原生批处理工具，仅切换动画期 profile。每轮按相反顺序执行原策略和候选策略，场景包括快回桌面、慢进最近任务和半程取消。每个窗口记录：

- `simpleperf stat --per-core --per-thread` 的目标线程 task-clock；
- 轻量 SurfaceFlinger FrameTimeline；
- 动画期和动画结束后的实际 affinity/uclamp。

采集不包含全系统 `sched_switch`，测试完成后关闭 stay-on、Perfetto 和 simpleperf。

## 结果

| 场景 | Raster CPU7 占比：基线 | 候选 | Raster task-clock 变化 |
|---|---:|---:|---:|
| 快回桌面 | 18.8% | 34.6% | -4.4% |
| 慢进最近任务 | 6.5% | 49.0% | -13.4% |
| 半程取消 | 13.7% | 57.2% | -7.7% |

两种策略下 Launcher 都没有 Full/Partial jank。候选策略降低了 Raster 的 CPU 时间并提高 CPU7 使用率，但 SystemUI/SurfaceFlinger 的少量离群没有形成确定改善。因此 3.1 的结论限定为改善 Launcher Raster 的放置和完成时间，不将其描述为消除所有动画掉帧。

## 最终运行策略

动画期：

```text
1.raster                perf affinity, uclamp min 928
1.ui                    mid affinity,  uclamp min 768
rt-launcher-mai         mid affinity,  uclamp min 512
IplrVkResMgr            mid affinity,  uclamp min 384
IplrVkFenceWait         little affinity, no boost
```

最后一个动画事件一秒后，批处理工具重新应用基础 affinity，并将目标线程恢复为 `uclamp 0/1024`。不锁 CPU 频率，不修改全局 cpuset，也不常驻采样性能计数器。

Scene 选择“官方调度”后 `scene-daemon` 仍然运行，并可能在稳定应用态把 Launcher 线程恢复为 `ff`。模块不在稳定应用态持续与其竞争；每次 Launcher 动画事件到来时重新应用上述策略。实机在动画中直接读到 Raster `9c/min=928`、UI `1c/min=768`，证明测试窗口内策略没有被 Scene 覆盖。
