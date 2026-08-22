# Sheng 快速操作后的应用 cgroup 恢复

测试设备为 Sheng HyperOS 4，目标进程为文件管理 `com.android.fileexplorer`。采样器每 50 ms 请求一次采样，只读取模块状态文件和 `/proc/<pid>/cgroup`、`/proc/<pid>/status`，不运行 Perfetto、simpleperf 或循环 dumpsys。

## 故障复现

现场中模块状态已经是 `app`，文件管理仍被留在：

```text
cpuset  /background
cpuctl  /background
allowed 0-2
```

连续 100 个样本全部如此。此时 Android 仍把文件管理视作前台应用，因此不是系统主动降级，而是模块在退出动画后没有完成对 source 的恢复。

第一次只恢复进入手势时保存的 cgroup 后，`background` 残留消失，但部分稳定样本停在 `/foreground`、CPU `0-6`。日志证明该快照是在 ActivityManager 已经开始手势降级后取得的，属于过渡态，不能作为 resumed Activity 的恢复目标。

## 修复

- 非 Launcher 应用收到 `activityResumed` 时先递增 policy epoch，使旧延迟任务失效。
- resumed 目标明确写入 `cpuset/top-app` 和 `cpuctl/top-app`。
- 延迟 source 重写使用调度时捕获的 PID 和记录，不重新读取可能已经提交为新目标的 `source-app`。
- 延迟写入后复核 pending、mode 和 source；若同一 PID 已恢复为目标，则回滚到 `top-app`。
- 稳定 `app` 提交最后再次把当前 source 放入 `top-app`，覆盖最后一个抢占窗口。

## 结果

自动执行八轮半程取消、快速回桌面和重新打开文件管理的组合。126 个样本中，完成后的 `app` 状态均回到：

```text
cpuset  /top-app
cpuctl  /top-app
allowed 0-7
```

两个采样点记录到 `mode=app`、`/foreground`，但它们分别位于下一次 `gestureStart` 到达模块前约一个采样周期，随后立即进入 `entering`，不是动画完成后的残留。测试结束后重新打开文件管理并等待两秒，ActivityManager 的 `topResumedActivity`、cpuset、cpuctl 和允许 CPU 均一致为 `top-app`、`0-7`。
