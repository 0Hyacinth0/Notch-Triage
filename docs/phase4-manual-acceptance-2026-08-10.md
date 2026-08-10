# Phase 4 手工验收记录（2026-08-10）

## 环境

- macOS 27.0（26A5388g）
- Apple Silicon（Apple M1 Pro，arm64）
- 内建 Liquid Retina XDR 显示器，3024 × 1964 Retina
- Xcode 27.0 beta（27A5228h）
- Debug Bundle ID：`com.hyacinth.notchtriage.debug`
- 被测产物：从当前未提交工作树构建的临时 Debug App；验收完成后已退出并删除临时 DerivedData

## 已通过

### 刘海与 Workspace

- 紧凑刘海可正常出现，悬停后进入 74pt Peek，点击可打开完整 Workspace，未出现停止响应。
- Peek 中持续显示“展开详细面板”指引；完整 Workspace 可在电源、通知、暂存、剪贴板四段导航间切换。
- 旧能力仍可访问：电源与充电详情位于“电源”；通知、Codex、废纸篓和 Now Playing 位于“通知”。
- Workspace 收起、重新展开和跨 App 切换后仍能恢复正确 section。

### 设置窗口

- Workspace 齿轮可以打开标准设置窗口。
- 再次使用 `Command-,` 会激活现有设置窗口，没有观察到重复窗口。
- 切换“行为”与“权限”后，窗口标题分别更新为“Notch Triage 设置 — 行为”和“Notch Triage 设置 — 权限”。

### 文件暂存架

- 文件选择器显示“只保存文件引用；不会移动、复制或修改原文件”的边界说明。
- 选择本地测试目录后，Shelf 显示 `1/20`；重复选择同一路径不会新增副本，而是提示“1 项已置顶”。
- 正常退出并重新启动后，Shelf 恢复为 `0/20`，符合会话级保留语义。
- 验收前后测试文件及其嵌套文件均存在，大小和修改时间未变化。

### 剪贴板历史

- 默认关闭；设置页明确说明白名单与无法识别所有密码或令牌的限制。
- 显式启用后，界面显示“正在监控”和“macOS 已允许 Notch Triage 读取剪贴板”。
- 从 TextEdit 复制安全测试文本后，Workspace 捕获为一条文本记录，并显示字节数。
- 点击“重新复制”后历史仍为 `1/50`，自写回没有形成重复记录。
- “清空历史”先显示确认说明；清空后历史为 `0/50`，同一文本仍可从系统剪贴板粘贴到 TextEdit。
- 会话保留模式下，退出前的 `1/50` 在重新启动后恢复为 `0/50`；启用状态和“到 App 退出”保留策略继续保存。
- 启用前内容没有被补录；此前的静态审计未发现剪贴板正文进入诊断或网络路径，本轮没有做独立流量抓包。
- 从 Finder 复制本地 `large-noise.png` 后，Workspace 捕获为文件 URL 记录。
- 从 Preview 复制 9,013,625 bytes 的 2000 × 1500 PNG 后，Workspace 新增为 `9 MB` 图片记录；点击“重新复制”后记录数仍为 `2/50`。
- 在设置页选择“停止并保留”后，复制另一个 Finder 文件，历史仍为 `2/50`；重新启用后也没有补录关闭期间的内容。
- 真实 UI 还发现主面板的 `confirmationDialog` 在 nonactivating panel 上未正常呈现，点击“关闭”会使面板收起且未更改设置。源码已换为面板内嵌确认层，Debug 构建和 96 项测试通过；修复后视觉操作仍需下一次真实 UI 复验。

### 生命周期与清理

- 最终退出 Debug App 后，没有残留 `NotchTriage` 或 `mediaremote-adapter` 进程。
- Computer Use 启动的 TextEdit 已退出；自动保存的测试 RTF 已移动到废纸篓，可恢复。
- 临时构建目录、测试文件目录和 Finder 测试窗口均已清理。

### 空闲性能抽样

