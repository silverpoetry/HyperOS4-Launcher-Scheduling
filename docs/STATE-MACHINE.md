# Launcher 生命周期状态机

## 为什么不能只看前台 Activity

从应用上滑小横条时，系统不会立即把 `com.miui.home` 设为 resumed Activity。原应用暂时保留前台身份，Quickstep 已经获得远程动画控制权，Launcher 同时绘制桌面或最近任务内容，SurfaceFlinger 合成两侧图层。

因此需要分别表示“应用的 Activity 身份”和“Launcher 是否正在参与可见转场”。本模块只关心后者。

## 状态

| 状态 | 可见工作 | 策略 |
|---|---|---|
| `app` | 普通应用稳定前台，Launcher 不再参与转场 | 解除 |
| `entering` | Launcher 已接管应用到桌面/最近任务的转场 | 生效 |
| `home` | 桌面主屏稳定显示 | 生效 |
| `recents` | 最近任务稳定显示 | 生效 |
| `leaving` | Launcher 正在执行打开应用的动画 | 生效 |

## 事件映射

| 事件 | 转换 | 含义 |
|---|---|---|
| `gestureStart` | `app → entering` | 全屏手势移动越过 Launcher 接管阈值；不是触摸按下，也不是视觉 blur 出现 |
| `onOverviewToggle` | `app → entering` | 按键最近任务的早期入口 |
| `IRecentsAnimationRunnerImplForRemoteBack ... CloseApp` | `app → entering` | Quickstep/远程动画接管应用关闭转场 |
| `gestureToHome` | `entering → home` | 全屏手势提交到桌面 |
| `ActivityObserverLauncher activityResumed pkg=com.miui.home` | `entering → home` | Launcher Activity 正式恢复；晚于转场接管 |
| `enterOverviewState` | `home/entering → recents` | 最近任务场景稳定 |
| `gestureToApp` 且 `gesture.active` 存在 | `entering/home → app` | 本轮上滑取消，恢复原应用进入前的 cgroup |
| `exitOverviewState` | `recents → leaving` | 从最近任务打开应用 |
| `openingRemoteAnimationOpen` | `home/recents → leaving` | Launcher 开始打开目标应用 |
| 非 Launcher 的 `ActivityObserverLauncher activityResumed` | 活跃状态保持 `leaving` | 目标应用已恢复，但 Launcher 仍可能在画最后几帧 |
| `openingRemoteAnimationClose` | `leaving → app` | Launcher 退出动画完成 |
| RemoteBack `on_animation_canceled` | `entering → app` | RemoteBack 路径取消，恢复原应用进入前的 cgroup |

Sheng v2.8 实机样本中，快滑从 `gestureStart` 到 Launcher resumed 约 0.36 秒；慢滑从 `gestureStart` 经 Launcher resumed 到 `enterOverviewState` 约 0.84 秒。策略在第一个事件到达时生效，而不是等卡片完成。

Android `logcat` 的文本输出接入非终端 shell 管道时会出现约 0.4 秒块缓冲。模块使用单个 arm64 `launcher-logwatch`，通过系统 `liblog` 直接读取 logd main buffer，只保留状态机需要的 Launcher 消息，并用 `write()` 逐条输出。它不注入 Launcher，不修改日志级别，也不采集高频渲染日志。

`PassBlurWindow`、blur 半径和玻璃材质不属于状态输入。它们是视觉实现细节，既可能晚于转场开始，也可能在关闭卡片等其它动画中出现。

## 源应用与目标应用

状态机维护两个独立记录：

```text
source-app          进入 Launcher 前的应用
pending-source-app  离开 Launcher 时刚恢复的目标应用
```

进入时只降低 `source-app`。目标应用恢复时先写入 pending，不能立即覆盖 source，否则退出动画期间的重复策略应用会错误降低正在打开的目标应用。只有进入 `app` 后，pending 才提交为下一轮 source。

pending PID 属于保护集合。目标收到 resumed 事件后明确回到 `top-app`，即使它与 source 是同一进程也不能继续沿用退避状态。不能直接恢复手势开始时捕获的 cgroup，因为事件到达模块时 ActivityManager 可能已经把源应用临时降到 `foreground`；稳定 resumed Activity 的语义目标是 `top-app`。

延迟重写持有本轮 source 快照和 PID，不在执行时重新解析可能已提交为新目标的 `source-app`。写入后再次检查 pending 和稳定状态；若 PID 已成为 resumed 目标，立即回滚到 `top-app`。进入 `app` 的最后一步再次落实当前 source 的 `top-app` 状态。

## 手势会话

`gesture.active` 只在 `gestureStart` 时创建，在 `gestureToHome`、`enterOverviewState` 或取消完成时删除。`gestureToApp` 只有在该文件存在时才表示“从应用上滑后取消”。从稳定最近任务点击当前应用卡片也会出现同名信号，但此时没有活动手势，不能按取消处理。

## 异步任务约束

`policy.epoch` 在策略启用、解除或目标应用 resumed 时变化。120/320 ms 的源应用重新写入必须匹配相同 epoch 和相同 source 内容，并固定使用创建任务时记录的 PID。

取消路径先递增 epoch，再恢复 source。这样已经睡眠结束、但尚未执行写入的旧任务会先失效，不会在恢复之后把前台应用再次送回 background。

`transition.serial` 在每个状态事件上递增。两秒退出兜底必须匹配相同 serial 且状态仍为 `leaving`。

这两个编号用途不同：epoch 保护一个完整 Launcher 活跃周期内的调度操作，serial 使旧的退出兜底不能跨越新事件。

## 不变量

1. `app` 状态下壁纸和 MIMD 必须处于记录的原始 cgroup。
2. 稳定 `app` 状态下当前 resumed source 必须处于 `cpuset/top-app` 和 `cpuctl/top-app`。
3. 目标应用不能在 Launcher 退出动画中成为 `source-app`。
4. Launcher、SystemUI、输入法和显示链进程不能成为退避对象。
5. 视觉 blur 变化不能触发或结束 CPU 策略。
6. 模块重启和卸载必须恢复壁纸及 MIMD，并终止旧监听器。
7. `gestureToApp` 不能脱离当前手势会话单独触发取消。
8. 延迟 source 写入后必须复核目标保护条件，不能只依赖写入前检查。
