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
| `gestureToApp` 且 `gesture.active` 存在 | `entering/home → app` | 本轮上滑取消，恢复来源应用的 affinity 事务与 cgroup |
| `exitOverviewState` | `recents → leaving` | 从最近任务打开应用 |
| `openingRemoteAnimationOpen` | `home/recents → leaving` | Launcher 开始打开目标应用 |
| 非 Launcher 的 `ActivityObserverLauncher activityResumed` | 活跃状态保持 `leaving` | 缓存目标并继续退避；Launcher 仍在绘制卡片展开动画 |
| `openingRemoteAnimationClose` | `leaving → app` | Launcher 退出动画完成，此时才恢复目标到 `top-app` |
| RemoteBack `on_animation_canceled` | `entering → app` | RemoteBack 路径取消，恢复来源应用的 affinity 事务与 cgroup |

Sheng v2.8 实机样本中，快滑从 `gestureStart` 到 Launcher resumed 约 0.36 秒；慢滑从 `gestureStart` 经 Launcher resumed 到 `enterOverviewState` 约 0.84 秒。`gestureStart` 到达后第一项调度动作就是退避缓存的 source；不会先等待进程刷新或 Launcher 线程处理，也不会把原始三指接触当作入口。

Android `logcat` 的文本输出接入非终端 shell 管道时会出现约 0.4 秒块缓冲。模块使用单个 arm64 `launcher-logwatch`，通过系统 `liblog` 直接读取 logd main buffer，只保留状态机需要的 Launcher 消息，并用 `write()` 逐条输出。它不注入 Launcher，不修改日志级别，也不采集高频渲染日志。

入口退避不再等待这条消息进入 shell。`launcher-logwatch` 在识别入口事件后，先调用 `source-affinityctl` 建立逐线程 affinity 事务，再把已缓存 source PID 写入 background cpuset 和 cpuctl，最后把事件交给 shell 完成状态处理。监听器空闲时阻塞在 logd，不轮询触控或 SurfaceFlinger。此路径消除了 shell 查询和调度造成的数百毫秒延迟，但 logd 仍是异步通道；它只能做到实测低延迟，不能承诺严格的单帧上界。

`PassBlurWindow`、blur 半径和玻璃材质不属于状态输入。它们是视觉实现细节，既可能晚于转场开始，也可能在关闭卡片等其它动画中出现。

## 源应用与目标应用

状态机维护两个独立记录：

```text
source-app          进入 Launcher 前的应用
pending-source-app  离开 Launcher 时刚恢复的目标应用
```

进入时只降低 `source-app`。目标应用恢复时先写入 pending，不能立即覆盖 source，也不能立即恢复性能组：此时 Launcher 仍在把最近任务卡片展开为全屏，提前恢复目标会与 Launcher 争用动画资源。只有进入 `app` 后，pending 才恢复到 `top-app` 并提交为下一轮 source。

pending PID 属于来源退避的保护集合。`activityResumed` 处理会把 affinity 事务转移到目标 PID，并明确将其保持在 background。正常路径由 `openingRemoteAnimationClose` 解除；若完成事件缺失，两秒兜底负责恢复。稳定完成态的语义目标始终是 `top-app`。

同一 PID 的重复事件只检查 Xiaomi UID 标记、新 TID 和实际 affinity；没有变化时不重建事务。若 resumed 目标不同，控制器先精确恢复旧来源，再为新目标建立事务。进入 `app` 的最后一步恢复当前事务，并落实目标的 `top-app` 状态。

## 手势会话

`gesture.active` 只在 `gestureStart` 时创建，在 `gestureToHome`、`enterOverviewState` 或取消完成时删除。`gestureToApp` 只有在该文件存在时才表示“从应用上滑后取消”。从稳定最近任务点击当前应用卡片也会出现同名信号，但此时没有活动手势，不能按取消处理。

## 异步任务约束

来源应用不再依靠 120/320 ms 延时任务反复写 cgroup。`source-affinityctl` 保存 PID、UID、TID 启动时间和每个线程的原始 affinity；重复事件只做事件驱动复核。ActivityManager 后续改变 cgroup 不会解除已经生效的显式 affinity。

`transition.serial` 在每个状态事件上递增。两秒退出兜底必须匹配相同 serial 且状态仍为 `leaving`，旧兜底不能跨越新事件。事务恢复同时核对 TID 启动时间，已经退出或被复用的 TID 不会被误改。

## 不变量

1. `app` 状态下不能残留来源应用 affinity 事务；壁纸和 MIMD 必须处于记录的原始 cgroup。
2. 稳定 `app` 状态下当前 resumed source 必须恢复原始 affinity，并处于 `cpuset/top-app` 和 `cpuctl/top-app`。
3. 目标应用不能在 Launcher 退出动画中成为 `source-app`，也不能在动画完成前被模块恢复到 `top-app`。
4. Launcher、SystemUI、输入法和显示链进程不能成为退避对象。
5. 视觉 blur 变化不能触发或结束 CPU 策略。
6. 模块重启和卸载必须恢复壁纸及 MIMD，并终止旧监听器。
7. `gestureToApp` 不能脱离当前手势会话单独触发取消。
8. 不同目标之间转移事务时，旧来源必须先恢复；同一 PID 的重复事件不能破坏最初保存的恢复信息。
