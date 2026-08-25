# 来源应用退避链路审计（2026-08-25）

## 范围

本次审计验证 HyperOS 4 桌面转场中的来源应用退避，测试设备为 Sheng，来源应用为 `com.tencent.jkchess`。操作使用屏幕三指上滑进入最近任务，再点击当前卡片返回应用。

正式实现只把 Launcher 视为转场权威。模块不监听触摸事件、第三方应用内部事件、全局 Activity 生命周期或全局 cgroup 变化来推测转场。

## 最终链路

```text
Launcher main 日志
        │ 仅 Launcher PID
        ▼
launcher-logwatch
        │ enter / handoff / adopt / complete + transition ID
        ▼
source-guard
        ├─ PID、UID、starttime 身份校验
        ├─ 前台基线：每线程 nice + affinity
        ├─ 专用 cpuset / cpuctl
        ├─ cgroup_attach_task 定点纠正
        └─ 视觉稳定后事务恢复
```

一次进入转场按以下顺序执行：

1. Launcher 发出明确的进入信号；
2. 协调器创建新的转场 ID，先向来源守卫发送 `enter`；
3. 来源仍在 `top-app` 时，守卫刷新已索引线程的 nice 和 affinity 基线；
4. 来源进程进入专用 cpuset/cpuctl，并应用目标 nice；
5. 协调器应用 Launcher、SystemUI 和 system_server 线程策略；
6. Android 后续覆盖来源控制组时，`cgroup_attach_task` 事件只纠正命中的 PID/TID；
7. 返回动画结束后，来源先回 `top-app`，再恢复 affinity，最后恢复 nice。

同来源 `handoff` 发生时，来源仍处于退避状态。此时只延续事务，禁止重新采集基线。

## 已修复的根因

### 热路径全量线程扫描

早期实现收到入口后才枚举来源应用全部线程并读取 `/proc/<tid>/stat`。重载应用有 120–160 个线程，退避会晚到可见动画之后。

最终实现把线程索引准备放在稳定前台阶段。入口只刷新已索引线程的 `getpriority` 和 `sched_getaffinity`，不重新遍历 `/proc`。首次 cgroup 迁移先于 Launcher/SystemUI 线程策略执行。

### 同来源返回污染恢复基线

返回当前卡片时会再次收到同来源激活信号。旧实现无条件采集基线，因此把退避中的 `CPU0–2 / nice19` 保存成原始状态，导致返回应用后长期留在小核。

最终实现只允许在 `inactive -> active` 边界采集基线。三轮连续往返后，主线程基线始终为 `CPU0–7 / nice -10`，恢复目标未再变化。

### 只恢复控制组，没有恢复线程亲和

Android 在退避期间可能同时改写 task profile 和线程 affinity。只把进程写回 `/top-app` 不能保证线程亲和恢复。

来源守卫现在为已见线程保存原始 affinity。退出事务按以下顺序恢复：

1. cpuset 回 `/top-app`；
2. cpuctl 回 `/top-app`；
3. 恢复线程 affinity；
4. 恢复线程 nice；
5. 恢复 Xiaomi `minor_window_app`。

恢复继续校验进程 PID、UID、starttime 和线程 starttime，避免 PID/TID 复用。

### cgroup 纠正队列积压

旧的纠正函数每收到一次主进程迁移事件，都会再次刷新全部线程并重写 nice。系统连续应用 task profile 时，后续事件会在守卫内部排队，产生 40–70 ms 的逃逸窗口。

最终纠正路径为常数时间：

- 主 PID 事件：立即把整个进程写回来源 cpuset/cpuctl；
- 子 TID 事件：只把该 TID 写回；
- 只修正命中线程的 nice；
- 不调用 `refresh_tasks()`，不全量调用 `apply_nice()`。

### 守卫与来源应用争抢效率核

来源守卫原先固定在 CPU0。重载来源被压到效率核后，守卫也会受到同一组 runnable 竞争，延迟处理 cgroup 事件。

当前自身线程分配为：

