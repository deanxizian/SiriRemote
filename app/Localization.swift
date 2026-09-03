import Foundation

/// SiriRemote follows the first macOS preferred language. Chinese locales use the compact Chinese
/// copy below; every other locale falls back to the English source string.
enum AppLocalization {
    static var usesChinese: Bool {
        guard let identifier = Locale.preferredLanguages.first?.lowercased() else { return false }
        return identifier == "zh"
            || identifier.hasPrefix("zh-")
            || identifier.hasPrefix("zh_")
    }
}

private let chineseStrings: [String: String] = [
    // Sidebar and shared status
    "Touch": "触摸",
    "Controls": "控制",
    "Voice": "语音",
    "Permissions": "权限",
    "Connected": "已连接",
    "Not Connected": "未连接",
    "Accessibility Permission Required": "需要辅助功能权限",
    "Restoring Input…": "正在恢复输入通道",
    "A second remote was ignored": "已忽略第二只遥控器",

    // Permissions
    "System Permissions": "系统权限",
    "Accessibility": "辅助功能",
    "Authorized": "已授权",
    "Authorization Required": "需要授权",
    "Open System Settings": "打开系统设置",
    "Startup": "启动",
    "Open at Login": "开机自启动",
    "Awaiting System Approval": "等待系统批准",
    "Configuration": "配置",
    "Couldn’t Change Open at Login": "无法更改开机自启动",
    "OK": "好",
    "Unknown Error": "未知错误",
    "Configuration file could not be read: %@": "配置文件无法读取：%@",

    // Touch
    "Switches": "开关",
    "Trackpad": "触控板",
    "Circular Scroll": "外圈滚轮",
    "Speed": "速度",
    "Pointer Speed": "指针速度",
    "Scroll Speed": "滚动速度",
    "Restore Defaults": "恢复默认设置",

    // Fixed controls
    "Button Actions": "按键功能",
    "Power Button": "电源键",
    "Lock Screen": "锁定屏幕",
    "TV Button": "TV 键",
    "Hold to switch apps; use Left/Right to choose": "按住切换 App；左右选择",
    "Center Button": "中心键",
    "Return": "回车",
    "Back Button": "返回键",
    "Delete (hold to repeat)": "删除（长按连续删除）",
    "Up / Down / Left / Right": "上 / 下 / 左 / 右",
    "Arrow Keys": "方向键",
    "Play/Pause Button": "播放 / 暂停键",
    "Play or pause media": "播放或暂停媒体",
    "Mute Button": "静音键",
    "Mute or unmute": "静音或取消静音",
    "Volume Up/Down Buttons": "音量加 / 减键",
    "Adjust system volume": "调节系统音量",
    "Voice Button": "语音键",
    "Tap to send; hold for voice input": "单击发送；按住语音输入",

    // Voice connections
    "Connections": "连接",
    "Apple TV Remote": "Apple TV 遥控器",
    "Installed": "已安装",
    "Installation Required": "需要安装",
    "Get": "获取",
    "Doubao Input Method": "豆包输入法",
    "Not Detected": "未检测到",
    "View Permissions": "查看权限",
    "Bluetooth Settings": "蓝牙设置",
    "Not Installed": "未安装",
    "Not Enabled": "未启用",
    "Enabled": "已启用",
    "Download": "下载",
    "Open Settings": "打开设置",

    // Menu bar
    "Remote: Not Connected": "遥控器：未连接",
    "Accessibility: Checking…": "辅助功能：检查中…",
    "Accessibility: Authorized ✓": "辅助功能：已授权 ✓",
    "Accessibility: Authorization Required": "辅助功能：需要授权",
    "Remote: Temporarily Unavailable": "遥控器：暂不可用",
    "Remote: Connected ✓": "遥控器：已连接 ✓",
    "Open SiriRemote": "打开 SiriRemote",
    "Quit SiriRemote": "退出 SiriRemote",

    // Standard application menus
    "About SiriRemote": "关于 SiriRemote",
    "Services": "服务",
    "Hide SiriRemote": "隐藏 SiriRemote",
    "Hide Others": "隐藏其他",
    "Show All": "全部显示",
    "Edit": "编辑",
    "Undo": "撤销",
    "Redo": "重做",
    "Cut": "剪切",
    "Copy": "拷贝",
    "Paste": "粘贴",
    "Select All": "全选",
    "Window": "窗口",
    "Close Window": "关闭窗口",
    "Minimize": "最小化",
    "Zoom": "缩放",
    "Bring All to Front": "前置全部窗口",
]

func L(_ english: String) -> String {
    guard AppLocalization.usesChinese else { return english }
    return chineseStrings[english] ?? english
}

func L(_ english: String, _ arguments: CVarArg...) -> String {
    String(format: L(english), arguments: arguments)
}
