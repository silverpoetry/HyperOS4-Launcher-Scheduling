# 来源应用退避的控制链路

## 问题

从应用进入桌面或最近任务时，来源应用仍会继续产帧、提交 Buffer、处理音视频或游戏逻辑。Launcher、SystemUI、system_server 与来源应用在同一段转场中同时需要 CPU。高负载来源应用如果继续占用性能核，会延长 Launcher 动画回调、WMShell 转场和 system_server Binder 回复的 runnable 等待。

一次性把来源 PID 写进系统 `background` cgroup 不能覆盖完整转场。ActivityManager 会继续依据 Activity、窗口和进程状态应用 task profile，把进程迁回 `top-app`。实机记录中，首次退避已经生效，后续系统迁移仍能让来源重新获得性能核；晚到的 `activityResumed` 日志只能在问题发生后才看到这一变化。

Xiaomi 的 `minor_window_app` 还会为指定 UID 应用附加调度策略。来源 UID 命中该节点时，需要在退避期间清除该标记，并在事务结束时恢复。

## 专用控制组

模块建立两个同名的运行时控制组：

```text
/dev/cpuset/hyperos4-source
/dev/cpuctl/hyperos4-source
```

cpuset 的 CPU 列表来自本机配置：使用 Android 的 `background` CPU 集，或使用模块按 `cpu_capacity` 推导出的效率核集合。没有设备固定 CPU 编号。

cpuset 是来源进程的硬 CPU 边界。向 `cgroup.procs` 写一次 PID 会迁移整个线程组；转场期间创建的新线程继承该组，不需要逐线程设置 affinity。cpuctl 的 `cpu.shares` 根据来源压制等级配置，用于来源和同组系统任务共享 CPU 时的进程级退让。

来源压制等级同时映射为 nice 目标。守卫只降低优先级高于目标的线程：

```text
applied_nice = max(original_nice, configured_target)
```

默认等级 40 对应 `nice=19`。nice 处理运行在常驻守卫内，不创建逐事件控制进程。

## 常驻守卫

`source-guard` 是来源事务的唯一所有者。它只在内存中保存：

```text
PID、UID、进程 starttime、原始 minor_window_app、TID、原始 nice、应用 nice
```

PID、UID 和 `/proc/<pid>/stat` 的 starttime 必须同时匹配，才能应用或恢复事务。这样即使 PID 被系统复用，也不会把旧来源状态写到新进程。

稳定应用阶段发送 `arm PID UID`。守卫在动画前完成进程身份验证和 nice 快照。状态不写入 `/data` 或临时事务文件；`source-guard.status` 只提供只读观测，不参与恢复。

真实动画入口由 `launcher-logwatch` 处理，顺序固定为：

1. 把来源 PID 写入专用 cpuset；
2. 把来源 PID 写入专用 cpuctl；
3. 通过 Unix datagram 发送 `activate PID UID`；
4. 再把生命周期事件交给 shell 状态机。

前两次 PID 写入已经形成硬边界。守卫收到激活命令后启用内核事件、清除匹配来源 UID 的 Xiaomi 标记，并应用内存中的 nice 快照。命令使用常驻 Unix datagram socket，不执行新的二进制或 shell 控制器。

## 系统覆盖的纠正

守卫为每个在线 CPU 打开 `cgroup_attach_task` tracepoint。只有来源事务处于 active 状态时才启用 perf event；稳定应用、桌面空闲和模块停用阶段全部关闭。3.3 实机空闲 10 秒的守卫 CPU tick 增量为 0。

ActivityManager 把来源任务迁出专用组时，内核事件包含被迁移 TID。守卫只比较当前来源 PID 和已缓存 TID；命中后读取一次来源主进程的 cgroup。如果 cpuset 或 cpuctl 已离开专用组，就重新写入一次来源 PID。写回迁移也会产生事件，但下一次检查已经满足目标组，因此不会循环。

cgroup 覆盖不会改变 nice，所以纠正路径只重写两个进程控制组，不重新枚举线程，也不重复执行逐线程 nice。Settings 的真实 83 线程样本中，系统覆盖后的整进程纠正耗时 663 us。

## 恢复

转场取消、动画完成、模块停用、服务退出或卸载时，守卫先关闭 tracepoint，再恢复状态：

- 返回前台的目标写回 `cpuset/top-app` 与 `cpuctl/top-app`；
- 已经转为后台的旧来源写入系统 `background` 组；
- 仅当进程 PID、UID 与 starttime 仍匹配时恢复；
- 仅当线程当前 nice 仍等于模块应用值时恢复原始 nice；
- 恢复或清理匹配来源 UID 的 `minor_window_app`。

当前应用恢复稳定后重新 arm，为下一次转场准备。打开不同应用时，旧事务先释放到系统 background，新目标成为守卫唯一所有者。

同一目标在 `leaving` 阶段可能重复发送 `activityResumed`。pending 记录的完整包名相同且其 PID 仍存活时，状态机把该事件视为重复；它不延长完成超时，也不重新激活事务。明确动画完成事件优先结束事务；缺失完成事件时，由一次可配置的应用转场完成超时收口。

## 实机验证

257 线程合成进程验证了以下不变量：

- 激活后 cpuset 与 cpuctl 同时位于 `/hyperos4-source`；
- 人工写回两个 `top-app` 组后，内核事件触发整进程纠正；
- 恢复后两个控制器都回到 `/top-app`；
- arm、active 与恢复状态只存在于守卫内存。

该样本的 arm 为 1.701 ms，activate 为 5.684 ms。arm 位于动画前；动画入口的硬 CPU 边界由监听器直接完成，不等待 257 个线程的 nice 处理。真实 Settings 样本的 83 线程 activate 为 1.678 ms，系统覆盖纠正为 663 us。

验收必须同时检查实际 cgroup、守卫状态和事件时间。只看到一次写入成功、命令返回 0 或短时 CPU 使用下降，都不能证明整个转场期间持续受控。
