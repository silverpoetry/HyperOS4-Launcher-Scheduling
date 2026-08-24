# Contributing

提交调度策略或兼容性变化时，请说明目标设备、HyperOS 版本、CPU 拓扑、复现操作和 A/B 结果。涉及亲和、
cgroup、uclamp 或 cpufreq 的修改应同时覆盖进入动画、取消、返回应用、服务重载和卸载恢复路径。

代码提交前运行：

```powershell
.\tools\Test-SourceLayout.ps1
.\build-module.ps1 -AndroidSdk 'C:\Android\Sdk'
```

诊断材料应先移除设备序列号、账号、完整 IP 地址、密钥和厂商专有文件。大型 Perfetto trace 可在 Issue 中
提供临时链接；仓库只保留支持结论所需的摘要与精简样本。
