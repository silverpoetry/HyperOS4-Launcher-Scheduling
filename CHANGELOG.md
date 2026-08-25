# Changelog

## 7.2

- Reconcile source placement at thread granularity when Android or a vendor task profile moves an individual worker out of the source cgroup.
- Index cached source TIDs in memory and validate previously unseen TIDs against the open source task directory without rescanning the process.
- Reapply the configured nice target to a displaced or newly observed source thread in the same native correction.
- Ignore the guard's own cgroup attach events by reading the tracepoint destination path, preventing self-generated correction loops.
- Remove status-file and stdout writes from the kernel-event hot path; live corrections only update an in-memory counter.

## 7.1.1

- Locate the log listener through `pidof` plus verified parent PID, without depending on the optional procfs children node or the truncated task name.
- Treat the listener shutdown used by an in-place reload as a successful monitor cycle.
- Serialize consecutive saves and confirm that each configuration refresh reaches a newly started listener.
- Report validation and runtime reload failures separately in the WebUI.

## 7.1

- Allow source-app placement to use the complete topology-derived CPU vocabulary.
- Add an efficiency-core placement that leaves one dynamically selected efficiency CPU available to system background work.
- Report the reserved-efficiency mask in the WebUI without changing existing user placement settings during upgrade.

## 7.0

- Replaced the per-event source affinity helper with one resident in-memory source guard.
- Added dedicated source cpuset and cpu-controller groups; one `cgroup.procs` write now constrains the whole process and future threads.
- Subscribed directly to the kernel `cgroup_attach_task` tracepoint and immediately reverses ActivityManager task-profile overwrites.
- Moved source nice snapshots into the resident controller and removed all SAF state formats, disk parsing and compatibility paths.
- Added process-level CPU shares while retaining reversible per-thread nice suppression.
- Enable cgroup trace events only while a source transaction is active and validate PID, UID and process start time before every restore.
- Treat repeated resumed events for the same pending target as idempotent so they cannot extend the application-transition completion timeout.

## 6.1

- Store transient source-affinity transaction state on `/dev` tmpfs instead of persistent module storage.
- Include original and applied nice values in prepared source state, and apply both affinity and nice in the first-frame native transaction.
- Reassert the active source transaction when Launcher resumes and when Recents becomes active, covering Android task-profile rewrites during long transitions.

## 5.8

- Add a configurable source-app nice target level of 0–40, defaulting to 40. The level maps from no suppression to `nice=19`; each thread moves directly to the target only when needed, and its original value is restored only while the module still owns the applied value.
- Move Launcher uclamp changes and SystemUI transition placement onto validated cached thread identities. Full thread enumeration is deferred outside the first animation frames and retained only as a cache-miss fallback.
- Reload settings through the existing PID 1-owned daemon. WebUI no longer starts a descendant service process that Android can classify and terminate as a phantom process.
- Upgrade source transaction state to `SAF2` while retaining safe recovery of active `SAF1` transactions.

## 5.7

- Publish a source-yield activity record from the same locked native transaction that saves affinity, moves cgroups and binds source threads.
- Treat one Launcher entry as one process-policy transaction. Later `home`, `recents` and `leaving` phases keep the existing transaction instead of rescanning every source thread.
- Extend an active SystemUI policy timeout without repeatedly enumerating and rewriting the same SystemUI threads.
- Replace the quadratic saved-thread lookup used by source reassertion with an indexed lookup.

## 5.6

- Preserve the full Android package name in source records instead of the 15-byte `/proc/Name` value.
- Observe matching `ActivityManager: Start proc` events from logd's system buffer while a source-yield transaction is active. A restarted source process is now captured and moved with one native `replace-yield` transaction before `activityResumed`.
- Match the exact main-process package and Android UID reported by system_server before replacement; `activityResumed` remains the fallback and new-thread reassert path.
- Add a source-app placement setting that distinguishes the capacity-derived efficiency cores from Android's system background cpuset.
- Use one seven-item placement vocabulary for topology reporting, Launcher threads and SystemUI threads, including the system background set.
- Redesign the WebUI around operational data, move module metadata to About, and report every CPU frequency policy with its current and configured range.

## 5.5

