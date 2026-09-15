# MouseBattery for macOS / 鼠标电量

[English](#english) · [简体中文](#简体中文)

> **Unofficial utility.** This project is independently developed and is not affiliated with, endorsed by, or supported by TAIDU. “TAIDU” and “MC203” are used only to identify compatible hardware and may be trademarks of their respective owners.

## 简体中文

这是一个为我个人在 macOS 上随时查看 **TAIDU MC203 人体工学鼠标**电量、以便及时充电而制作的菜单栏小工具；现以开源形式分享给有相同需求的用户。

它仅支持已经实机验证的 MC203：

- 2.4G 接收器：USB `3554:F5D5`
- USB 有线模式：USB `3554:F511`
- macOS 13 或更高版本，Apple Silicon（arm64）

本项目**不支持蓝牙**、键盘或其他钛度鼠标。请不要把相同或相近 USB ID 当作兼容性证明；不同品牌、不同型号可能使用相同的接收器 ID，但命令和电量数据格式未必相同。

### 功能

- 在菜单栏显示当前电量百分比与鼠标图标。
- 在菜单中显示最近一次有效读数的电池电压（mV）。
- 充电中显示绿色闪电；设备报告满电时显示“已充满”。
- 支持“立即刷新”和“开机自动启动”。
- 只匹配 MC203 的指定 HID 状态接口；不使用蓝牙。
- 不记录鼠标移动、按键、滚轮或个人数据。诊断信息只保存在内存中，直到退出应用。

### 电量换算

应用读取鼠标报告的实际电池电压，并按 MC203 Windows 原厂驱动所采用的电压/电量换算点计算百分比。这个曲线**不是线性的**：例如约 `3843 mV` 会显示约 `45%`，而约 `4000 mV` 对应约 `75%`，`4110 mV` 及以上才是 `100%`。这是保留原厂换算方式的结果，并非本项目额外平滑或修改后的曲线。

### 安装与构建

发布页提供已打包的 `.dmg`。从源码构建：

```sh
./build.sh
open build/鼠标电量.app
```

首次启动需要在“系统设置 → 隐私与安全性 → 输入监控”中允许此应用。macOS 将该接收器的厂商状态报告归入此权限；本应用只接受经过校验的电量回复报文。

### 非官方与商标说明

本项目不是官方驱动，不包含、分发或依赖任何厂商安装包、可执行文件、DLL、图片、Logo 或配置文件。它不会修改鼠标设置、固件、灯效、按键或 DPI。使用前请自行判断风险；作者不对设备兼容性或数据准确性作保证。

## English

This is a small macOS menu-bar utility I made so I can check the battery of my **TAIDU MC203 ergonomic mouse** at any time and recharge it promptly. It is shared as open source for people with the same need.

It supports only the physically verified MC203 interfaces:

- 2.4 GHz receiver: USB `3554:F5D5`
- Wired USB mode: USB `3554:F511`
- macOS 13 or later on Apple Silicon (arm64)

It does **not** support Bluetooth, keyboards, or other TAIDU mice. A matching or similar USB ID is not proof of compatibility: different products can share a receiver ID while using different commands or battery-report formats.

### Features

- Shows the current battery percentage and a mouse icon in the menu bar.
- Shows the voltage (mV) from the latest valid battery report in the menu.
- Shows a green lightning bolt while charging and “Fully charged” when reported by the device.
- Includes manual refresh and Launch at Login.
- Matches only the specified MC203 HID status interfaces; no Bluetooth is used.
- Does not record pointer movement, buttons, scrolling, or personal data. Diagnostics stay in memory only until the app quits.

### Battery conversion

The app reads the battery voltage reported by the mouse and converts it to a percentage using the voltage-to-percentage points used by the MC203 Windows driver. The curve is intentionally **non-linear**: about `3843 mV` maps to about `45%`, about `4000 mV` maps to about `75%`, and `4110 mV` or higher maps to `100%`. The app preserves that vendor conversion behaviour; it does not apply an extra smoothing curve.

### Build

Use a macOS 13+ Apple-Silicon development environment:

```sh
./build.sh
open build/鼠标电量.app
```

At first launch, allow Input Monitoring in **System Settings → Privacy & Security → Input Monitoring**. macOS puts this receiver’s vendor status channel behind that permission. The app accepts only checksum-validated battery replies.

### Unofficial and trademark notice

This is not an official driver. The repository contains no vendor installer, executable, DLL, artwork, logo, or configuration file, and does not depend on one. It does not alter firmware, settings, lighting, buttons, DPI, or other mouse behavior. Use it at your own discretion; no compatibility or measurement-accuracy warranty is provided.

## License

Released under the [MIT License](LICENSE). See [NOTICE](NOTICE) for third-party and trademark notices.
