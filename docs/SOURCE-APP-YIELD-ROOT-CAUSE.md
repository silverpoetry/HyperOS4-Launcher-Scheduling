# 来源应用退避失效的根因与替代方案

## 结论

当前版本把来源应用写入 `cpuset/background` 和 `cpuctl/background`，但在 Sheng 的高负载游戏上，这只改变了可见的 cgroup 路径，并没有在动画关键阶段形成实际的 CPU0-2 硬限制。继续提高 `cgroup.procs` 的写入频率不能解决问题。

可用的用户态控制面是线程 nice。原生监听器在动画边沿一次性保存来源应用各 TID 的 nice，将高优先级线程临时降到 `nice=+10`，动画结束或取消时按 TID 恢复原值。该值不会被 ActivityManager、metis 或游戏在测试窗口内覆盖。

## 实际链路

1. Launcher 发出 `gestureStart`，原生 `launcher-logwatch` 立即把来源 PID 写入 background cpuset/cpuctl。
2. 内核 `cgroup_attach_task` 记录证明写入成功；约 196 ms 后，`system_server` 的 `OomAdjuster` 又把仍然可见的来源 Activity 提到 `foreground`。这是 Android 可见进程的正常调度语义。
3. 即使没有等到 OomAdjuster，直接把游戏 PID 写入 `background/cgroup.procs` 或逐 TID 写入 `background/tasks`，UnityMain 的 cgroup 路径会显示 `/background`，但 `Cpus_allowed_list` 和 `sched_getaffinity` 仍为 CPU0-7，至少 100 ms 不变。
4. 调用系统 `settaskprofile TID CPUSET_SP_BACKGROUND` 结果相同：task profile 报告成功，路径进入 background，实际允许 CPU 仍为 0-7。
5. 对该 UnityMain 调用 `sched_setaffinity(0-2)` 时，系统调用返回成功，但同一次命令读回即为 0-7。内核 syscall trace 只出现调用者 `taskset`，没有游戏或其它用户态进程发起第二次恢复调用。
6. 内核已加载 Xiaomi `metis` 和 WALT 调度扩展，并注册 `mi_sched_setaffinity`、`mi_set_cpus_allowed_comm` 等钩子。实机行为表明，游戏的实际选核受到这一层控制，不能用普通 cgroup/affinity 写入可靠覆盖。
7. `metis` 暴露的 `add_rebind_task_lit` 节点按单 TID写入后也没有改变实际选核：同一 UnityMain 在相邻两个 500 ms 窗口中，基线有 99 次被调度到 CPU7，写入后仍有 89 次被调度到 CPU7。

因此，当前失败同时有两层原因：ActivityManager 会根据可见状态重新分组；更深的 Xiaomi 调度层又使普通 background/affinity 写入不等于实际小核约束。

## nice 验证

对单个 UnityMain 从 `nice=-20` 临时改为 `nice=+10`：

- 立即生效；
- 500 ms 后仍为 `+10`；
- 可恢复到原来的 `-20`。

原生批处理对 159 个现有线程完成保存和修改约需 1.0 ms，恢复约需 0.5 ms，不需要轮询。

同一暖态游戏进程的四轮进入最近任务 A/B：

| 指标 | v3.5 cgroup | 动画期 nice=+10 |
|---|---:|---:|
| 来源游戏实际 CPU 时间 | 2398.8 ms | 2137.6 ms |
| Launcher 关键线程最长 runnable 等待 | 16.44 ms | 13.36 ms |
| Launcher `CALLBACK_ANIMATION` >16.67 ms | 13 | 11 |
| Full/Partial 帧时间线 jank | 1 | 1 |

`nice=0` 只消除负 nice，但游戏仍有大量同优先级可运行线程，未产生稳定收益。`nice=+10` 能让 Launcher 在竞争时先运行，但不会减少游戏本身的工作量，也不会禁止游戏在空闲性能核上运行。

## 推荐实现

将退避从“高频抢写 cgroup”改成“动画边沿一次性 nice 事务”：

1. `launcher-logwatch` 收到真实卡片开始移动的事件；
2. 读取已缓存的 source PID；
3. 在原生进程内枚举 `/proc/PID/task`，保存 `TID -> 原始 nice`；
4. 只对 `SCHED_OTHER` 且 nice 小于 `+10` 的线程设置 `nice=+10`；
5. 保持到对应进入动画完成、退出动画完成或取消事件；
6. 只对仍属于原 PID 的原 TID恢复记录值；已退出线程忽略；
7. 恢复必须幂等，守护退出、模块关闭和开机清理都执行一次；
8. 初版不做20ms轮询。若以后证明动画中确有新建的高负载线程，再增加一次受 epoch 保护的短延迟补扫，而不是持续抢写。

原有 cgroup 写入可以保留为普通应用的辅助策略，但不再把路径变化当成实际退避成功，也应删除120/320 ms和20 ms竞争式重写。

## 边界

- 这是调度竞争优先级控制，不是减少来源应用计算量；
- nice 对实时调度线程不生效，音频等 RT 线程仍按原策略运行；
- 打开目标应用时应保持退避到 Launcher 的关闭动画完成，再恢复，不能在 `activityResumed` 立即恢复；
- 若要从内核层彻底约束选核，需要修改与当前固件匹配的 metis/WALT 钩子。公开的 Sheng 内核主树没有提供这部分模块实现，不能把未知私有参数作为正式模块依赖。