- 新安装默认将 Launcher Raster 放置到动态 prime 集合，SystemUI 主线程、RenderThread、WMShell 与 GPU completion 放置到非 prime 性能集合。升级保留已有用户配置。
- 修正 5.4 并发验收发现的锁创建窗口：竞争者看到刚建立但尚未写入 owner 的重载锁时先等待，再决定是否回收，避免两个重载同时进入临界区。
- 重载查找当前服务时同时读取 `daemon.pid` 与单实例锁 owner。即使一次竞争已删除 PID 文件，也能识别、停止并替换真实在线实例，不再留下“进程运行但 WebUI 离线”的状态。
- WebUI 重载控制进程和新守护进程在进入锁、清理及就绪等待前即迁入 foreground cpuset/cpuctl，避免设备重载时 100 ms 的等待被后台调度拖成长达数秒。
- 守护进程取得单实例锁并完成遗留进程清理后立即发布 PID；状态页也会以单实例锁 owner 作为后备。并发重载等待到已有重载成功后会直接合并，不再反复停止刚启动的服务。

## 5.4

- 为 WebUI、模块操作按钮触发的服务重载增加跨进程互斥；并发保存会串行完成，不再同时清理彼此刚启动的守护进程。
- 守护进程使用持久单实例锁记录所有者 PID。新实例只清理旧版遗留进程；已有有效实例时重复启动直接退出，异常退出留下的锁会在下次启动时安全回收。
- 停止旧服务前同时核对 PID 和 `/proc/PID/cmdline`，避免陈旧 PID 文件在号码复用后误杀无关进程。
- 重载会先删除陈旧 PID，启动后等待并验证新 PID 确实对应本模块 `service.sh`；启动失败会反馈给 WebUI，不再先返回成功再显示离线。

## 5.3

- 将来源应用退避收敛为单个加锁的原生事务：先在 `top-app` 中保存逐 TID 原始亲和，再迁入 background cpuset/cpuctl，最后绑定 background CPU。返回时先恢复 `top-app` 控制组，再按 TID 启动时间恢复保存值。
- 增加 SystemUI 转场线程管理。主线程、RenderThread、WMShell 与 GPU completion 使用可迁移的渲染集合；HeapTaskDaemon、Finalizer、ReferenceQueue 和 JIT 默认进入不含渲染集合的次级性能核，结束或超时后精确恢复原亲和。
- CPU 拓扑增加 `render` 与 `secondary` 集合。`render` 由 prime 和最快非 prime 容量簇组成，`secondary` 使用其余性能核；集合完全按运行时 cpuset 与 `cpu_capacity` 推导。
- Launcher Raster 不再强制独占 prime。Raster、UI/Rust、ResMgr、FenceWait 以及两类 SystemUI 线程的核心集合均可在 WebUI 独立配置。
- SystemUI 管理只在 Launcher 转场中生效，稳定应用态立即恢复；桌面/最近任务缺少明确结束边时使用可配置超时兜底。诊断页同时显示 Launcher 与 SystemUI 受管线程。

## 5.2

- 修正原生快速退避的快照顺序：在来源应用仍属于 `top-app` 时保存真实逐线程 affinity，再由同一个原生事务写入 background cpuset/cpuctl，避免把临时 CPU0–2 错记成恢复基准。
- 为 affinity 状态文件增加进程间排他锁，序列化原生监听器与 shell 状态机的 apply、replace 和 restore 操作。
- 晚到的 Launcher exit-start 事件仅在已经有 pending 目标时重新安排完成兜底，避免它使先前 app-resumed 的恢复计时失效，同时不把点空白或返回桌面误判为应用恢复。
- 修正全新安装的配置迁移返回值。没有旧配置时迁移现在正常成功，随后创建持久默认配置，服务与 KernelSU WebUI 可以完成首次启动。
- 监听 `finish_remote_transition to_home = false` 完成边；从最近任务返回同一应用且不再发送 `activityResumed` 时，也会恢复来源应用的控制组和逐线程亲和。

## 5.1