| 线程 | CPU 集合 | nice |
| --- | --- | ---: |
| 协调器主线程、计时线程、看门狗 | 效率核中的单核 | 0 |
| Launcher 日志读取线程 | 次级性能核 | -5 |
| 来源守卫 | 次级性能核中的单核 | -10 |

协调器进程使用 `top-app` cpuset 作为上限，然后用线程 affinity 精确限制自身线程。它不使用 Prime，也不会被设备的 `/foreground` 小核上限截断。

## 实机时序

最终三轮低开销记录：

- 手势开始后约 150–180 ms，来源已进入 `/hyperos4-source`；
- 来源退避在首段可见卡片动画前完成；
- 进入和最近任务稳定阶段，实际 cpuset 始终为 `/hyperos4-source`；
- 返回动画中，系统写入的宽 affinity 会显示为 0–7，但实际 cpuset 仍为 `/hyperos4-source`，不能把该显示误判为性能核逃逸；
- 视觉稳定后恢复为 `/top-app / CPU0–7 / nice -10`。

三轮结束状态：

```text
active=0
trace_enabled=0
main_original_nice=-10
main_original_affinity=ff
affinity_restore_attempts=288
affinity_restore_successes=288
nice_restore_attempts=358
nice_restore_successes=358
```

恢复尝试与成功数一致。

## 重载 A/B

记录目录：

- `test-results/jkchess-current-ab-20260825-195642`

每组执行四轮三指进入最近任务和点击卡片返回，顺序为启用、禁用、启用。以下数据只统计 Launcher Surface 帧时长；FrameTimeline 中大量 `Dropped Frame / Unknown` 不作为可见掉帧计数。

| 来源退避 | 返回阶段 Launcher >16.67 ms | p95 | 最大值 |
| --- | ---: | ---: | ---: |
| 启用 A | 2 | 11.94 ms | 21.55 ms |
| 禁用 | 110 | 19.52 ms | 22.15 ms |
| 启用 B | 4 | 12.76 ms | 21.41 ms |

启用两组结果接近，禁用组稳定恶化。入口稳定阶段三组均没有超过 16.67 ms 的 Launcher 帧；剩余 Full jank 主要是少量 Display HAL、SurfaceFlinger CPU/GPU Deadline 或 SystemUI resync，不属于来源应用退避能完全消除的范围。

调度记录中，启用组四轮的来源主线程在入口命令后的首个采样即位于 CPU0–2，`last_big_after_command_ms` 均为空；禁用组仍在性能核运行约 297–300 ms。

## 负向验证

设置应用内从主设置切换到 Wi-Fi 设置后：

```text
phase=app
transaction=none
sequence=0
policy_active=0
source active=0
```

前后序号和策略状态不变，说明同包 Activity 切换不会被当作桌面转场。

## 运行开销

11 秒全调度 Perfetto 会放大日志读取开销，因此该数值用于相对比较，不作为日常功耗估计。最终启用组中：

- `source-guard` 在约 5.1 秒入口窗口消耗约 20 ms CPU；
- `source-guard` 在约 3.3 秒返回窗口消耗约 74–78 ms CPU，其中包含转场结束时恢复 120–160 个线程；
- 日志读取线程仍需消费 Launcher 自身 main buffer，约占单核 6–14%，但固定在 CPU3–6，不占 Prime；
- 稳定无转场时，计时线程阻塞等待，不做全局扫描。

模块没有触摸监听、第三方应用监听、system_server events 全量监听、20 ms 来源线程全量扫描或周期性 shell 进程。

## 发布回归条件

发布前必须同时满足：

1. 三指入口由 Launcher 信号触发，同包 Activity 切换不增加转场序号；
2. 来源退避先保存基线，再移动控制组；
3. 同来源 handoff 不重采基线；
4. cgroup 覆写纠正路径不枚举全部线程；
5. 返回结束恢复 top-app、原始 affinity 和原始 nice；
6. 协调器自身线程不占 Prime，日志读取和来源守卫不被来源小核 cpuset 截断；
7. 启用—禁用—启用 A/B 的两组启用结果一致；
8. 测试结束后删除设备端 Perfetto 配置和 trace，并恢复屏幕常亮设置。
