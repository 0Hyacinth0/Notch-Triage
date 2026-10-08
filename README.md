<div align="center">
  <img src="./assets/notch-triage-logo.png" alt="Notch Triage Logo" width="132" height="132">
  <h1>Notch Triage</h1>
  <p><strong>把 MacBook 刘海变成真正有用的系统状态与效率中心。</strong></p>
  <p>原生、轻量、常驻的 macOS 刘海工具，集中呈现系统状态，并提供文件暂存与隐私优先的剪贴板历史。</p>

  <p>
    <img src="https://img.shields.io/github/v/release/0Hyacinth0/Notch-Triage?style=flat-square&amp;color=25D9C5" alt="Latest release">
    <img src="https://img.shields.io/badge/macOS-26%2B-000000?style=flat-square&amp;logo=apple&amp;logoColor=white" alt="macOS 26+">
    <img src="https://img.shields.io/badge/Swift-5-F05138?style=flat-square&amp;logo=swift&amp;logoColor=white" alt="Swift 5">
    <img src="https://img.shields.io/badge/UI-Liquid%20Glass-4B5563?style=flat-square" alt="Liquid Glass">
  </p>

  <p>
    <a href="https://github.com/0Hyacinth0/Notch-Triage/releases/latest"><strong>下载最新版</strong></a>
    ·
    <a href="#核心能力">功能概览</a>
    ·
    <a href="#安装与首次运行">安装指南</a>
    ·
    <a href="https://github.com/0Hyacinth0/Notch-Triage/issues">问题反馈</a>
  </p>
</div>

---

## 核心能力

| 模块 | 能力 | 说明 |
| --- | --- | --- |
| 刘海交互 | 静止、圆环横向速览、悬停预览、点击展开 | 窗口锚定屏幕顶边连续变形，左右内容按实体刘海镜像布局 |
| AI 套餐用量 | 订阅额度、API 余额和消费 | 独立设置页管理平台与账户、连接状态、最后读取时间及刘海显示选择；支持 Codex、Claude Code、DeepSeek、Kimi、OpenRouter、MiniMax、OpenAI/Anthropic 组织消费与 Copilot 个人计费报告 |
| 系统 HUD | 音量、显示亮度、AirPods | 系统状态变化时以紧凑 HUD 进入刘海，展示完成后自动收起 |
| 媒体中心 | 正在播放、播放进度与基础控制 | 支持 Apple Music、Spotify、QQ 音乐、网易云音乐等系统媒体来源；可在面板中播放/暂停、上一首和下一首 |
| 歌词显示 | 刘海下方同步歌词、逐字动画与光效 | 独立设置页；支持渐进、波浪、程序坞放大，极光等四种光效预设，字体、字号、位置和同步偏移；可查询歌词或导入 LRC / YRC |
| 电源管理 | 电池健康、循环次数、实时功率 | 电池圆环可横向速览供电状态、电量与功率；完整面板展示适配器、系统与电池之间的功率流，并支持系统提供的充电上限档位 |
| 通知与废纸篓 | 实时横幅来源、可见通知中心来源、横幅处理、通知清理与废纸篓操作 | 通知桥展示本次运行观察到的横幅来源，以及通知中心打开时可识别的来源和数量，不保留正文；自动收起只处理横幅；清理通过辅助功能操作系统界面并复查“全部清除”控件，系统操作与本地记录分开；Widget Extension 不计入通知；危险操作需要用户明确确认 |
| 文件暂存架 | 拖入、拖出、打开、Finder 定位与会话暂存 | 最多保留 20 个本地文件或文件夹引用；清空只删除引用，不移动、复制或删除原文件 |
| 剪贴板历史 | 文本、图片与本地文件 URL | 默认关闭，用户明确启用后才监控；支持会话、1 天和 7 天保留期限，并可重新复制或随时清空 |
| 稳定性 | 节能调度、休眠感知、诊断面板 | 锁屏、熄屏或休眠时暂停非必要刷新，唤醒后自动恢复 |
| 更新 | GitHub Release 自动更新 | 下载后校验 SHA-256、Bundle ID、版本与签名 Team ID，再原子替换并重启 |

左右翼内容可以分别设置为电池状态、AI 套餐用量、正在播放或隐藏，也可以自由互换；配置会跨启动保存。

在“设置 → AI 套餐用量 → 刘海显示”中，可选择内外双弧、长弧＋底部短弧或左右双弧。默认保留内外双弧；长弧/左弧表示 5 小时剩余额度，底部短弧/右弧表示周剩余额度。选择即时生效并跨启动保存，悬停仍可查看精确数值。

额度消耗时，长弧与底部短弧都从右向左变暗；左右双弧都从上向下变暗。两项额度分别沿自己的固定轨道变化。

