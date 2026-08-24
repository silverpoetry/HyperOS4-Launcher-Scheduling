# 来源应用退避：根因、控制链路与验证

## 结论

仅把来源应用写入 `cpuset/background` 和 `cpuctl/background`，不能保证它实际运行在后台核。Sheng 的 Xiaomi `metis` 调度模块会依据 `minor_window_app` 对指定 UID 应用特殊策略；该 UID 命中时，普通 cgroup 和 `sched_setaffinity()` 的表面成功不等于实际限制。

有效顺序是：

1. 读取并保存来源进程每个现有 TID 的原始 CPU affinity 与 nice；
2. 若 `/sys/module/metis/parameters/minor_window_app` 等于来源 UID，按 Joyose 的结束小窗语义写入 `0`；
3. 对全部来源 TID 调用 `sched_setaffinity()`，目标掩码取自设备自己的 `/dev/cpuset/background/cpus`，并按设置提高 nice；
4. 动画期间对新增 TID和 Xiaomi 标记回写做事件驱动补入；
5. 动画完成、取消、服务恢复或卸载时，按 TID 启动时间校验并恢复原始掩码与模块仍持有的 nice。

Sheng 的后台 CPU 集是 `0-2`。模块不把这个编号写死；在其它设备上使用其本机 background cpuset。

## 调度链路

来源应用从全屏进入桌面或最近任务时，系统中同时存在三层控制：

- ActivityManager/OomAdjuster 根据 Activity 可见状态移动 cpuset 和 cpuctl；
- Joyose 在游戏、小窗等场景写入 Xiaomi 调度参数；
- `metis` 和 WALT 在内核调度路径处理 UID、TID 和 affinity。

Joyose 中的小窗命令最终映射到：

```text
/sys/module/metis/parameters/minor_window_app#<应用 UID>
```

结束命令映射到：

```text
/sys/module/metis/parameters/minor_window_app#0
```

实机上金铲铲的 UID 为 `10341`。当节点值为 `10341` 时，RenderThread 和 UnityMain 的 `Cpus_allowed_list` 为 `0-7`。直接执行 `taskset 7 <TID>` 虽返回成功，立即读回仍为 `ff`。先把该节点写为 `0`，同一次 `taskset` 后立即读回 `7`，`Cpus_allowed_list` 变为 `0-2`。

该 affinity 在随后把线程从 `top-app` 移到 `foreground` 后仍保持 `0-2`。因此 ActivityManager 的后续 cgroup 迁移不会撤销已经生效的显式 affinity；旧方案失败的关键是 Xiaomi UID 特权仍在，而不是必须持续抢写 cgroup。

## 原生 affinity 事务

`source-affinityctl` 使用一个短生命周期状态文件记录：

```text
PID、UID、原始 minor_window_app、目标掩码、TID、TID 启动时间、原始 affinity、原始 nice、本轮应用 nice
```

状态文件通过临时文件加原子重命名更新。动画关键路径不调用同步落盘；设备突然重启会重新初始化调度参数，普通进程崩溃时状态文件仍可由服务启动恢复。

初次应用时，控制器枚举 `/proc/<PID>/task`，保存全部原始掩码和 nice，清除与来源 UID 相同的小窗标记，再统一绑定到 background CPU 集。nice 压制目标可设为 0–40 级，默认 40：0 不压制，20 对应 `nice=0`，40 对应 `nice=19`。线程应用值为 `max(原值, 目标 nice)`，因此只降低高于目标的优先级，不改变已经低于目标的线程。线程创建会继承创建者 affinity；若后续事件发现新 TID，则把它加入状态。新线程已经继承后台掩码时，恢复掩码使用设备 `top-app` CPU 集，避免退出动画后永久留在小核。

恢复 nice 时同时核对 TID 启动时间与当前值。只有当前 nice 仍等于状态文件记录的本轮应用值，控制器才恢复原值；系统或应用在动画期间主动改过的值由其继续管理。

重复 Launcher 事件采用快路径：没有新 TID、没有线程逃逸、`minor_window_app` 也未回写时，只验证，不重复保存或绑定。若 Joyose 再次写回相同 UID，则清零该值并只重绑逃逸线程。

## 生命周期

- `gestureStart`、按键最近任务或关闭应用远程动画开始：原生 logd 监听器直接发起 affinity 事务，然后执行兼容性的 background cgroup 放置。
- 桌面和最近任务稳定显示：事务保持有效，来源应用不能占用性能核。
- 上滑取消：先把来源进程恢复到 `top-app`，再恢复原始 affinity 和原始 Xiaomi 标记。
- 从桌面或最近任务打开同一应用：保留同一事务，吸收新增线程和 Joyose 回写；在 Launcher 退出动画完成后恢复。
- 打开不同应用：先恢复旧来源线程但不恢复旧 UID 标记，再为新目标建立事务，避免把已经在后台的游戏重新标为小窗应用。
- 缺少明确完成事件：两秒安全兜底恢复；控制 shell 处于 `foreground`，空闲时阻塞在 logd，不做轮询。
- 服务重启、模块关闭或卸载：存在状态文件时执行恢复。

## 实机验证

Sheng 上的控制器测试结果：

- 金铲铲：160 个现有线程全部由 `0-7` 限制为 `0-2`；500 ms 后仍为 160/160；进入 Launcher 动画后存活的 158 个线程仍全部受限；恢复 158 个，另外 2 个已退出 TID 按启动时间安全跳过。
- Xiaomi 标记回写：写回游戏 UID 后出现逃逸线程；事件驱动 reassert 再次得到全部线程受限，随后原始 affinity 可完整恢复。
- 不同应用事务转移：旧来源先以 `restore_minor=0` 恢复，新目标 79/79 个线程受限，状态头切换为新 PID/UID，最终恢复后 Xiaomi 标记保持系统当前值。
- v4.0 控制器阶段耗时，Settings 74 个线程：初次事务 2.812 ms；无变化重复事件 1.017 ms；仅处理 Xiaomi 标记回写 0.904 ms。
- 原生监听器使用 `posix_spawn()` 启动控制器；71 线程游戏的完整入口事务为 16.877 ms，原 `fork()+exec()` 路径为 29.294 ms。
- 完整 Launcher 退出路径：76/76 个存活线程恢复，状态文件删除，目标回到 `cpuset/top-app` 和 `cpuctl/top-app`，相同 UID 的 `minor_window_app` 恢复。

验收同时检查 `Cpus_allowed_list` 与控制器枚举结果。仅看到 cgroup 路径变化、`taskset` 返回成功或 CPU 时间小幅下降，都不能判定退避生效。

## 策略边界

nice 用于解决来源线程与 system_server、显示提交线程共享后台核心时的运行优先级竞争；affinity 与 cgroup 负责核心隔离。两者在同一个原生事务内保存、应用和恢复。

控制器由转场事件驱动。20 ms、120 ms 或 200 ms 周期性重写 cgroup 会增加唤醒与竞态，不属于当前执行链路。
