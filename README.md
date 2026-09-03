# SiriRemote

[![CI](https://github.com/deanxizian/SiriRemote/actions/workflows/ci.yml/badge.svg)](https://github.com/deanxizian/SiriRemote/actions/workflows/ci.yml)

SiriRemote 是一款面向 **Apple TV Siri Remote 第三代（A2854）** 的 macOS 菜单栏应用。
它把遥控器变成 Mac 的触控与按键控制器，并将遥控器实体麦克风接入豆包输入法。

项目以精简和稳定为目标：按键采用固定布局，不包含云端转写、API Key、按键映射、
Layer、App Wheel、Shell 或 AppleScript 等扩展功能。

这是非官方社区项目，与 Apple 或字节跳动无隶属关系。触控和遥控器语音依赖未公开的
macOS/蓝牙接口，升级系统前请保留可用安装包和卸载包。

## 功能概览

- 触摸板移动指针、轻触左键、双指手势和多显示器边缘处理。
- 外圈圆周滚动，可与触摸板分别开启或关闭。
- 固定的方向键、媒体键、锁屏、连续删除和 App 切换操作。
- Siri 键支持短按 Return 和按住说话两种手势。
- A2854 实体麦克风通过 `Siri Remote Mic` 输入豆包语音。
- 自动发现同一遥控器公开的多个 HID Interface，并在断连、睡眠、权限撤销或退出时
  释放鼠标键、Command、Fn 和所有延迟动作。
- 原生菜单栏运行；关闭主窗口后隐藏 Dock 图标，应用继续在后台工作。

SiriRemote 只接受 Apple VID `0x004C`、PID `0x0315`。当前版本只接管一只 A2854；
检测到第二只遥控器时会提示并忽略其输入。

## 系统要求

| 项目 | 要求 |
| --- | --- |
| macOS | macOS 13 Ventura 或更高版本 |
| 遥控器 | Apple TV Siri Remote 第三代 A2854（USB-C） |
| 蓝牙 | 遥控器已在 macOS 蓝牙设置中配对并连接 |
| 权限 | SiriRemote 的“辅助功能”权限 |
| 语音输入 | 已安装并启用豆包输入法 |
| 蓝牙语音采集 | Apple PacketLogger，位于 `/Applications/PacketLogger.app` |
| 安装 | 管理员权限，用于安装 Capture 服务和 CoreAudio HAL 驱动 |

“输入监控”不是本项目的独立权限要求，设置页不会显示或请求它。

## 安装与首次配置

### 1. 配对遥控器

先在“系统设置 → 蓝牙”中配对 A2854，并确认它处于已连接状态。

### 2. 安装 PacketLogger

从 Apple Developer 下载
[Additional Tools for Xcode](https://developer.apple.com/download/all/?q=Additional+Tools+for+Xcode)，
将其中的 `PacketLogger.app` 放到 `/Applications`：

```text
/Applications/PacketLogger.app
```

PacketLogger 是 Apple 工具，不随 SiriRemote 安装包分发。普通触控和按键不依赖它，
只有遥控器语音需要它。

### 3. 安装 SiriRemote

双击本地构建产物：

```text
dist/out/SiriRemote-Full-Setup.pkg
```

安装包会安装以下本项目组件：

```text
/Applications/SiriRemote.app
/Library/Audio/Plug-Ins/HAL/SiriRemoteAudio.driver
/Library/Application Support/SiriRemote/
/Library/LaunchDaemons/com.deanxi.siriremote.capture.plist
```

每次启动 SiriRemote 都会打开主窗口。关闭窗口后应用仍在菜单栏运行；点击菜单中的
“打开 SiriRemote”可重新打开窗口，使用 Command-Q 或菜单中的“退出 SiriRemote”才会结束应用。

### 4. 授予辅助功能权限

进入 SiriRemote 的“权限”页，点击未授权的“辅助功能”状态行，然后在系统设置中打开权限。
权限开启后应用会自动恢复输入链路；如果 macOS 保留了旧的 HID 授权状态，SiriRemote 会安全
释放全部输入并自动重启一次，不需要手工退出重开。

### 5. 配置豆包输入法

1. 在“系统设置 → 键盘 → 输入法”中安装并启用豆包输入法。
2. 在豆包输入法的麦克风设置中选择 **Siri Remote Mic**。
3. 在任意可编辑文本框中测试遥控器 Siri 键。

SiriRemote 不会修改 macOS 默认输入设备。开始语音时，如果当前不是豆包输入法，应用只会
切换一次到豆包，等待前台文字输入上下文生效后再按下 Fn；语音结束后保持豆包，不切回原输入法。

## 固定按键布局

| 遥控器操作 | Mac 行为 |
| --- | --- |
| 电源键 | 锁定屏幕（Control-Command-Q） |
| 返回键 | Delete；按住 350 ms 后每 80 ms 连续删除 |
| TV 键按住 | 保持 Command-Tab App 切换器 |
| TV 按住时按左 / 右 | 在 App 切换器中向前 / 向后选择 |
| 松开 TV 键 | 释放 Command，确认当前选择 |
| 中心实体键 | Return |
| 触摸板轻点 | 鼠标左键；仅在“触摸板”开启时生效 |
| 上 / 下 / 左 / 右 | 对应方向键 |
| 播放 / 暂停 | 系统播放 / 暂停 |
| 静音 | 系统静音 |
| 音量加 / 减 | 系统音量加 / 减 |
| Siri 键 | 短按 Return，按住调用豆包语音 |

电源键只能锁定或唤醒锁屏界面，第三方应用不能绕过密码、Touch ID 或系统认证来解锁 Mac。

### Siri 键手势

| 手势 | 行为 |
| --- | --- |
| 短按后松开 | 立即发送 Return |
| 按住至少 200 ms | 开始按住说话；松开后结束录音 |

第一次按下时会预热采集链路，但只有同一次物理按压达到 200 ms 后才会真正发送 Fn down。
短按不会打开豆包语音。采集或音频在 1.5 秒内未准备好时，会安全中止并释放 Fn。

## 设置窗口

设置窗口分为四页：

- **触摸**：触摸板开关、外圈滚轮开关、带档位的指针和滚动速度，以及恢复默认设置。
- **控制**：查看当前固定按键布局。
- **语音**：显示 A2854、Apple PacketLogger 和豆包输入法状态；仅在异常时提供对应跳转。
- **权限**：显示辅助功能授权状态、设置开机自启动，并在权限缺失时打开正确的系统设置页面。

触摸板关闭后，指针、轻触、拖动和双指手势全部停止；外圈滚轮仍由自己的开关独立控制。
关闭触摸、遥控器断连、Mac 睡眠或应用退出时，未完成的鼠标操作会立即清理。

## 语音链路

```text
A2854 实体麦克风
→ Bluetooth HCI 数据
→ PacketLogger 会话文件（.pklg）
→ ACL / L2CAP / ATT 重组与语音帧校验
→ Opus 解码
→ 48 kHz 单声道 PCM
→ 双声道共享 Ring
→ Siri Remote Mic
→ 豆包输入法
```

PacketLogger 本身不负责“解密”语音。它只记录蓝牙控制器看到的 HCI 数据；SiriRemote 的
解析器从捕获文件中重组 ACL/L2CAP/ATT Notification，识别当前语音通道和帧序列，校验
Opus TOC 后解码成 PCM。虚拟麦克风再把单声道数据复制为左右双声道，提供给豆包输入法。

豆包语音启动前，应用会选择已经启用的豆包输入法，并通过 CGEvent 发送真实配对的
Fn down/up。Siri 键松开后仍接收约 80 ms 的迟到帧，并最多等待 750 ms 让虚拟麦克风读完
已经写入的数据，减少首字和尾音被截断的情况。

### 后台组件

| 组件 | 作用 | 空闲行为 |
| --- | --- | --- |
| `SiriRemote.app` | HID、触控、按键、设置和豆包会话协调 | 常驻菜单栏 |
| `SiriRemoteCapture` | 系统级 Capture 服务，管理固定采集流程 | 常驻但不启动重型采集 |
| Apple PacketLogger | 捕获 A2854 的蓝牙 HCI 数据 | 不运行 |
| `SiriRemoteAudioRouter` | 解析 `.pklg`、解码 Opus、写共享 Ring | 不运行 |
| `SiriRemoteAudio.driver` | 向 CoreAudio 发布 `Siri Remote Mic` | 无生产者时输出静音 |

PacketLogger 和音频路由器只在真实 Siri 语音会话有 demand 时启动。仅仅打开豆包、枚举
虚拟麦克风或保持 SiriRemote 空闲，不应启动采集链路。

## 权限与异常恢复

- 撤销辅助功能权限时，应用先停止触摸和 HID 输入，再强制释放 mouseUp、Fn、Command、
  Delete 重复计时器及所有待执行手势，避免系统输入卡在按下状态。
- 重新授权后会自动重新建立遥控器检测；如果进程级 HID 授权仍旧失效，只自动重启一次。
- 断连、睡眠、PacketLogger 或路由器异常、权限丢失和应用退出都会使当前语音 generation
  失效，并关闭采集 demand。
- Capture 服务只执行固定的 SiriRemote 工作流，不接受调用方提供任意命令、UID 或路径。
- Capture 服务不会以 root 直接执行用户可写的 `/Applications/PacketLogger.app`。它只在本机
  创建 root 拥有的工作副本，移除来源 ACL，并在每次启动采集前验证 Apple 签名、
  Bundle ID、文件所有权和写权限；Apple 更新原版后会按 App 与命令行组件的签名身份自动
  刷新工作副本，验证失败时拒绝启动语音采集。
- 语音采集的临时文件位于 `/private/var/run/com.deanxi.siriremote/`，会在会话结束后清理。

## 常见问题

### 顶部显示“未连接”

确认遥控器是 A2854、蓝牙中显示已连接，并检查 SiriRemote 的辅助功能权限。语音页在确实
未检测到遥控器时会提供“蓝牙设置”入口；权限缺失时会改为引导到“权限”页。

### 已连接，但触控或按键没有反应

检查辅助功能权限。若刚刚重新授权，等待 SiriRemote 自动恢复或自动重启一次。不要同时运行
多个 SiriRemote 副本，也不要从项目目录直接启动另一个 App bundle。

### 按 Siri 键没有出现豆包语音界面

确认：

1. 当前有可接收文字的输入框焦点。
2. 豆包输入法已在系统输入法列表中启用。
3. `PacketLogger.app` 位于 `/Applications`。
4. 按住 Siri 键超过 200 ms。

### 豆包界面出现，但没有波形或无法识别

在豆包输入法中确认麦克风为 **Siri Remote Mic**，再查看语音页中的 A2854、PacketLogger
和豆包输入法状态。`Siri Remote Mic` 无生产者时会正确输出静音，因此“设备可见”并不等于
遥控器音频已经到达。

### 查看诊断日志

```sh
log stream --level debug --predicate 'subsystem == "com.deanxi.siriremote"'
sudo tail -f /Library/Logs/SiriRemote/capture.log
```

查看语音相关进程：

```sh
pgrep -fl 'SiriRemote|packetlogger|SiriRemoteAudioRouter|SiriRemoteCapture'
```

空闲时不应存在 PacketLogger 或 `SiriRemoteAudioRouter` 进程。

## 卸载

双击：

```text
dist/out/SiriRemote-Complete-Uninstall.pkg
```

卸载包会删除 SiriRemote App、HAL 驱动、Capture 服务、LaunchDaemon、当前控制台用户的
配置、偏好和日志，并恢复安装前的 MobileBluetooth `HCITraces` 原始值。卸载过程中系统音频
和蓝牙服务会短暂重启。

卸载器不会删除 PacketLogger、SiriRemoteForge、remote-mic-app、`MiRemoteV 2ch` 或其他
项目的虚拟音频设备。

## 构建与验证

### 完整本地安装包

```sh
dist/build-release.sh 0.1.0
```

该命令会依次运行 Core 测试、构建 App、路由器、HAL 和 Capture 服务，完成签名、打包与
内容审计。输出位于 `dist/out/`：

```text
SiriRemote-Full-Setup.pkg
SiriRemote-Complete-Uninstall.pkg
SHA256SUMS.txt
```

### 本机开发验证

```sh
./script/build_and_run.sh --verify
```

这个入口会：

1. 运行 SwiftPM 测试并构建 App。
2. 使用稳定身份 `Developer ID Application: ZIAN XI (96M7FW2XLU)` 签名。
3. 拒绝 ad-hoc 签名或签名校验失败的 bundle。
4. 通过 Installer 替换 `/Applications/SiriRemote.app`。
5. 启动并确认系统中只有一个来自该路径的 SiriRemote UI 进程。

实时测试只使用 `/Applications/SiriRemote.app`，不要直接运行 `app/SiriRemote.app` 或其他
项目内 bundle，以免 TCC 权限、进程状态和实际测试版本不一致。

仅运行 Core 单元测试：

```sh
(cd SiriRemoteCore && swift test)
```

App 使用 Developer ID Application 证书签名，但为兼容私有 `MultitouchSupport.framework`
不启用 Hardened Runtime；Capture 服务、音频路由器和 HAL 驱动启用 Hardened Runtime。
当前 PKG 没有 Developer ID Installer 签名，因此属于本机安装包，不承诺公证或公开分发。

## 仓库结构

```text
SiriRemote/
├── SiriRemoteCore/     纯 Swift 状态机、配置模型和单元测试
├── app/                macOS App、HID、触控、固定按键、豆包协调与设置 UI
├── mic/
│   ├── captured/       按需 Capture LaunchDaemon
│   ├── router/         PacketLogger tail、协议解析、Opus 解码和 Ring 写入
│   └── driver/         Siri Remote Mic CoreAudio HAL
├── dist/               完整安装、卸载、看门狗和包审计
└── script/             稳定签名的本机开发安装入口
```

## 已知边界

- 仅支持 A2854，不兼容旧款 Apple TV 遥控器或其他蓝牙遥控器。
- 只接管一只物理遥控器。
- 按键布局固定，当前版本不提供自定义映射。
- 触控依赖私有 `MultitouchSupport.framework`，因此不适合 Mac App Store 沙盒分发。
- 遥控器语音依赖 Apple PacketLogger 和未公开的蓝牙语音协议，macOS 更新可能影响兼容性。
- 不提供内置麦克风回退、监听播放、云端转写或独立语音识别服务。

## 许可证与来源

项目采用 **GPL-3.0-only**。SiriRemote 直接派生自
[`SiriRemoteForge v0.2.0-beta.8`](https://github.com/HOLODATA-COM/SiriRemoteForge/releases/tag/v0.2.0-beta.8)
commit `781a738ef3402c3c5eea5e2faa4ae53c9e4ffbc5`。

上游关系与参考来源：

- [`machinarii/hypervibe`](https://github.com/machinarii/hypervibe) commit
  `1e7746aabb22636df3f6410fcb2c92bb9e2217ab`：HID、触控和控制层来源。
- [`HD838A/remote-mic-app`](https://github.com/HD838A/remote-mic-app) commit
  `b233a88cc4457b00413dda6b37ec8b4af12c5121`：TIS 与 Fn 生命周期的行为参考；未复制其图标或
  专有资源。
- [BlackHole](https://github.com/ExistentialAudio/BlackHole)：CoreAudio HAL 技术基线。
- [Opus](https://opus-codec.org/)：遥控器语音帧解码。

逐文件来源和改动见 [`SOURCE_PROVENANCE.md`](SOURCE_PROVENANCE.md)，第三方声明见
[`NOTICE`](NOTICE)，完整许可证见 [`LICENSE`](LICENSE)。

提交改动前请阅读 [`CONTRIBUTING.md`](CONTRIBUTING.md)；安全问题请按
[`SECURITY.md`](SECURITY.md) 私下报告，不要在公开 Issue 中上传蓝牙抓包或敏感日志。
