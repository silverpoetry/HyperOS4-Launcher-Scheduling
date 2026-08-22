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

## 静态与构建检查

- 所有模块 Shell 脚本通过 `sh -n`；
- `launcher-logwatch` 由 NDK arm64 编译并保留 C 源码；
- ZIP 根目录包含 KernelSU 脚本和 `bin/launcher-logwatch`；
- 源码不包含 blur 阈值、固定 CPU 编号、频率锁或前台轮询；
- `git diff --check` 通过；
- 构建产物生成 SHA-256 文件。

当前验证针对 Sheng 这一版 HyperOS 4 Launcher 日志协议。桌面大版本更新后应重新运行生命周期测试。
