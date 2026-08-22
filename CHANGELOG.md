# Changelog

## Project collection move - 2026-08-22

- 项目移动到 `D:\Projects\Magisk\HyperOS4-Launcher-Scheduling`。
- 构建成品统一写入父级 `..\output`，不再在仓库内维护 `dist` 副本。
- 原 Shennong 专用 ADB 5555 支持项目已拆分为独立的通用模块项目。

2.1–2.7 是同日实机收敛候选；2.8 完成 Launcher 生命周期验证；3.0 恢复并通用化逐线程调度。

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
