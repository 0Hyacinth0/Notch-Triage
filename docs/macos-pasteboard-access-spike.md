# macOS Pasteboard Access Spike

日期：2026-08-10
验证环境：macOS 27.0 (26A5388g)，Xcode 27 beta (27A5228h)

## 结论

Clipboard History 不能在应用启动后默认读取 `NSPasteboard.general`。第一版必须显式关闭，只有用户主动点击“启用剪贴板历史”后才开始监控。

Apple 在当前 AppKit 中已提供 `NSPasteboard.accessBehavior`：

- `.default`：General pasteboard 的程序化读取默认会询问用户；应用在首次告警前不会出现在对应的系统设置面板。
- `.ask`：程序化读取时询问用户。
- `.alwaysAllow`：自动允许。
- `.alwaysDeny`：自动拒绝；只有由用户发起且被系统识别为粘贴的操作仍允许。

系统只在读取不是由系统认定的 paste-related UI 操作引起时显示告警。后台 Clipboard History 的周期性读取属于程序化读取，因此不能借用“用户点击粘贴”的例外。

参考：

- [AppKit updates — macOS pasteboard privacy](https://developer.apple.com/documentation/updates/appkit)
- [`NSPasteboard.AccessBehavior`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum)
- [`NSPasteboard.accessBehavior`](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-86972)
- [`NSPasteboard.changeCount`](https://developer.apple.com/documentation/appkit/nspasteboard/changecount)
- [Pasteboard detection patterns and metadata](https://developer.apple.com/documentation/appkit/nspasteboard-detection-patterns)

## 本机验证

在本机 SDK 上执行了不读取内容的最小探针：

```text
accessBehavior=alwaysAllow
changeCountReadable=true
contentReadAttempted=false
```

这个 `.alwaysAllow` 结果属于执行探针的开发工具进程，不代表 Notch Triage 的最终 per-app 状态。可确认的边界是：

- 读取 `changeCount` 可用于低成本检测所有权变化；它不需要获取剪贴板正文。
- 本次不读取、不输出、不保存当前剪贴板内容，也没有更改用户的 per-app 剪贴板权限。
- 本机“系统设置 → 隐私与安全”尚未显示剪贴板分类，与 Apple 所述“只有应用首次触发访问告警后才出现”一致。
- 第一次真实正文读取必须放在 Clipboard History 的显式启用流程内，不在技术探针中提前弹窗或更改权限。

## 实施约束

1. 设置页先说明会读取纯文本、图片和本地文件 URL，以及无法可靠识别所有密码或令牌的限制。
2. 用户确认启用后先读取 `accessBehavior`，再开始 monitor；`.alwaysDeny` 时显示受阻状态和系统设置指引。
3. 监控循环只轮询 `changeCount`；只有值变化时才读取白名单类型。
4. 在可以满足需求时优先使用 `detectedPatterns` / `detectedMetadata`，因为 Apple 明确说明这些检测不会通知用户；它们不能替代获取历史正文所需的真实读取。
5. 关闭 Clipboard History、删除历史和清空历史都不得调用 `NSPasteboard.clearContents()`；只有用户明确执行“再次复制”时才可替换 general pasteboard。

## Phase 3 发布门槛

- 用新的 Notch Triage 测试 bundle ID 从 `.default` 开始，在产品的显式启用按钮后验证首次系统告警。
- 分别验证 `.ask`、`.alwaysAllow` 和 `.alwaysDeny`，以及从系统设置返回 App 后的即时刷新。
- 验证未启用时不创建 timer、不读取正文，退出/锁屏/休眠后不留监控任务。
- 验证密码管理器已知 concealed/transient UTI，并在 README 中保留“无法识别所有第三方秘密内容”的明确限制。
