# 验证记录

## v4.0 来源应用真实退避

Sheng 上确认 Xiaomi `metis` 的 `minor_window_app` 是旧方案失效的根因。该节点等于来源应用 UID 时，`sched_setaffinity()` 返回成功后线程仍会被立即扩回 `0-7`；按 Joyose 小窗结束语义写入 `0` 后，同一线程可以稳定保持在 `/dev/cpuset/background/cpus` 定义的 `0-2`。

v4.0 使用 `source-affinityctl` 保存并恢复每个 TID 的原始 affinity。以 160 线程的游戏为来源应用，初次设置后 160/160 位于后台 CPU 集，500 ms 后仍为 160/160；经过 Launcher 入口事件后，仍存活的 158/158 线程保持约束，恢复时精确恢复 158 个线程，2 个已经退出的线程按启动时间校验跳过。

事务转移也完成了 Settings → 文件管理实测：Settings 的 72/72 线程先恢复，文件管理的 79/79 线程随后受约束，最终 79/79 精确恢复。来源 UID 标记被外部重新写入后，下一条生命周期事件会把标记清零并重新约束逃逸线程；没有 20 ms 轮询或延时抢写。

Sheng 上 74 个 Settings 线程的控制器内部耗时为：首次事务 2.812 ms，无变化复核 1.017 ms，只修复 UID 标记的复核 0.904 ms。入口由原生 logd 监听器通过 `posix_spawn()` 调用控制器，再写 background cgroup。以 71 线程的游戏现场测得完整原生入口事务 16.877 ms，原 `fork()+exec()` 路径为 29.294 ms。

最终安装包还完成了游戏 UID 现场测试：入口前 `minor_window_app=10341`；入口后该值为 `0`，71/71 个线程受限于 CPU `0-2`，700 ms 后仍为 71/71。应用重新打开时，Joyose 曾把标记写回 `10341` 并造成 15 个线程逃逸；同一生命周期事件将标记再次清零并重新约束 15 个线程。动画结束后恢复 65 个仍存活线程，7 个已经退出的线程按启动时间跳过，状态文件删除，标记恢复为 `10341`。

同一 v4.0 游戏进程的 affinity 单变量 A/B 表明：来源应用在性能核的 CPU 时间下降 56.8%，Launcher p95 下降 7.2%，全链路 Full/Partial 从 28 降到 14。第二次开启样本消除了 Launcher 和 task transition leash 的 Full/Partial，另一次开启样本仍存在 Floating Dock 82.4 ms 离群帧。Settings 低负载样本因任务类型和辅助组件状态不同，只能作粗略等待量参考，不能用于判定 Dock、Caption 等组件的因果关系。完整结果见 [来源应用 affinity 性能 A/B](SOURCE-AFFINITY-PERFORMANCE-AB.md)。

## 基础 A/B

v1.1 在 Shennong 上完成源应用调度 A/B，确认 ActivityManager 会在第一次退避后约 100–110 ms 重新提升进程；120 ms 和 320 ms 的受保护重写可在关键窗口维持 background。原始数据位于 `test-results/shennong-20260822-ab/`。

## Sheng v2.8 生命周期验证

2026-08-22 在 Sheng HyperOS 4 实机完成同一启动周期验证。设备使用 3048×2032 横屏，测试应用为 KernelSU，结果详见 `test-results/sheng-20260822-v2.8/REPORT.md`。

| 路径 | 状态结果 | cgroup 结果 |
|---|---|---|
| 桌面点击应用 | `home → leaving → app` | 目标最终为 `top-app` |
| 快滑回桌面 | `app → entering → home` | source、壁纸、MIMD 为 `background`；Launcher 为 `top-app` |
| 慢滑进入最近任务 | `app → entering → home → recents` | source 在最近任务稳定前进入 `background` |
| 上滑后取消 | `app → entering/home → app` | source 先退避，取消后恢复为 `top-app`，两秒后未被旧任务覆盖 |
| 最近任务打开同一应用 | `recents → leaving → app` | 没有误触发 cancel；pending/source 同 PID 被主动恢复为 `top-app` |

实测关键单调时间：

```text
cancel:
  gesture start       78.13
  source restored     78.52
  app stable          78.83

slow recents:
  gesture start       92.26
  Launcher resumed    92.73
  recents stable      93.10

open from recents:
  exit start          94.30
  pending cached      94.41
  target restored     94.42
  app stable          95.38
```

进程检查只有一个 service 守护、一个 `launcher-logwatch` 和一个管道读取 shell。没有 logcat 监听器，也没有重复模块守护。

## Shennong v3.0 逐线程验证

Shennong 的设备拓扑为：

```text
top-app:    0-7
background: 0-1,5-6
capacity:   379,379,923,923,923,867,867,1024
```

模块运行时得到 `perf=9c`、`mid=1c`、`little=03`。批处理工具对 1 个 raster、1 个 UI、多个 Rust、2 个 ResMgr 和 1 个 fence 线程执行 apply/reset 均无失败，单次约 10 ms。

隔离 A/B 只切换逐线程 affinity/uclamp，源应用、壁纸和 MIMD 的 cgroup 策略保持启用。每个有效 FrameTimeline 场景使用三轮样本；逐线程×CPU 的 `task-clock` 使用两轮可配对细粒度样本。

