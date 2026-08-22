# Shennong 逐线程调度 A/B

## 目的

验证恢复 Launcher 逐线程 affinity/uclamp 后，CPU 放置是否实际生效，以及它是否对 HyperOS 4 的桌面转场产生可测量影响。

## 方法

设备为 Shennong，逻辑分辨率 1080×2400。A/B 只切换 `thread-policy.state`，整进程 source/wallpaper/MIMD cgroup 策略始终启用。

场景包括快滑回桌面、慢滑最近任务、半程取消、桌面打开文件管理和最近任务打开中央卡片。使用：

- `simpleperf task-clock --per-thread --per-core`，观察 Launcher 目标线程在每个 CPU 的运行时间；
- SurfaceFlinger FrameTimeline，观察 Launcher、SystemUI 和 SurfaceFlinger 的 Full/Partial jank；
- 模块状态日志，确认 `app/entering/home/recents/leaving` 结果。

三次无效场景被排除：第二轮快滑分别被通知栏和距离传感器提示遮挡；第二轮启用态慢滑被系统判定为取消。补测的第四轮用于替换这些样本，没有把失败操作计入对应场景。

原始数据位于：

```text
test-results/shennong-thread-policy-20260822-160032
test-results/shennong-thread-policy-20260822-160321
test-results/shennong-thread-policy-20260822-160834
```

## 结果

关闭策略时，UI/raster/Rust 有 15.42%–27.25% 的 task-clock 位于目标性能集合之外。开启后，四个完整场景为 0%；半程取消保守样本为 5.32%。最终实现已经修正测试切换器的延迟重新应用问题。

两轮细粒度配对中，UI/raster/Rust 与 ResMgr 的累计 task-clock 在五个场景里均下降，范围为 12.4%–23.7%。该结果表明相同转场工作在合适核心上完成得更快，但样本量不足以推导功耗变化。

Launcher 自身所有有效样本均没有 Full jank。最大 Launcher 帧耗时在快滑、慢滑、取消和桌面打开应用时下降；最近任务打开应用基本持平。SystemUI 和 SurfaceFlinger 有少量正反向离群帧，因此不把逐线程策略描述为通用的“消灭掉帧”方案。

旧 shell 逐 TID 实现整组约 0.8 秒，无法覆盖动画首段。原生 `launcher-threadctl` 的 apply/reset 实测各约 10 ms，且 affinity/uclamp syscall 均返回成功。

## 结论

逐线程 affinity 有明确作用，应保留。短时 uclamp 与 affinity 一起参与了 A/B，但没有单独隔离，视为辅助策略。最终实现使用设备拓扑推导和原生批处理，不使用固定 CPU 编号。
