# 轻载小核限频 A/B

## 变量

设备为 Sheng，测试应用为 Android 设置。`IplrVkFenceWait`、UI、Raster、Rust 和 ResMgr 在全部样本中保持相同的中核/性能核放置，唯一变量是转场期 policy0 限频开关。

为排除第三方调度干扰，测试期间暂时停止 Scene/Vtools 服务，并将 policy0 上限恢复到硬件上限 2016000 kHz。测试结束后恢复原来的 307200 kHz 和 Vtools 服务。每个样本执行五轮进入最近任务与返回应用，顺序为：

```text
不限频 → 78% 限频 → 78% 限频 → 不限频
```

## FrameTimeline

| 样本 | Launcher 平均帧 | Launcher 最大帧 | Launcher Full | SurfaceFlinger Full | SystemUI Full + Partial |
| --- | ---: | ---: | ---: | ---: | ---: |
| 不限频 1 | 7.234 ms | 22.700 ms | 2 | 6 | 17 |
| 78% 1 | 7.957 ms | 28.835 ms | 3 | 8 | 13 |
| 78% 2 | 8.161 ms | 46.076 ms | 5 | 16 | 26 |
| 不限频 2 | 8.306 ms | 29.452 ms | 2 | 5 | 20 |

合并两次样本：

| 指标 | 不限频 | 78% 限频 |
| --- | ---: | ---: |
| Launcher 平均帧均值 | 7.770 ms | 8.059 ms |
| Launcher 最大帧均值 | 26.076 ms | 37.456 ms |
| Launcher Full jank | 4 | 8 |
| SurfaceFlinger Full jank | 11 | 24 |
| SystemUI Full + Partial | 37 | 39 |

两个测试顺序下，Launcher 和 SurfaceFlinger 的长尾都在限频时变差。SystemUI 汇总接近，说明变化主要发生在应用窗口到 Launcher/SurfaceFlinger 的交接链。

## 原因

轻载来源应用没有持续占用大量性能核，限频不能释放有意义的性能核预算。它仍需完成退出阶段的渲染、窗口快照、Buffer 提交和状态收尾；这些工作被限制到更低频的小核后，Launcher 虽然运行在 CPU3-7，仍会等待来源应用和显示链交付结果。

一次完整返回还会产生 `launcher-transition-start`、`launcher-exit-start` 和重复的 `app-resumed` 等事件。对同一 cpufreq policy 多次限制和恢复会增加频率切换的时序抖动。它在持续高负载或功耗控制场景中可能仍有价值，但目前没有改善帧时间的实测依据，因此正式默认值为关闭。