| 场景 | 关闭时关键线程落在目标集合外 | 开启后 | 关键线程 + ResMgr task-clock 变化 |
|---|---:|---:|---:|
| 快滑回桌面 | 17.25% | 0% | -23.7% |
| 慢滑最近任务 | 19.24% | 0% | -23.0% |
| 半程取消 | 17.59% | 5.32% | -12.8% |
| 桌面打开应用 | 27.25% | 0% | -18.3% |
| 最近任务打开应用 | 15.42% | 0% | -12.4% |

半程取消样本中的 5.32% 来自测试切换器在 gesture 事件到来后才完成重新应用；最终切换器和模块启动路径已修正为手势前应用。ResMgr 在关闭状态下按平台原始策略位于 CPU0-1，开启后位于 CPU2-4。

Launcher 在所有有效样本中均无 Full jank。每轮最大 Launcher 帧耗时的均值如下：

| 场景 | 关闭 | 开启 |
|---|---:|---:|
| 快滑回桌面 | 16.77 ms | 13.13 ms |
| 慢滑最近任务 | 17.20 ms | 14.10 ms |
| 半程取消 | 13.15 ms | 12.98 ms |
| 桌面打开应用 | 24.16 ms | 15.80 ms |
| 最近任务打开应用 | 16.82 ms | 17.14 ms |

SurfaceFlinger/SystemUI 仍有少量正反向离群 jank，不能从这组样本推导出全局掉帧必然下降。能确认的是 CPU 放置和任务完成时间发生了预期变化；单独的 uclamp 增益没有从 affinity 中拆分。

## 静态与构建检查

- 所有模块 Shell 脚本通过 `sh -n`；
- `launcher-logwatch` 和 `launcher-threadctl` 均由 NDK arm64 编译并保留 C 源码；
- ZIP 根目录包含 KernelSU 脚本和三个 arm64 工具；
- 源码不包含 blur 阈值、固定 CPU 编号、频率锁或前台轮询；
- `git diff --check` 通过；
- 构建产物生成 SHA-256 文件。

当前验证针对 Sheng 这一版 HyperOS 4 Launcher 日志协议。桌面大版本更新后应重新运行生命周期测试。

## Shennong v3.1 prime 倾向验证

2026-08-22 在恢复官方 cpuset 后重新测试。官方值为 `top-app=0-7`、`background=0-1,5-6`；3.0 基线仍推导出 `perf=9c`，但 Raster 在 CPU7 的 task-clock 占比只有约 6.5%–16.2%。原因是原 Raster uclamp 768 低于 CPU2-4 的 capacity 923，EAS 无需使用 capacity 1024 的 CPU7。

先测试 Raster 动画期强绑动态 prime。CPU7 占比达到 85%–94%，但快回桌面和慢进最近任务中增加了 SurfaceFlinger Full/Partial jank，因此弃用。

最终策略保持 Raster 的 `perf` 迁移空间，将 Raster uclamp 设为 928；UI/Rust 动画期进入 `mid`，避免与 Raster 争 prime。三轮交替 A/B 结果：

| 场景 | Raster CPU7 占比：3.0 | 3.1 | Raster task-clock 变化 | Launcher Full/Partial jank |
|---|---:|---:|---:|---:|
| 快回桌面 | 18.8% | 34.6% | -4.4% | 0 / 0 |
| 慢进最近任务 | 6.5% | 49.0% | -13.4% | 0 / 0 |
| 半程取消 | 13.7% | 57.2% | -7.7% | 0 / 0 |

快回桌面的第一对样本采集窗口明显不完整，FrameTimeline 的全局离群统计不采用该对。其余样本中 SystemUI/SurfaceFlinger 仍有少量双向离群，3.1 没有证明可以消除系统合成侧的偶发 jank。运行期检查确认，动画内 Raster 为 `9c/min=928`、UI/Rust 为 `1c/min=768/512`；动画结束后恢复 `9c/min=0`。

Scene 的“官方调度”模式仍保留 `scene-daemon`。它会在稳定应用态将 Launcher 基础亲和恢复为 `ff`，但动画中现场读取仍是模块的 `9c/1c/03` 和对应 uclamp。模块按动画事件重新应用策略，不在稳定应用态持续轮询或与外部调度器争写。

## Sheng v3.1 后台负载验证

2026-08-22 在 Sheng 横屏 `3048×2032` 上测试。后台腾讯会议主进程含 199 个线程，位于 `cpuset/background` 和 `cpuctl/background`，只允许 CPU0-2。正式窗口中 profile 1 和 profile 2 的会议平均 CPU 占用分别约为 55.5% 和 55.6% 单核，负载强度相当。

Sheng 拓扑为 `perf=f8 (CPU3-7)`、`mid=78 (CPU3-6)`、`little=07 (CPU0-2)`。三轮交替 A/B 结果：

| 场景 | Raster CPU7：3.0 | 3.1 | Raster task-clock | Launcher p95 | Launcher Full/Partial jank |
|---|---:|---:|---:|---:|---:|
| 快回桌面 | 33.3% | 86.1% | -14.2% | 6.253 → 6.233 ms | 0 / 0 |
| 慢进最近任务 | 32.3% | 83.6% | -21.5% | 11.380 → 10.149 ms | 0 / 0 |
| 半程取消 | 28.9% | 77.1% | -16.0% | 7.170 → 5.277 ms | 0 / 0 |

UI 被分流至 CPU3-6 后 task-clock 增加约 13.6%–29.8%，但 Launcher 帧 p95 没有恶化。SurfaceFlinger 和 SystemUI 层的少量离群在不同场景中正反向变化，没有证明 3.1 会统一改善系统合成侧 jank。完整说明见 `docs/SHENG-HIGH-LOAD-VALIDATION.md`。
