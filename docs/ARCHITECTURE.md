# Runtime architecture

模块由三个常驻执行单元组成：shell 状态机、阻塞在 logd 的 Launcher 事件读取器、阻塞在内核 tracepoint 与控制 socket 上的来源守卫。它们都由事件唤醒，不轮询界面或进程状态。

## 依赖方向

```text
launcher-logwatch ── lifecycle event ──> events.sh ──> state-machine.sh
       │                                      │
       └─ initial cgroup placement            └─ policy commands
                                                  │
                                                  v
source-guard <── Unix datagram commands ── process-policy.sh
       │
       └── cgroup_attach_task tracepoint
```

`source-guard` 是来源应用状态的唯一所有者。shell 只保存 source 与 pending source 的身份记录，不保存线程级事务。

## 策略层

- `config.sh`：持久配置与运行时路径。
- `runtime.sh`：服务生命周期、日志、序号与通用 cgroup 原语。
- `topology.sh`：从在线 CPU、系统 cpuset 和 `cpu_capacity` 推导动态核心集合。
- `source-guard.sh`：创建专用 cpuset/cpuctl、配置 CPU 集与 shares、管理原生守卫生命周期。
- `process-policy.sh`：source/pending source 身份、守卫命令与辅助进程恢复。
- `launcher-policy.sh`：Launcher UI、Raster、Rust、ResMgr 与 FenceWait 的线程放置。
- `systemui-policy.sh`：SystemUI/WMShell 转场线程放置。
- `frequency-policy.sh`：可选效率核限频事务。
- `state-machine.sh`：`app/entering/home/recents/leaving` 转换。
- `events.sh`：把筛选后的 Launcher 生命周期事件映射到状态机。

## 来源应用热路径

稳定应用阶段向守卫发送 `arm PID UID`。守卫在内存中缓存 TID 与原始 nice；这一步不在动画关键路径。

`launcher-logwatch` 收到真实动画入口后执行：

1. 向 `/dev/cpuset/hyperos4-source/cgroup.procs` 写一次来源 PID；
2. 向 `/dev/cpuctl/hyperos4-source/cgroup.procs` 写一次来源 PID；
3. 通过 Unix datagram 发送 `activate PID UID`；
4. 把生命周期事件交给 shell。

cpuset 在前两次写入后形成硬 CPU 边界，现有线程被整体迁移，新线程自动继承。守卫随后应用内存中的 nice 快照并清除对应的 Xiaomi `minor_window_app` 标记。

ActivityManager 后续执行 task profile 时，内核产生 `cgroup_attach_task`。守卫只比较当前来源 PID/TID；发现目标离开专用组后，整体写回 cpuset/cpuctl。cgroup 覆盖不改变 nice，因此纠正路径不枚举线程。自己的写回事件在读取 `/proc/<pid>/cgroup` 后被识别为已满足，不会形成循环。tracepoint 只在 active 事务中启用，空闲阶段不接收系统其它迁移事件。

## 恢复不变量

- 稳定 `app` 状态的当前应用位于 `top-app`，原始 nice 与 Xiaomi 标记已恢复。
- Launcher 可见期间，来源应用保持在专用组。
- pending target 在卡片展开动画结束前保持受控，完成后才提交为下一轮 source。
- 同一 pending 目标的重复 resumed 事件不重启完成超时。
- 切换到不同目标时，旧来源进入系统 background，新目标成为守卫唯一所有者。
- 守卫停止、服务退出和卸载都先释放当前来源，再移除专用 cgroup。
- 没有 SAF 文件、逐事件进程启动、周期性 cgroup 重写或旧控制器回退路径。

## WebUI

持久设置位于 `/data/adb/hyperos4-launcher-scheduling`。来源核心选择决定专用 cpuset 的 `cpus`，来源压制等级同时决定守卫应用的目标 nice 和专用 cpuctl 的 `cpu.shares`。配置更新通过服务 reload 重新配置同一组与同一守卫，不启动第二套策略。