- Xcode Time Profiler 成功录制 10.875 秒，`potential-hangs` 与 `hang-risks` 均为 0。
- 主线程约 99% 时间在正常等待事件；112 个 1ms 主线程样本约等于 1% CPU，未发现持续热点。
- 录制后已退出 App 及 `mediaremote-adapter`，并删除 trace 与临时 DerivedData。
- 对真实 9 MB 图片复制路径另录制了 20.854 秒 Time Profiler：`potential-hangs=0`、`hang-risks=0`；961 个 1ms 活跃样本中剪贴板读取链命中 4 个样本，图片指纹/存储在后台任务中命中 1–2 个样本，未见持续主线程阻塞。
- Xcode 27 的 `Power Profiler` 在 macOS 上直接报错“仅支持 iOS/iPadOS”，因此不再将该模板当作 macOS 发行门槛。
- 改用 macOS `top` 对启用 Clipboard Monitor 的紧凑态 Debug App 做约 10 分钟资源趋势抽样：119 个五秒点，CPU 平均 1.48%、中位数 1.4%、P95 2.5%、峰值 3.3%；线程数始终为 7，内存约 65–67 MB。这是长时资源趋势，不冒充真实功耗估算；若要得到 SoC 能耗数据，需要管理员权限运行 `powermetrics` 或使用外部能耗工具。

## 自动验证基线

- 当前实现最近一次完整 XCTest：96 项通过，0 失败、0 跳过。
- Release generic macOS universal 构建通过；可执行文件包含 `x86_64` 与 `arm64`。
- `codesign --verify --deep --strict` 通过。
- `git diff --check` 通过。

## 后续仍需补充的硬件与权限验收

- Finder 真实拖入尝试受当前 Computer Use 跨窗口坐标限制影响，未成功落到 DropTarget；文件选择器通过不能替代拖放验收。
- 尚未完成 Finder 与至少两类第三方 App 的拖入/拖出、快速拖放、取消、partial/rejected/provider error、20 项超限和 nonactivating panel outside-click 矩阵。
- 当前机器只有一块内建显示器；外接显示器、显示器插拔、非主屏和无刘海屏幕未验收。
- 图片、文件 URL、自写回和关闭后不读取已完成真实验收；已知敏感声明、锁屏/休眠暂停及 1 天/7 天跨启动保留仍未完成。
- 本机已有剪贴板读取授权，因此本轮没有重新触发首次 pasteboard access alert，也没有覆盖“拒绝后重新检查”的路径。
- 已完成大图片 Time Profiler 和约 10 分钟 macOS 资源趋势抽样；`Power Profiler` 不支持 macOS，管理员权限的 `powermetrics`/SoC 能耗估算未执行。
- 主面板“关闭/清空剪贴板历史”的内嵌确认层修复尚未完成 Computer Use 复验。
- Workspace/Peek 曾采用 116pt 卡片式预览，并在收起时形成被压扁的两段残影。当前已按用户决定恢复 v26.8.4.2327 的 74pt 三栏 Peek、旧版 340ms + 320ms 收起时序与无按压高亮按钮；2026-08-10 使用本地源码构建和系统鼠标事件复验，按下前后截图像素一致，全程未启用 Computer Use。
- 尚未验证 Reduce Motion、真实通知、系统 HUD、QQ 音乐进度、充电上限、更新安装、DMG 挂载/回下载一致性。
- 本轮首次发布为 v26.8.10.2030；永久显示“点击展开”的后续修订发布为 v26.8.10.2043，DMG、Git tag 与 GitHub Release 均由独立发布步骤生成并校验。

## 下一轮建议顺序

1. 在真实 Finder 和第三方 App 中完成 Shelf 拖入/拖出矩阵，优先排除 DropTarget 卡住、outside-click 误收起和原文件变更。
2. 在重置剪贴板授权的隔离测试账户或虚拟机中覆盖首次允许、拒绝与重新检查；随后补图片、文件 URL、锁屏/休眠和持久保留。
3. 复验面板内嵌确认层；如需真实 SoC 能耗数据，在明确授权后用 `powermetrics`，再做外接显示器和 Reduce Motion。
4. 上述门槛全部通过后再生成时刻版本号、universal DMG，并核对 Release 回下载资产与本地包摘要。
