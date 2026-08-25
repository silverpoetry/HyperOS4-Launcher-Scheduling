# 转场状态机

状态机区分 Activity 前台身份和 Launcher 是否参与可见转场。应用开始缩成卡片时，原应用仍可能保持 top-app；最近任务卡片展开为应用时，目标 Activity 也可能早于视觉动画完成恢复。只根据 resumed Activity 无法确定调度边界。

## 状态

| 状态 | 含义 |
|---|---|
| `app` | 应用视觉稳定，Launcher 不再参与转场 |
| `entering` | 应用正在缩放为桌面或最近任务卡片 |
| `home` | 桌面稳定显示 |
| `recents` | 最近任务稳定显示 |
| `leaving` | 卡片或桌面图标正在展开为应用 |

## 逻辑转场

### 应用进入桌面或最近任务

`gestureStart`、最近任务按键入口或 RemoteAnimation CloseApp 创建一个转场 ID。重复入口日志只确认同一操作，不增加序号。

协调器立即发送 `enter ID`。来源守卫约束此前稳定记录的应用，同时协调器应用 Launcher、SystemUI 和 system_server 线程策略。

`gestureToHome` 和 `enterOverviewState` 确认最终场景。进入期间出现的 Launcher resumed 只是 Launcher 获得前台的中间信号，不会把 `entering` 改写成 `home`。若最终场景日志缺失，入口兜底把 `entering` 收敛为 `recents`。线程策略在视觉稳定等待后恢复；来源应用继续留在专用控制组。

### 最近任务或桌面打开应用

`exitOverviewState` 或 opening remote animation 创建新的转场 ID。目标 Activity resumed 后分两种处理：

- 返回原来源卡片：发送 `handoff ID PACKAGE`，来源继续受限，直到动画完成；
- 打开另一张卡片：发送 `adopt ID PACKAGE`，旧来源恢复 nice 并留在系统 background，目标只登记为下一来源，整个展开动画中保持系统 top-app 策略。

同一目标的重复 resumed 日志不会把已登记但未压制的目标再次激活。

`openingRemoteAnimationClose` 和 `finish_remote_transition` 只表示协议层完成。协调器不会立即恢复目标应用，而是发送 `complete ID DELAY`。默认等待 450 ms，使卡片展开、WMShell leash、WindowManager 布局和最后几帧合成结束后再恢复 top-app。

若结束日志缺失，目标 resumed 时设置的完成超时负责收尾。后续正常结束日志会用较短的视觉稳定等待覆盖该超时。

### 手势取消

只有当前存在应用进入 Launcher 的手势会话时，`gestureToApp` 或 RemoteBack cancel 才表示取消。取消同样经过视觉稳定等待，不在第一条取消日志到达时立即恢复来源。

## 转场 ID

转场 ID 使用单调时钟纳秒值。守卫只接受不小于当前事务的身份更新，只对等于当前事务的完成命令设置定时器。

新转场开始时会取消旧完成定时器。由此保证：

- 旧目标不能覆盖新来源；
- 旧定时器不能在新手势中把应用放回 top-app；
- 同一操作的重复日志不会重复扫描线程或创建控制进程；
- 来源主进程重建只在包名、UID 和当前身份一致时接管。

## 活动转场复核

线程策略应用后，协调器默认每 20 ms 检查一次已缓存目标 TID。检查内容只有当前 affinity 和 uclamp；值未变化时不写入。系统覆盖目标设置时，下一轮只修正该线程。

复核在以下任一条件满足时停止：

- 桌面或最近任务稳定并经过视觉等待；
- 应用展开完成并经过视觉等待；
- 完成日志缺失但兜底超时到期；
- 服务重载、关闭或退出。