- 动态推导独立 prime CPU mask。Launcher Raster 固定使用 prime，UI/Rust 按现有放置策略使用去掉 prime 的性能核；亲和覆盖完整运行期，短时计时器只控制 uclamp。
- 原生转场监听器先写来源应用的 background cpuset/cpuctl，再执行逐线程亲和事务，缩短首批动画帧前的应用退避路径。
- 事件日志增加 cgroup 写入完成的单调时钟时间戳，分别记录快速退避与完整逐线程事务的完成时刻。

## Project layout - 2026-08-22

- 构建成品统一写入父级 `..\output`，仓库内不维护重复的 `dist` 副本。
- 原 Shennong 专用 ADB 5555 支持项目已拆分为独立的通用模块项目。

2.1–2.7 是同日实机收敛候选；2.8 完成 Launcher 生命周期验证；3.0 恢复并通用化逐线程调度。

## 5.0

- 将 762 行 `service.sh` 拆分为配置、运行时、CPU 拓扑、Launcher 线程、来源应用、频率事务、状态机和事件处理层；入口脚本只负责装配与守护生命周期。
- 删除旧 `thread-policy.sh`、单文件 `webroot/app.js`、单文件 `webroot/styles.css` 和已经没有写入方的 `active-source-groups` 恢复分支。
- 原生监听器已完成 affinity 与两个 background cgroup 写入时，shell 不再重复执行来源应用事务；部分失败仍走修复路径。
- WebUI 采用分层 ES Modules 与拆分 CSS，恢复 Material 3 标题卡片、状态卡片、规范底栏、动态配色、深色模式、左右滑动和脏表单操作栏。
- 配置接口由 15 个位置参数改为受限的命名 `key=value` 协议；前后端均校验允许键、枚举和范围，写入使用同目录原子替换。
- 持久配置迁移到独立数据目录，与 KernelSU 更新时替换的程序目录分离；5.0 首次启动自动迁移已知旧配置，卸载时明确清除。
- 增加 Android `sh` 语法、遗留文件、依赖解析、文件职责上限、CPU mask 及配置边界检查；本轮同时完成桌面与手机宽度的 WebUI 渲染、交互、表单保存和控制台错误验证。

## 4.2

- 将转场小核限频改为默认关闭，WebUI 仍保留开关、比例与超时参数，供高负载或功耗实验手动使用。
- 可选限频比例改为相对硬件上限计算；当前上限已低于目标时不再继续下压，避免重复生命周期事件或第三方调度造成比例叠乘。
- Settings 轻载场景完成两组交叉 A/B。限频开启后，Launcher Full jank 合计从 4 增至 8，SurfaceFlinger Full jank 从 11 增至 24，Launcher 最大帧均值从 26.08 ms 增至 37.46 ms。
- 保留 4.1 验证有效的 FenceWait 中核放置。轻载掉帧来自来源应用收尾与 Buffer 交接被限频拖慢，而不是 Launcher 主线程误入小核。

## 4.1

- 增加转场期小核簇频率上限。目标 cpufreq policy 由设备 `cpu_capacity` 和 cpuset 动态推导，默认限制到原上限的 78%，结束事件或 1500 ms 安全超时后恢复。
- 频率恢复采用所有权检查：仅在当前值仍等于模块写入值时恢复原值，不覆盖其它调度器的后续修改；服务重启、模块停用和卸载同样执行恢复。
- WebUI 精简为状态、设置和日志三页，移除宣传文案、装饰性说明框和关于页。
- 来源应用、壁纸/MIMD、Launcher 线程、小核限频均可独立开关；限频比例、超时、线程放置、提升持续时间、四类 uclamp 和应用返回兜底时间均可配置。
- `launcher-threadctl` 改为显式接收放置策略和各线程的 uclamp 参数，不再依赖编译期固定档位。
- `IplrVkFenceWait` 默认从小核移到动态 `mid` 集合，并提供独立放置参数。Sheng 在小核固定 307200 kHz 的五轮 A/B 中，FenceWait 运行时间下降 83.0%，Launcher Full jank 从 30 降到 14。
- 模块作者标记更新为 `github: silverpoetry`。

## 4.0