## 交互方式

1. **静止**：刘海保持紧凑，只呈现必要状态。
2. **圆环悬停**：媒体圆环横向展开播放控制；电池圆环横向展示供电状态、电量与实时功率。
3. **刘海悬停**：展开为无回弹的快速预览，精确数值和媒体信息随即出现。
4. **点击**：打开完整 Liquid Glass 工作区，在电源、通知、暂存和剪贴板四个分区间切换。
5. **离开**：点击桌面或其他 App 后自动收起；面板内菜单和确认弹窗不会误触关闭。

## 安装与首次运行

1. 前往 [Releases](https://github.com/0Hyacinth0/Notch-Triage/releases/latest) 下载最新发布包。
2. 将 `NotchTriage.app` 移入“应用程序”文件夹并启动。

> 如果“应用程序”中同时存在 `NotchTriage.app` 与旧的 `Notch Triage.app`，请先退出两者，再用最新版 `NotchTriage.app` 覆盖并移除旧的空格命名副本，避免同一 Bundle ID 启动两个实例。

3. 根据需要授予辅助功能、Finder 自动化、剪贴板访问或登录项权限。
4. 点击刘海区域打开面板；剪贴板历史保持默认关闭，只有点击“启用剪贴板历史”后才开始监控新内容。

> Notch Triage 当前定位为 GitHub / 官网分发的 macOS 工具，不面向 Mac App Store。

### 权限说明

| 权限 | 使用目的 | 是否必需 |
| --- | --- | --- |
| 辅助功能 | 识别系统横幅，并仅在系统提供安全取消动作时尝试收起 | 按需 |
| Finder 自动化 | 读取废纸篓聚合数量、执行经用户确认的清空操作 | 按需 |
| 登录项 | 使用系统 `SMAppService` 实现开机启动 | 可选 |
| 剪贴板访问 | 仅在用户启用 Clipboard History 后读取新复制的白名单内容 | 可选，默认关闭 |

应用不会安装 root helper。请求辅助功能权限前，面板会先完整收起，再打开系统设置；“修复权限”也只会重置 Notch Triage 自身的授权记录。

## 兼容性

| 项目 | 要求 |
| --- | --- |
| 最低系统 | macOS 26.0 |
| 推荐设备 | 带实体刘海的 MacBook 内建显示器 |
| 原生充电上限 | macOS 27.0 及系统支持的硬件；其他系统自动降级为只读电源监控 |
| Codex 额度 | 本机存在 Codex 或 ChatGPT 提供的 Codex 可执行文件，并已登录对应账户 |
| 完整通知能力 | 需要用户授予辅助功能权限 |

## 隐私与安全

- 通知桥只保存来源 App，不保存通知正文。
- 清除通知、清空废纸篓等操作必须由用户在面板中明确触发。
- 原生横幅仅在系统暴露 `AXCancel` 安全动作时尝试收起，否则保持原样。
- 更新包会校验摘要、Bundle ID、版本与签名身份，不直接执行未经验证的下载内容。
- Codex 通过本机已登录的 App Server 会话读取；应用不读取其登录令牌。其他平台的 API Key/Token 由用户添加并仅保存在本机钥匙串，余额与凭证不会写入诊断日志。
- Claude Code 状态栏桥接需要用户主动开启：先备份设置，保留已有状态栏输出，只同步额度、会话估算成本和更新时间；通过官方登录状态校验账户，关闭时恢复原配置。
- API 请求只使用各平台固定的官方 HTTPS 地址，不将凭证转发到其他域名。账户用量快照仅存内存；Claude 桥接缓存仅写本机应用支持目录。
- 文件暂存架只保存本地 URL 引用；移除或清空暂存架不会操作原文件。
- 剪贴板历史默认关闭，只记录纯文本、PNG/JPEG/TIFF 图片和本地文件 URL；已知 concealed、transient、自动生成及敏感声明会被跳过，但无法保证识别所有第三方密码或令牌。
- 会话模式不落盘；1 天和 7 天模式仅写入本机 Application Support。关闭监控、删除历史或清空历史都不会更改当前系统剪贴板。
- 诊断报告复制、文件复制和“重新复制”使用同一自写回抑制，不会被再次收录为新历史；剪贴板正文不会进入诊断日志或网络请求。
- 后台服务共享节能调度器；面板收起后自动降频，锁屏和休眠期间暂停非必要刷新。


### AI 套餐用量连接

- Codex 自动发现应用包的新旧布局、用户应用目录、PATH 及常见 CLI 安装位置，也支持手动指定路径；使用已登录的官方客户端，不需要复制 OAuth 凭证。
- Claude Code 需要 2.1.251+ 的 Pro/Max 账户；开启状态栏连接后，正常会话响应会同步数据。会话成本是估算值，不代表订阅余额。
- DeepSeek 和 Kimi 查询 API 钱包；Kimi 国内/国际 Key 与币种分别管理，不代表 Kimi Code 订阅。
- OpenRouter Management Key 查询账户余额，普通 API Key 查询该 Key 的预算和消费。
- MiniMax 使用 Token Plan 订阅 Key；仅使用平台明确返回的剩余百分比，其他计数按原字段展示，不猜测剩余额度。
- OpenAI/Anthropic 查询最近 30 天组织消费，需要管理级凭证；不是预付钱包。Copilot 查询个人购买许可的本月计费报告，不推算剩余额度。
- Gemini、GLM、Cursor 等平台尚未完成自动采集验证，当前未提供连接入口。
- 连接多个平台不会自动切换刘海显示账户。读取失败会标记旧数据；完整 Codex 响应和账户变化会清理不再有效的余额。

本地 `docs/`、截图、构建输出、日志及凭证文件不随源码提交或打包发布。

## 诊断与更新

诊断页统一展示媒体、通知、电源、Codex、更新和废纸篓的健康状态、最近检查时间与后台调度状态，并支持复制最近诊断报告。

应用启动时会检查 GitHub 最新 Release，常驻期间每 6 小时复查。临时网络失败会在 15 分钟后重试；更新界面会显示真实下载百分比、已下载大小、总大小以及签名和完整性验证状态。

## 开发构建

### 环境

- Xcode（需包含项目所用的 macOS SDK）
- Swift 5
- macOS 26.0 或更高版本

应用版本与 build number 统一维护在 [`Config/Version.xcconfig`](./Config/Version.xcconfig)；Xcode 配置和发布打包脚本都从这里读取。README 顶部的版本徽章跟随 GitHub 最新 Release 自动更新。

### 命令行构建

本项目可以使用独立的 Xcode Beta 构建，无需修改全局 `xcode-select`：

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project NotchTriage.xcodeproj \
  -scheme NotchTriage \
  -configuration Debug \
  -derivedDataPath /tmp/notch-triage-derived \
  build
```

Debug 构建使用 `com.hyacinth.notchtriage.debug`，正式 Release 使用 `com.hyacinth.notchtriage`，两者的辅助功能授权记录彼此独立。

### 自动化测试

使用 Xcode Beta 运行 macOS 单元测试：

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild test -project NotchTriage.xcodeproj \
  -scheme NotchTriage \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/notch-triage-tests
```

当前测试覆盖纯模型边界，不覆盖真实系统权限或更新安装流程。

### 分层 App 图标

应用图标由 [Icon Composer 文档](./NotchTriage/AppIcon.icon/icon.json) 构成，三个 SVG 图层随 `.icon` 包一同保存，保留 Default、Dark、Mono 和系统小尺寸渲染能力；圆角遮罩、折射、阴影与材质由系统生成，不预烘焙进源图。

<details>
<summary><strong>展开完整验证清单</strong></summary>

1. 用 Xcode 打开 `NotchTriage.xcodeproj`，选择 `NotchTriage` Scheme。
2. 首次运行时，在“系统设置 → 隐私与安全性 → 辅助功能”中允许调试版 App。
3. 播放 Apple Music、Spotify、QQ 音乐或网易云音乐，检查左翼曲目与实时推进的进度；在面板中逐一验证播放/暂停、上一首和下一首，并确认无媒体或播放器禁止跳过时按钮自动禁用。
4. 将鼠标移入连续黑色刘海区域检查悬停预览，再点击展开完整面板。
5. 点击桌面或其他 App，确认完整面板自动收起。
6. 在“设置 → AI 套餐用量”添加连接、查看状态并选择刘海显示账户；检查额度、余额/消费、最后读取时间和失败提示。
7. 打开 macOS 通知中心，确认面板只显示可识别的来源计数；默认情况下横幅保持显示，开启“自动收起横幅”后验证新横幅收起而来源记录保留。
8. 在通知中心有内容时执行“清理通知中心”，检查控件复查状态；再单独清除本次横幅记录，确认该操作不影响 macOS 通知中心。
9. 切换 80 / 85 / 90 / 95 / 100% 充电上限，验证系统返回状态；“充满”只应临时覆盖限制。
10. 分别更改左右显示内容，收起并重启 App，确认设置保留。
11. 检查音量、显示亮度与 AirPods 连接 HUD。
12. 在诊断页确认六项服务状态与最近检查时间更新，并测试复制诊断报告。
13. 启用“开机时启动”；如果系统要求批准，检查登录项设置入口。
14. 使用“设置与更新 → 退出 Notch Triage”正常结束应用。
15. 从 Finder 和至少两个第三方 App 拖入/拖出单个与多个文件，确认取消、失败和超限后面板不会卡在拖放状态，且原文件不受影响。
16. 在默认关闭状态确认 Clipboard History 不读取内容；启用后验证文本、图片和文件 URL、系统访问提示、重新复制、自写抑制、锁屏暂停、三种保留期限及“清空历史不清系统剪贴板”。

</details>

## 技术边界

- 系统级 Now Playing 通过随包分发的 BSD 3-Clause `MediaRemoteAdapter` 读取曲目、时长、时间锚点与播放速率，并在界面端推算实时进度；QQ 音乐的 AX 播放器节点只作为元数据与状态兜底。该实现适合官网分发，不适合直接提交 Mac App Store。
- Codex 美元余额是按 OpenAI 当前 `25 credits ≈ US$1` 关系换算的近似值；credits 原值来自本机 App Server，兑换关系变化时可能需要随版本更新。
- macOS 27 手动充电上限来自系统 PowerUI 接口；旧系统自动降级为只读监控。
- 通知中心没有公开的跨 App 通知数据库 API；本程序只通过辅助功能读取可见横幅和已打开通知中心中的可识别来源/数量，并通过其界面发起清理。macOS 的 AX 层级会随系统版本变化；清理后只能复查“全部清除”控件是否还显示，不能保证扫描到每条历史通知或证明系统历史已完全清空。
- 剪贴板敏感类型过滤基于已知声明和保守白名单，不能替代密码管理器自身的安全控制。
- 当前未加入窗口切换、自动清理通知中心历史记录或旧系统视觉降级。

## 项目链接

- [Releases](https://github.com/0Hyacinth0/Notch-Triage/releases) — 下载正式版本
- [Issues](https://github.com/0Hyacinth0/Notch-Triage/issues) — 报告问题与提出建议
- [Source](https://github.com/0Hyacinth0/Notch-Triage) — 浏览源代码

---

<p align="center">
  <strong>Notch Triage</strong><br>
  <sub>让原本占据空间的刘海，成为抬眼可见的效率中心。</sub>
</p>

### 歌词显示

设置中的“歌词显示”页提供字体、字号（8–120 点，可直接输入，长句保留字号并换行）、已唱与待唱颜色、光效强度，以及从左到右渐进、逐字光波和程序坞放大三种高亮形式。歌词悬浮在刘海下方，不接收鼠标事件；面板展开或屏幕锁定时隐藏。设置预览与实际歌词共用渲染组件，也可在刘海下方预览 30 秒。

启用后按播放器提供的歌名、歌手、专辑和时长筛选网易云音乐、QQ 音乐与 LRCLIB 的结果，优先使用 YRC、KLYRIC、QRC 等真实逐字时间轴；逐行缓存继续尝试升级。查询会发送歌名和歌手，不使用播放器账户凭证，原始歌词缓存保存在本机 Caches 目录。中文显示可选简体（默认）、繁体或保留原文，只转换显示文字，保留时间戳。支持导入 UTF-8 LRC、增强 LRC、YRC 和解码后的 QRC。只有逐行数据时默认整句显示，也可手动开启估算动画，但不能保证逐字同步；播放器没有提供进度时无法同步显示。第三方接口可能变更或限制访问，逐字准确度仍取决于匹配的歌曲版本和来源时间轴。

歌词光效提供极光、月光、暖金和清晰预设，可分别设置主色、尾色、柔光范围与呼吸。极光采用冰白字芯、青蓝至淡紫渐变和双层柔光；设置页的实时示意可暂停。两侧律动提供柔光频谱、流动波形和水波纹三种样式，围绕实际文字居中；距文字间隔、单侧宽度及高度独立调节。真实频谱通过 Core Audio Tap 分析系统输出音频的 14 个对数频段，首次启用需要系统音频权限；不使用麦克风，不保存或上传音频。歌词隐藏、播放暂停、锁屏或功能关闭时停止采集，无信号时静止。设置和刘海演示中的频谱明确为示意动画；系统减少动态效果会停止位移、放大、呼吸及律动。旧版歌词外观配置兼容保留，点击预设可应用新光效。

### 歌词组件许可

QQ QRC 解码器改编自 [MxIris-LyricsX-Project/LyricsKit](https://github.com/MxIris-LyricsX-Project/LyricsKit)，该文件按 MPL-2.0 提供；原始提交、修改说明与完整许可保存在 `NotchTriage/ThirdParty/LyricsKit/`。其他歌词接入与显示逻辑由本项目实现。
