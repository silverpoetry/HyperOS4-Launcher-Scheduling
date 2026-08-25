# 运行架构

模块由两个常驻原生进程和一个负责生命周期的 shell 服务组成。

```text
logd
  │ Launcher 生命周期日志
  ▼
launcher-logwatch
  ├─ 转场状态机
  ├─ Launcher / SystemUI / system_server 线程策略
  ├─ 活动转场内的定点亲和复核
  └─ 带转场 ID 的来源控制命令
                         │
                         ▼
                    source-guard
                      ├─ 来源 PID、UID、starttime 与包名
                      ├─ 专用 cpuset / cpuctl
                      ├─ nice 与 affinity 快照
                      ├─ cgroup_attach_task 追踪
                      └─ 视觉稳定定时恢复
```

shell 服务只在启动和配置重载时执行以下操作：

1. 读取持久配置并推导 CPU 拓扑；
2. 创建来源应用专用控制组；
3. 启动 `source-guard`；
4. 识别一次当前前台应用并建立初始来源身份；
5. 生成只读运行配置并启动 `launcher-logwatch`。

转场期间不运行 `pidof`、`dumpsys`、`taskset`、`uclampset`、shell 定时器或其它子进程。状态文件由协调器的后台线程异步发布，不阻塞日志事件处理。

## 转场协调器

`launcher-logwatch` 直接使用 `liblog` 的阻塞流读取 Launcher PID 的 main 生命周期日志。原始日志先由状态机合并为逻辑转场，一次操作只产生一个转场 ID。读取线程与策略线程分离；退出时主线程先关闭事件提交，再等待正在处理的事件跨过屏障，最后统一恢复策略。

协调器使用 `top-app` cpuset 作为进程上限，再对自身线程做精确亲和：主线程、计时线程和看门狗固定在效率核，日志读取线程固定在次级性能核。来源守卫固定在一颗次级性能核。这样日志解析和 cgroup 纠正不会占用 Prime，也不会与受限来源一起堵在效率核。

进入转场时，协调器完成以下工作：

- 通知来源守卫约束当前来源应用；
- 扫描一次 Launcher、SystemUI 和 system_server 的目标线程；
- 保存尚未记录的线程身份、原始亲和与原始 uclamp；
- 应用配置的核心集合和 uclamp；
- 启动活动转场内的定点复核。

复核只读取已缓存的少量 TID。若系统在转场期间覆盖了目标线程的亲和，下一次复核只重写发生变化的线程。默认间隔为 20 ms，可在界面调整。复核不会重新扫描 `/proc`，也不枚举来源应用线程。

进入桌面、进入最近任务或返回应用后，协调器等待一段视觉稳定时间。默认 450 ms。期间继续保持目标策略；到期后恢复 SystemUI、system_server 和 Launcher uclamp。Launcher 的基础亲和在服务运行期间保留，服务停止或重载时恢复原值。

## 来源应用守卫

`source-guard` 是来源应用执行状态的唯一所有者。它保存：

- PID、UID、进程 starttime 和完整包名；
- 当前已接受的转场 ID；
- 每个已见线程的原始 nice 与 affinity；
- Xiaomi `minor_window_app` 原始值；
- 当前约束与恢复定时器状态。

协调器只发送以下事务命令：

- `enter ID`：约束当前来源；
- `handoff ID PACKAGE`：返回同一来源卡片时保持约束，等待动画完成；
- `adopt ID PACKAGE`：稳定应用前台更新来源身份；若从最近任务打开另一张卡片，先把旧来源恢复到 background，再登记目标但不压制目标；
- `complete ID DELAY`：在视觉稳定时间后恢复目标应用；
- `replace-current PID UID PACKAGE`：当前来源主进程重建时更新身份。

守卫拒绝小于当前转场 ID 的命令。旧日志、重复 resumed 事件和上一轮完成定时器不能覆盖新转场。PID、UID、进程 starttime 与每个已登记 TID 的 starttime 都参与恢复校验。

来源稳定前台时建立线程索引。每次从未激活状态进入退避前，只对已索引线程刷新一次 nice 与 affinity 基线，然后再移动控制组；同来源转场延续时禁止重采基线。进入专用 cpuset/cpuctl 时只写一次进程 PID，内核迁移现有线程，新线程继承控制组。ActivityManager 后续改写 task profile 时会触发 `cgroup_attach_task`；守卫按事件命中的 PID/TID 立即写回，不在纠正路径枚举全部线程。视觉转场完成后先回到 `top-app`，再恢复 affinity，最后恢复 nice，避免系统任务配置覆盖恢复值。

## 线程策略

Launcher：

- Raster 使用独立的渲染核心集合，默认 Prime；
- UI 与 Rust 使用非 Prime 性能核；
- 资源管理和 FenceWait 分别使用可配置集合；
- uclamp 覆盖完整视觉转场，结束后恢复原值。

SystemUI：

- 主线程、RenderThread、`wmshell.main` 和 GPU 完成线程使用关键集合；
- GC、终结器、JIT 和 Profile Saver 使用维护集合；
- 默认关键集合为非 Prime 性能核。

system_server：

- `android.anim` 和 `android.display` 使用关键集合；
- `TaskSnapshotPersister` 使用次级集合；
- 不统一修改 Binder 线程，不固定 SurfaceFlinger。

SurfaceFlinger 保持系统优先级和可迁移性。该模块只减少与其生产者、WMShell 和 WMS 的可控竞争，不改变显示 HAL 或合成策略。

## 配置与恢复

持久配置位于 `/data/adb/hyperos4-launcher-scheduling`。运行配置和守卫 socket 位于 `/dev/.hyperos4-launcher-scheduling`，重启后不会残留。

服务重载、模块关闭和卸载均按以下顺序恢复：

1. 协调器恢复 Launcher、SystemUI、system_server、辅助进程和频率状态；
2. 来源守卫恢复当前应用到 top-app，并恢复 nice 与 Xiaomi 标记；
3. 服务移除专用控制组和运行时文件。

若重载发生在最近任务稳定态，服务在替换进程前保存来源身份与 `recents` 场景；新协调器启动后立即重新激活同一来源。重载本身不会把来源提前放回 top-app。