- Remove the redundant second `/proc/TID/stat` pass immediately before binding. On-device controller timing for 74 Settings threads is now 2.8 ms for the initial transaction, about 1.0 ms for an unchanged duplicate event, and 0.9 ms when clearing a rewritten Xiaomi marker with no escaped thread.
- Add stage-level timing to the native controller so collection, atomic state save, binding, and total cost remain auditable.
- Launch the controller with Android `posix_spawn()` instead of `fork()` plus `exec()`. The complete native event-edge transaction measured 16.877 ms on Sheng with a 71-thread game source, down from 29.294 ms, before the event is handed to the shell state machine.

## 3.9 (superseded test build)

- Make `replace` idempotent for repeated `activityResumed` notifications from the same PID/UID; it now uses the fast reassert path instead of restoring and recreating the transaction.

## 3.8 (superseded test build)

- Remove synchronous `fsync` from the transition edge while retaining atomic state-file replacement; this reduces the affinity transaction from tens of milliseconds under contention to the millisecond range.
- Make duplicate transition events a verification-only fast path unless a new TID, escaped mask, or Xiaomi minor-window rewrite is detected.
- Transfer the active transaction from the previous source to a different resumed target during Launcher exit, and restore the old `minor_window_app` value only when that same UID actually resumes.

## 3.7 (superseded test build)

- Reassert the active affinity transaction when Joyose writes the source UID back to `minor_window_app` during app resume, and include newly created TIDs in the saved restore set.
- Keep the event-driven shell controller in `foreground` while it blocks on logd so a high-load app cannot stretch the two-second exit fallback into tens of seconds.
- Remove the obsolete 120/200 ms cgroup reassert workers; affinity now survives ActivityManager cgroup movement directly.

## 3.6 (superseded test build)

- Replace the ineffective source-app cgroup-only assumption with a verified per-thread affinity transaction.
- Temporarily clear `metis/parameters/minor_window_app` only when it matches the captured source UID; this removes the Xiaomi kernel override that silently expanded affinity back to all CPUs.
- Save each existing source TID's original affinity, constrain all of them to the device-defined background CPU mask, and restore exact masks on completion, cancellation, daemon recovery, disable, or uninstall.
- Run the affinity transaction directly from the native Launcher event listener before the legacy cgroup placement, while keeping CPU masks topology-derived.

## 3.5

- 将入口退避的关键路径下沉到原生 `launcher-logwatch`：读取到 `gestureStart`、按键最近任务或 RemoteBack 关闭应用信号后，直接读取缓存 source PID 并写入 cpuset/cpuctl，不再等待 shell 管道和状态机。
- 原生监听器预先打开 background cgroup 节点，空闲时阻塞在 logd；使用 foreground 调度避免被后台负载长期饿死，但不进入 `top-app`，也不轮询输入或窗口。
- shell 中的同一退避操作保留为失败兜底，并继续承担生命周期记账、Launcher 线程策略、取消恢复和退出动画完成恢复。
- Sheng Moonlight 三轮初测中，logd 事件传递加两次 cgroup 写入为约 4.44–8.37ms；后续压力样本显示 logd 本身仍有离群延迟，因此日志触发不能形式化保证每次小于一个 120Hz 帧周期。

## 3.4

- `gestureStart` 表示 Launcher 已接管窗口、前台应用开始卡片化。收到该事件后先退避已缓存的源应用，再执行状态记账、Launcher 线程提升和壁纸/MiMD 查询，移除首批动画帧前的策略空窗。
- 非 Launcher 应用提前发出 `activityResumed` 时，只缓存并继续退避目标；不再在卡片展开动画仍运行时显式恢复 `top-app`。
- 目标只在 `openingRemoteAnimationClose` 确认 Launcher 退出动画结束后恢复；缺少完成事件时仍由两秒超时兜底恢复。
- 不监听原始多点触控。应用内三指操作不会触发策略；入口仍以 Launcher 窗口转场信号为准。

## 3.3

- 增加 KernelSU WebUI，采用 Material 3 动态色、底部导航和四页横向滑动结构。
- 状态页显示生命周期、守护进程、source 应用、设备信息和动态推导的 CPU 集合；策略页可切换应用退避、逐线程策略和提升档位。
- 诊断页按需读取关键线程、cgroup、SELinux 与最近事件，不启动常驻性能监测。
- WebUI 后端只接受固定动作和枚举参数，不把页面输入拼接为任意 Shell 命令。
- 增加服务重载、日志清理与诊断信息复制功能；原有调度状态机和线程策略不变。

