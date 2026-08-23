# 高负载源应用进入最近任务时的增量卡顿

## 问题

轻载应用和高负载应用进入最近任务时都会执行同一套 Launcher 绘制、任务卡片合成、Floating Dock 绘制和任务快照。共同存在的工作只能解释最近任务动画的基础负载，不能解释高负载源应用为何明显更卡。

本次分析只比较高负载场景相对基线增加的工作。

## 同应用 A/B

为了排除应用类型、卡片内容、背景材质和任务快照内容的差异，A/B 两组都使用同一个金铲铲任务：

- Active：游戏正常运行，执行四轮三指上滑进入最近任务；
- Frozen：从卡片开始移动前暂停游戏进程，进入动画结束后立即恢复；
- 两组使用相同的 Launcher、相同任务、相同画面和相同操作时序；
- 只分析每轮手势开始到进入动画结束的区间。

暂停只是用于建立因果关系，不是最终模块方案。

## 结果

四轮进入动画的统计如下：

| 指标 | Active | Frozen | 差值 |
| --- | ---: | ---: | ---: |
| 源游戏 CPU Running | 5285.92 ms | 504.10 ms | +4781.82 ms |
| 源游戏 `queueBuffer` 次数 | 74 | 14 | +60 |
| 源游戏 `queueBuffer` 墙钟 | 143.37 ms | 5.87 ms | +137.50 ms |
| 源游戏最长 `queueBuffer` | 18.01 ms | 0.56 ms | +17.45 ms |
| 源游戏 `eglSwapBuffers` 次数 | 25 | 6 | +19 |
| Launcher Raster P95 | 10.87 ms | 9.16 ms | +1.71 ms |
| Launcher Raster 最大值 | 63.30 ms | 15.75 ms | +47.55 ms |
| Launcher Raster Runnable | 520.20 ms | 370.58 ms | +149.62 ms |
| Launcher UI Runnable | 625.82 ms | 459.61 ms | +166.21 ms |
| TaskSnapshot CPU Running | 981.78 ms | 968.88 ms | +12.90 ms |
| TaskSnapshot Runnable | 619.67 ms | 332.35 ms | +287.32 ms |

Active 组的主要源应用线程包括：

```text
UnityMain          3353.22 ms
Thread-103          415.07 ms
应用主线程          335.50 ms
UnityChoreographer  305.06 ms
AudioTrack          143.02 ms
NDK MediaCodec      135.02 ms
UnityGfxDevice       83.94 ms
```

当前模块的 CPU 退避基本生效。Active 组源应用约 5051.50 ms 的 CPU 时间落在 CPU 0–2，约 246.05 ms 落在 CPU 3–7。但 CPU 亲和只改变线程在哪些 CPU 上运行，不会停止 Unity 主循环，也不会阻止应用继续向共享 GPU 和 BufferQueue 提交工作。

## 结论

高负载场景增加的主要负载不是 Launcher 为游戏绘制了不同的卡片，也不是轻载场景不画背景、Dock 或小窗按钮。源游戏在已经缩成卡片后仍是活跃的图形生产者：

1. Unity 主循环和工作线程继续运行；
2. EGL 交换和 BufferQueue 提交继续发生；
3. GPU 与显示缓冲链路仍被源应用占用；
4. Launcher UI/Raster 和 TaskSnapshot 的计算本身没有增加同等规模，但 Runnable 排队明显增加；
5. 相同的最近任务绘制因此更容易超过 8.33 ms 帧预算。

暂停源应用后，Launcher Raster P95 和最长帧都明显下降，建立了源应用持续运行与增量卡顿之间的因果关系。

Frozen 组的 Raster P95 仍为 9.16 ms，说明最近任务主 Surface 的 HyperMaterial、Vulkan Encode 和任务快照仍构成基础负载；它们解释未完全消失的基线卡顿，不解释高负载相对轻载增加的部分。

## 后续优化方向

生产方案应在确认任务卡片开始移动后，短暂抑制源应用的产帧链路，并在动画完成后恢复。只修改 CPU affinity 不足以完成这一点。

可先以短时 cgroup freezer 做模块 A/B，验证对输入、Binder、音频、任务快照和应用恢复的影响。冻结区间必须严格限制在转场内，并设置超时恢复；直接长期发送 `SIGSTOP` 不适合作为正式方案。

