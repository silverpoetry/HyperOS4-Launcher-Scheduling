# Runtime architecture

模块运行时由一个阻塞式 shell 控制器和一个阻塞在 logd 的原生事件读取器组成。代码拆分通过启动时 `source` 完成，不增加常驻进程、轮询器或 IPC 层。

## 依赖方向

```text
service.sh
  ├─ config.sh
  ├─ runtime.sh
  ├─ topology.sh
  ├─ launcher-policy.sh
  ├─ frequency-policy.sh
  ├─ process-policy.sh
  ├─ state-machine.sh
  └─ events.sh

launcher-logwatch ── event line ──> events.sh ──> state-machine.sh
       │                                   │
       └─ source affinity/cgroup fast path └─ policy layers
```

依赖只向下：事件层不实现策略，状态机不解析日志，策略层不决定转场状态，拓扑层不包含具体 SoC 的 CPU 编号。

## 各层职责

- `config.sh`：集中声明持久配置与运行时文件路径，提供默认值和数值读取边界。
- `runtime.sh`：日志、序号、进程树生命周期和 cgroup 读写原语。
- `topology.sh`：从在线 CPU、cpuset 与 `cpu_capacity` 推导 all/perf/mid/little mask，并缓存输入拓扑。
- `launcher-policy.sh`：发现五类 Launcher 线程，保存原始 affinity，批量调用原生线程控制器并精确恢复。
- `frequency-policy.sh`：可选小核限频的所有权事务。目标相对硬件上限计算，恢复前检查当前值仍由模块持有。
- `process-policy.sh`：source/pending source 记录、来源 affinity 事务、top-app/background cgroup 和辅助进程恢复。
- `state-machine.sh`：维护 `app/entering/home/recents/leaving` 转移及丢失完成事件的超时兜底。
- `events.sh`：把严格筛选的 Launcher 日志事件映射为状态机调用。

## 热路径

`launcher-logwatch` 收到真正的 Launcher 动画起点后，先调用 `source-affinityctl`，再写来源 PID 到 background cpuset/cpuctl，最后才向 shell 输出事件。事件中带有原生事务结果：三项全部成功时，shell 只做状态记录、Launcher 策略和后续状态转移；任一项失败才重新执行来源退避作为修复。

空闲时原生读取器睡眠在 logd，shell 睡眠在管道读取。WebUI 是按需命令，不存在后台 Web 服务。

## 恢复不变量

- 稳定 `app` 状态的当前应用最终位于 `top-app`，并恢复其逐 TID affinity。
- pending target 永远不会被当作 source 退避。
- Launcher 线程恢复时优先使用启动前快照；启动后才出现的线程恢复到动态默认集合。
- 频率值仅在仍等于模块写入值时恢复，避免覆盖第三方调度器。
- 服务重载和模块卸载走同一组恢复函数，不维护第二套补丁逻辑。

## WebUI

`webroot/js` 使用浏览器原生 ES Modules，不引入框架运行时或打包器：

- `bridge.js` 是唯一 KernelSU 命令边界；
- `model.js` 只转换后端数据；
- 三个 `*-view.js` 只渲染各自页面；
- `navigation.js` 只处理底栏和水平手势；
- `main.js` 负责请求去重和页面生命周期。

后端 `webui.sh` 只分派固定动作。配置使用命名 token，未知键、非法枚举和越界整数都会在写入前被拒绝。

持久设置位于 `/data/adb/hyperos4-launcher-scheduling`，不与 `/data/adb/modules/<id>` 中的可替换程序文件混放。首次启动 5.0 时，`config.sh` 会迁移旧目录中的已知配置键并删除对应旧副本；运行快照仍留在模块运行目录，由服务重载和卸载恢复函数管理。