## 3.2

- 修复快速连续手势后源应用可能永久留在 `background`（Sheng 为 CPU `0-2`）或 `foreground`（CPU `0-6`）的问题。
- resumed 应用按 Android 前台语义恢复到 `top-app`，不再把手势开始后捕获的临时 `foreground` 组误作稳定恢复目标。
- `activityResumed` 在恢复目标前使旧 policy epoch 失效，延迟重写固定使用本轮 source PID，不会在醒来后误读已经提交的新 source。
- 延迟重写增加写后竞态复核；稳定 `app` 提交最后再次落实 `top-app` 不变量，覆盖已经通过旧检查才被抢占的工作线程。
- Sheng 文件管理复现中，修复前稳定 `app` 的 100/100 个采样均为 `background`/CPU `0-2`；修复后完成八轮快速返回、取消和重新打开，所有完成态均为 `top-app`/CPU `0-7`。

## 3.1

- 确认 Shennong 官方调度下，3.0 的 `perf=9c` 虽包含 CPU7，但 768/640 的 uclamp 已可由 CPU2-4 满足；三轮基线中 Raster 在 CPU7 的占比仅约 6.5%–16.2%。
- 动画期将 UI 和 Rust 线程放入动态推导的 `mid` 集合，Raster 保持可在 `perf` 集合迁移。Raster uclamp 调整为 928，UI 调整为 768，使 Raster 倾向 prime，同时在 SurfaceFlinger 占用 prime 时仍可退回其它性能核心。
- 动画结束不再只清除 uclamp；批处理工具同时恢复 3.0 的基础亲和，避免动画期线程分流残留。
- 拒绝采用 Raster 强绑 prime 的候选。它可将 Raster 的 CPU7 占比提高到 85%–94%，但实测会增加 SurfaceFlinger deadline miss。
- 交替 A/B 中，平衡策略将 Raster task-clock 在快回桌面、慢进最近任务和半程取消中分别降低约 4.4%、13.4% 和 7.7%；Launcher 没有 Full/Partial jank。SystemUI/SurfaceFlinger 的零星离群未显示确定改善，因此不宣称本版本消除所有系统合成掉帧。
- 在 Sheng 上以后台腾讯会议约 55% 单核持续负载完成相同交替 A/B。Raster task-clock 分别降低约 14.2%、21.5% 和 16.0%，Launcher p95 在快回桌面基本持平，在慢进最近任务和半程取消分别降低约 10.8% 和 26.4%。

## 3.0

- 恢复 Launcher 逐线程亲和：`1.ui`、`1.raster` 和 Rust 主线程使用性能集合，Impeller 资源管理线程使用去掉 prime 的性能集合，fence 等待线程保留在最低容量簇。
- 不再写死 Sheng 的 `f8/78/07`。运行时根据设备 `top-app/background` cpuset 和 `cpu_capacity` 推导，Shennong 实测为 `9c/1c/03`。
- 恢复 1 秒的逐线程 uclamp：raster 768、UI 640、Rust 512、ResMgr 384；稳定状态回到 0/1024。
- 用单个原生 `launcher-threadctl` 扫描 TID 并直接调用 affinity/uclamp syscall，替代每轮约二十个 `taskset/uclampset` 子进程。Shennong 实测整批 apply/reset 各约 10 ms。
- 拓扑在 cpuset 内容变化时重新推导，避免开机初期 cpuset 尚未初始化而错误退化为全核。
- 已知线程按原始快照恢复；快照后新生的同类线程按设备 `all/little` 语义恢复，解决线程继承亲和后无法完全禁用的问题。
- 在 Shennong 上对快滑、慢滑、半程取消、桌面打开应用和最近任务打开应用完成隔离 A/B。逐线程核心放置有效，FrameTimeline 改善具有场景性，不宣称消除所有 jank。

## 2.8

