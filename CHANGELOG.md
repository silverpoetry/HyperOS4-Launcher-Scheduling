# Changelog

## Project collection move - 2026-08-22

- 项目移动到 `D:\Projects\Magisk\HyperOS4-Launcher-Scheduling`。
- 构建成品统一写入父级 `..\output`，不再在仓库内维护 `dist` 副本。
- 原 Shennong 专用 ADB 5555 支持项目已拆分为独立的通用模块项目。

2.1–2.7 是同日实机收敛候选；2.8 完成 Launcher 生命周期验证；3.0 恢复并通用化逐线程调度。

## 4.2

- 将转场小核限频改为默认关闭，WebUI 仍保留开关、比例与超时参数，供高负载或功耗实验手动使用。
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
