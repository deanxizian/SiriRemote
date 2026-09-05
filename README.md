# SiriRemote

[![CI](https://github.com/deanxizian/SiriRemote/actions/workflows/ci.yml/badge.svg)](https://github.com/deanxizian/SiriRemote/actions/workflows/ci.yml)

[下载最新版本](https://github.com/deanxizian/SiriRemote/releases/latest) · [更新记录](CHANGELOG.md)

SiriRemote 是一款面向 **Apple TV Siri Remote 第三代（A2854）** 的 macOS 菜单栏应用，
提供 Mac 触控、固定按键控制，以及遥控器实体麦克风到豆包输入法的语音输入。

这是非官方社区项目，与 Apple 或字节跳动无隶属关系。触控和遥控器语音依赖未公开的
macOS/蓝牙接口，升级系统前请保留可用安装包和卸载包。

## 功能概览

- 触摸板指针、轻触左键、双指手势和独立开关的外圈圆周滚动。
- 固定的方向键、媒体键、锁屏、连续删除和 App 切换操作。
- Siri 键支持短按 Return 和按住说话两种手势。
- A2854 实体麦克风通过 `Siri Remote Mic` 输入豆包语音。
- 断连、睡眠、权限撤销或退出时自动释放鼠标键、Command、Fn 和延迟动作。
- 关闭主窗口后隐藏 Dock 图标，仅在菜单栏后台运行。

SiriRemote 只接受 Apple VID `0x004C`、PID `0x0315`。当前版本只接管一只 A2854；
检测到第二只遥控器时会提示并忽略其输入。

## 系统要求

| 项目 | 要求 |
| --- | --- |
| macOS | macOS 13 Ventura 或更高版本 |
| Mac 芯片 | Apple Silicon（发布包为 arm64，暂不提供 Intel 预编译包） |
| 遥控器 | Apple TV Siri Remote 第三代 A2854（USB-C） |
| 蓝牙 | 遥控器已在 macOS 蓝牙设置中配对并连接 |
| 权限 | SiriRemote 的“辅助功能”权限 |
| 语音输入 | 已安装并启用豆包输入法 |
| 蓝牙语音采集 | Apple PacketLogger，位于 `/Applications/PacketLogger.app` |
| 安装 | 管理员权限，用于安装 Capture 服务和 CoreAudio HAL 驱动 |

“输入监控”不是本项目的独立权限要求，设置页不会显示或请求它。

## 安装与首次配置

### 1. 配对遥控器

1. 给遥控器充电，打开“系统设置 → 蓝牙”并记住当前附近设备。
2. 将遥控器靠近 Mac，同时按住 **返回键（`<`）+ 音量加键**约 5 秒，使它进入配对状态。
3. 连接刚出现的设备。它常显示为序列号或不明显的名称，**不一定叫 `Siri Remote`**。
4. SiriRemote 显示“已连接”即已通过 Apple VID `0x004C`、PID `0x0315` 验证。

若没有新设备，按住 **TV/控制中心键 + 音量减键**约 5 秒重启遥控器，等待 5–10 秒后重试；
同时避免附近 Apple TV 抢先连接。组合键参见
[Apple 官方说明](https://support.apple.com/102569)。

### 2. 安装 PacketLogger

从 Apple Developer 下载
[Additional Tools for Xcode](https://developer.apple.com/download/all/?q=Additional+Tools+for+Xcode)，
将 `PacketLogger.app` 放到 `/Applications`。它不随 SiriRemote 分发，且只有遥控器语音需要。

### 3. 安装 SiriRemote

从项目的 [GitHub Releases](https://github.com/deanxizian/SiriRemote/releases) 下载同一版本的
三个文件：

```text
SiriRemote-0.2.0-Full-Setup.pkg
SiriRemote-0.2.0-Complete-Uninstall.pkg
SiriRemote-0.2.0-SHA256SUMS.txt
```

先在下载目录核对校验和：

```sh
shasum -a 256 -c SiriRemote-0.2.0-SHA256SUMS.txt
```

两个 PKG 均显示 `OK` 后再安装 Full Setup。PKG 使用
`Developer ID Installer: ZIAN XI (96M7FW2XLU)` 签名；包内 App、Capture 服务、音频路由器
和 HAL 驱动使用同一团队的 `Developer ID Application` 身份签名。当前发行包尚未完成 Apple
公证；若 macOS 阻止打开，请在尝试打开后进入“系统设置 → 隐私与安全”，在“安全性”中
选择“仍要打开”并完成管理员验证。不要关闭 Gatekeeper，也不要清除文件隔离属性。

从 0.1.0 升级请直接安装完整包，无需先卸载。0.2.0 更新了 App、Capture、路由器和音频驱动
之间的协议，不能只替换 App；现有配置保留，安装期间系统音频会短暂重启。

安装包会安装以下本项目组件：

```text
/Applications/SiriRemote.app
/Library/Audio/Plug-Ins/HAL/SiriRemoteAudio.driver
/Library/Application Support/SiriRemote/
/Library/LaunchDaemons/com.deanxi.siriremote.capture.plist
```

关闭主窗口后应用仍在菜单栏运行；从菜单栏重新打开，或用 Command-Q 完全退出。

### 4. 授予辅助功能权限

在 SiriRemote 的“权限”页点击未授权的“辅助功能”状态行并完成授权。应用会自动恢复输入；
若 macOS 仍保留旧 HID 授权状态，应用会安全释放输入并自动重启一次。

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

按下时会预热采集；达到 200 ms 才发送 Fn down，短按不会打开语音。1.5 秒内未准备好时
会安全中止并释放 Fn。

## 设置窗口

设置窗口分为四页：

- **触摸**：触摸板开关、外圈滚轮开关、带档位的指针和滚动速度，以及恢复默认设置。
- **控制**：查看当前固定按键布局。
- **语音**：显示 A2854、Apple PacketLogger 和豆包输入法状态；仅在异常时提供对应跳转。
- **权限**：显示辅助功能授权状态、设置开机自启动，并在权限缺失时打开正确的系统设置页面。

触摸关闭后，指针、轻触、拖动和双指手势停止，外圈滚轮仍由独立开关控制。

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

PacketLogger 只记录蓝牙 HCI 数据；SiriRemote 重组 ACL/L2CAP/ATT Notification、校验并
解码 Opus，再将单声道 PCM 复制为双声道交给虚拟麦克风。

应用切换到已启用的豆包输入法后发送配对的 Fn down/up；松开后等待最后一帧后的 80 ms
安静窗口（收尾上限 300 ms），再最多等待 750 ms 排空音频。收尾时再次按住 Siri 会保留
这次按下，上一句结束后接续新会话；新旧音频按 generation 隔离。

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
- App 与 Capture 通过校验签名、产品标识和 Team ID 的 XPC 通信，不信任通知中的 PID。
  PCM 仅供 root 和 CoreAudio 服务组访问，App 只读取诊断计数；停止时先撤销音频会话再回收进程。
- Capture 服务不以 root 直接运行 `/Applications/PacketLogger.app`；它使用 root 所有的工作
  副本，并在采集前验证 Apple 签名、Bundle ID、文件所有权和写权限。
- 语音采集的临时文件位于 `/private/var/run/com.deanxi.siriremote/`，会在会话结束后清理。

## 常见问题

### 顶部显示“未连接”

确认遥控器是 A2854、蓝牙中显示已连接，并检查 SiriRemote 的辅助功能权限。语音页在确实
未检测到遥控器时会提供“蓝牙设置”入口；权限缺失时会改为引导到“权限”页。

### 已连接，但触控或按键没有反应

检查辅助功能权限并等待自动恢复；不要同时运行多个 SiriRemote 副本。

### 按 Siri 键没有出现豆包语音界面

确认：

1. 当前有可接收文字的输入框焦点。
2. 豆包输入法已在系统输入法列表中启用。
3. `PacketLogger.app` 位于 `/Applications`。
4. 按住 Siri 键超过 200 ms。

### 豆包界面出现，但没有波形或无法识别

在豆包输入法中确认麦克风为 **Siri Remote Mic**，再检查语音页状态。设备可见不代表遥控器
音频已到达，因为虚拟麦克风在无生产者时会输出静音。

### 查看诊断日志

```sh
log stream --level debug --predicate 'subsystem == "com.deanxi.siriremote"'
sudo tail -f /Library/Logs/SiriRemote/capture.log
/Applications/SiriRemote.app/Contents/MacOS/SiriRemote --verify-capture
```

`--verify-capture` 只检查真实 App 与 Capture 的双向签名握手，不启动录音或发送按键。

查看语音相关进程：

```sh
pgrep -fl 'SiriRemote|packetlogger|SiriRemoteAudioRouter|SiriRemoteCapture'
```

空闲时不应存在 PacketLogger 或 `SiriRemoteAudioRouter` 进程。

## 卸载

双击：

```text
SiriRemote-0.2.0-Complete-Uninstall.pkg
```

卸载包会删除 SiriRemote App、HAL 驱动、Capture 服务、LaunchDaemon、当前控制台用户的
配置、偏好和日志，并恢复安装前的 MobileBluetooth `HCITraces` 原始值。卸载过程中系统音频
和蓝牙服务会短暂重启。

卸载器不会删除 PacketLogger、SiriRemoteForge、remote-mic-app、`MiRemoteV 2ch` 或其他
项目的虚拟音频设备。

## 构建与验证

### 完整本地安装包

```sh
dist/build-release.sh 0.2.0
```

该命令会依次运行 Core 测试、构建 App、路由器、HAL 和 Capture 服务，完成签名、打包与
内容审计。输出位于 `dist/out/`：

```text
SiriRemote-0.2.0-Full-Setup.pkg
SiriRemote-0.2.0-Complete-Uninstall.pkg
SiriRemote-0.2.0-SHA256SUMS.txt
```

### 本机开发验证

```sh
./script/build_and_run.sh --verify
```

该入口会测试、构建并使用稳定 Developer ID 签名，通过 Installer 更新
`/Applications/SiriRemote.app`，拒绝 ad-hoc 或无效签名，并确认只运行这一份 UI 进程。

实时测试只使用 `/Applications/SiriRemote.app`，不要直接运行 `app/SiriRemote.app` 或其他
项目内 bundle，以免 TCC 权限、进程状态和实际测试版本不一致。

该开发入口只更新 App。修改 Capture、Router、HAL 或共享 ABI 时，必须构建并安装完整包。
CI 同时覆盖实际豆包会话状态机、Capture 身份校验、Router/解析器、HAL 多客户端 I/O，
以及 ASan/UBSan 下的冷启动挂接、失效会话静音和尾音排空；不代替遥控器和豆包实机验收。

仅运行 Core 单元测试：

```sh
(cd SiriRemoteCore && swift test)
```

App 使用 Developer ID Application 证书签名，但为兼容私有 `MultitouchSupport.framework`
不启用 Hardened Runtime；Capture 服务、音频路由器和 HAL 驱动启用 Hardened Runtime。
两个 PKG 使用 Developer ID Installer 证书和可信时间戳签名；在实际完成 Apple 公证与装订
前，文档和 Release 不会将它们标记为已公证。

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

逐文件来源见 [`SOURCE_PROVENANCE.md`](SOURCE_PROVENANCE.md)，第三方声明见 [`NOTICE`](NOTICE)，
许可证见 [`LICENSE`](LICENSE)。贡献前请阅读 [`CONTRIBUTING.md`](CONTRIBUTING.md)；安全问题请按
[`SECURITY.md`](SECURITY.md) 私下报告。