- 增加显式 `gesture.active` 生命周期。只有本轮收到 `gestureStart` 且尚未提交到 home/recents 时，`gestureToApp` 才按取消处理。
- 从稳定最近任务点击当前应用卡片时，同名 `gestureToApp` 不再短暂切到 app；策略保持到真正的 Launcher 退出完成。

## 2.7

- pending 目标与 source 使用同一 PID 时，按进入 Launcher 前记录的 cgroup 主动恢复目标；不能依赖 ActivityManager 在 resumed 后重复写一次它认为已经正确的 top-app 状态。
- 取消手势先递增 policy epoch，再恢复 source，关闭已通过旧 epoch 检查的异步重写与取消恢复之间的竞态窗口。

## 2.6

- 将 pending 目标 PID 加入保护集合。用户从桌面或最近任务重新打开与旧 source 相同的应用时，目标 resumed 后不会因 PID 相同而继续被当作上一前台应用退避。

## 2.5

- 用单个 arm64 `launcher-logwatch` 通过 Android `liblog` 直接读取 logd main buffer，并用 `write()` 逐条输出经过严格筛选的 Launcher 生命周期事件。
- 应用恢复事件改从 Launcher 的 `ActivityObserverLauncher activityResumed pkg=` 获取，再按包名解析 PID；不再解析 logcat 格式中的 PID。
- 实机连续监听完整捕获 `gestureStart → Launcher resumed → gestureToHome`，避免文本 logcat 的约 0.4 秒块缓冲和单事件重启缺口。

## 2.4

- 保留单个连续 logcat 监听器，并用随模块构建的 arm64 `liblinebuf.so` 将 stdout 设为逐行缓冲。
- 实机对照确认普通长驻管道约延迟 0.4 秒；逐行缓冲在事件产生时立即输出，同时不产生 2.3 单事件重启窗口造成的生命周期事件丢失。
- 原生辅助库只在模块的 logcat 子进程中通过 `LD_PRELOAD` 生效，不注入 Launcher 或其它系统进程。

## 2.3

- 将长驻 logcat 管道改为单匹配事件读取。每次 `-m 1` 退出会立即刷新事件，随后以 `-T 1` 重启并用 epoch 行去重，消除长驻 stdout 的块缓冲延迟。
- 状态日志加入 `/proc/uptime` 单调时间，可量化事件、退避和恢复的先后关系。

## 2.2

- 修复 `wm_on_resume_called` 中右对齐 PID 的解析。logcat 在 PID 前加入空格时，2.1 会拒绝该记录，导致源应用未建立且策略只作用于壁纸/MIMD。
- 仅在 source/pending-source 内容变化时记录一次缓存结果，供实机验收，不启用高频调试日志。

## 2.1

- 根据 Sheng 实机 Launcher 日志加入全屏手势生命周期：`gestureStart`、`gestureToHome`、`gestureToApp`。
- 策略在 Launcher 正式接管手势时启用；不等待快滑/慢滑的最终提交。
- 取消手势时恢复源应用进入前记录的 cpuset 与 cpuctl。
- 保留按键最近任务和 RemoteBack 路径作为并行入口。

## 2.0 - 2026-08-22

- Replace the Recents-only trigger with an explicit Launcher lifecycle state machine.
- Start policy when Quickstep/remote animation takes control, before Launcher becomes the resumed Activity.
- Keep policy active through Home, Recents, and the complete Launcher exit animation.
- Remove the `PassBlurWindow` fallback, blur coupling, 750 ms entry deduplication, and one-second wallpaper/MIMD restore timer.
- Separate the previous source application from the newly resumed target application so the target is never demoted during its opening animation.
- Restore the original source cgroups when an app-to-Launcher gesture is canceled.
- Preserve v1.1's device-defined cgroups, original wallpaper/MIMD group restoration, guarded 120/320 ms source reassertion, and stale-listener cleanup.
- Keep module ID `hyperos4_recents_source_app_yield` for in-place upgrades.

## 1.1 - 2026-08-22

- Generalize scheduling to device-defined cgroups and validate it on Shennong.
- Reassert source placement after ActivityManager's early foreground promotion.
- Record and restore wallpaper/MIMD original groups.
- Clean stale monitor processes on module restart.

## 1.0 - 2026-08-22

- Initial Sheng Recents source-application yield implementation.
