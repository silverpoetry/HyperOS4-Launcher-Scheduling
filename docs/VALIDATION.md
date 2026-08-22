# 验证记录

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
- ZIP 根目录包含 KernelSU 脚本和两个 arm64 工具；
- 源码不包含 blur 阈值、固定 CPU 编号、频率锁或前台轮询；
- `git diff --check` 通过；
- 构建产物生成 SHA-256 文件。

当前验证针对 Sheng 这一版 HyperOS 4 Launcher 日志协议。桌面大版本更新后应重新运行生命周期测试。
