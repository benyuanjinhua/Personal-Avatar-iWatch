# Jackson Avatar Apple Watch 真机安装 Troubleshooting

> 本文记录 2026-07-30 的实际部署过程，并整理成后续可重复执行的排障手册。  
> 适用于：Xcode 26、iOS 26、watchOS 26；其他版本的菜单名称可能略有差异。

## 1. 已验证的成功条件

- Mac 已安装完整版 Xcode，并已选择正确的 Developer Directory。
- Xcode 已登录 Apple ID，允许创建 Apple Development 证书。
- iPhone 通过可传数据的 USB 线连接 Mac，双方已信任。
- iPhone 与 Watch 正常配对，Wi-Fi 和蓝牙保持开启。
- iPhone 和 Watch 的系统主开发者模式均已开启。
- Mac 的“隐私与安全性 → 蓝牙 / 本地网络”已允许 Xcode。
- Watch 已解锁、靠近 iPhone 和 Mac，最好放在充电器上。
- Xcode 自动签名配置同时包含 iPhone UDID 和 Watch UDID。

本次最终验证设备为 Apple Watch Series 8（`Watch6,15`，`arm64_32`）。不要只凭口头型号判断，以 `devicectl` 返回值为准。

## 2. 基础检查

### 2.1 确认 Xcode

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcodebuild -version
xcodebuild -showsdks
```

### 2.2 查看 Xcode 能发现哪些设备

```bash
xcrun devicectl list devices
xcrun xcdevice list
```

成功时应同时看到已连接的 iPhone 和已配对的 Watch。记录两种标识：

- CoreDevice ID：`devicectl list devices` 的 `Identifier`。
- UDID：`device info details` 中的 `hardwareProperties.udid`。

```bash
xcrun devicectl device info details --device <WATCH_COREDEVICE_ID>
```

关键成功状态：

```text
developerModeStatus: enabled
ddiServicesAvailable: true
pairingState: paired
tunnelState: connected
cpuType: arm64_32
```

## 3. 开发者模式：最容易混淆的地方

### iPhone

路径：

```text
设置 → 隐私与安全性 → 开发者模式
```

打开后按系统要求重启，并在重启解锁后再次确认“打开开发者模式”。

### Apple Watch

正确路径：

```text
设置 → 隐私与安全性 → 开发者模式
```

打开后必须：

1. 选择重新启动。
2. 重启并解锁 Watch。
3. 再次点击“打开开发者模式”。
4. 输入 Watch 密码确认。

Watch 设置首页的“开发者”菜单不是主开发者模式。里面的下列开关不能替代主开关：

- 关联域开发
- WidgetKit 开发者模式
- HealthKit 调试选项

如果“隐私与安全性”里没有开发者模式：

1. 先让 Xcode 的 Devices 窗口成功识别一次 Watch。
2. 保持 Watch 解锁并重启。
3. 重启后再次检查“设置 → 隐私与安全性”底部。

命令行返回的 `developerModeStatus` 是最终判断依据，不以菜单是否出现“开发者”三个字为准。

## 4. 推荐安装流程

### 4.1 Xcode 识别与签名

1. 打开 `WristAgent.xcodeproj`。
2. 打开 `Window → Devices and Simulators`。
3. 确认 iPhone 和 Watch 均在 Connected 下。
4. 两个 Target 使用同一个 Team 和 Automatic Signing。

目标 Bundle ID：

```text
iPhone: com.benyuan.wristagent.WristAgent
Watch:  com.benyuan.wristagent.WristAgent.watchkitapp
```

### 4.2 直接针对 Watch 构建

```bash
xcodebuild \
  -project WristAgent.xcodeproj \
  -scheme 'WristAgent Watch App' \
  -configuration Debug \
  -destination 'id=<WATCH_UDID>' \
  -derivedDataPath .build/WatchDeviceDerivedData \
  DEVELOPMENT_TEAM=<TEAM_ID> \
  WRISTAGENT_BUNDLE_ID=com.benyuan.wristagent.WristAgent \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build
```

成功标志：

```text
** BUILD SUCCEEDED **
```

构建产物：

```text
.build/WatchDeviceDerivedData/Build/Products/Debug-watchos/WristAgent Watch App.app
```

### 4.3 核验 Provisioning Profile

```bash
security cms -D \
  -i '.build/WatchDeviceDerivedData/Build/Products/Debug-watchos/WristAgent Watch App.app/embedded.mobileprovision' \
  | plutil -extract ProvisionedDevices xml1 -o - -
```

输出必须包含 Watch UDID。通常也会包含配对 iPhone 的 UDID。

检查签名：

```bash
codesign -dv --verbose=4 \
  '.build/WatchDeviceDerivedData/Build/Products/Debug-watchos/WristAgent Watch App.app'
```

应看到：

```text
Identifier=com.benyuan.wristagent.WristAgent.watchkitapp
Format=app bundle with Mach-O thin (arm64_32)
Authority=Apple Development: ...
```

### 4.4 安装、启动和验证

```bash
xcrun devicectl device install app \
  --device <WATCH_COREDEVICE_ID> \
  '.build/WatchDeviceDerivedData/Build/Products/Debug-watchos/WristAgent Watch App.app'
```

```bash
xcrun devicectl device process launch \
  --device <WATCH_COREDEVICE_ID> \
  com.benyuan.wristagent.WristAgent.watchkitapp
```

```bash
xcrun devicectl device info processes \
  --device <WATCH_COREDEVICE_ID> \
  | rg 'WristAgent|watchkitapp'
```

同时看到 Jackson Avatar 可执行文件和对应进程，说明安装、签名和启动均成功。

## 5. 故障现象与处理

### 5.1 iPhone 仅充电，Xcode 看不到设备

可能原因：

- 线材只支持充电。
- iPhone 未信任 Mac。
- iPhone 未解锁。

处理：

1. 使用确认支持数据传输的 USB-C 线。
2. 解锁 iPhone。
3. iPhone 上选择“信任此电脑”并输入密码。
4. Mac 上允许连接配件。
5. 重新执行 `xcrun devicectl list devices`。

### 5.2 Watch 完全不出现在 Xcode

按顺序检查：

1. iPhone 是否能被 Xcode 正常识别。
2. Watch 是否已与这台 iPhone 配对。
3. iPhone、Watch、Mac 的 Wi-Fi 和蓝牙是否开启。
4. Watch 是否解锁、靠近设备且屏幕点亮。
5. macOS 是否允许 Xcode 使用蓝牙和本地网络。
6. 完全退出并重新打开 Xcode。

权限改变后 Xcode 必须重启才能重新加载。

如果仍然没有 Watch，可重启 Xcode 设备发现服务：

```bash
killall CoreDeviceService remotepairingd
xcrun devicectl list devices
```

这两个服务会由 macOS 自动重新启动。

### 5.3 `connected (no DDI)`

典型根因：Watch 主开发者模式未真正启用。

检查：

```bash
xcrun devicectl device info details --device <WATCH_COREDEVICE_ID>
```

如果看到：

```text
developerModeStatus: disabled
ddiServicesAvailable: false
```

回到第 3 节重新开启 Watch 主开发者模式，并完成重启后的二次确认。

### 5.4 `doesn’t have a known architecture`

典型错误：

```text
Apple Watch doesn’t have a known architecture
```

这通常不是工程的 Architecture 配置问题，而是 Xcode 尚未获得 Watch 的完整设备信息。优先检查：

- `developerModeStatus` 是否为 `enabled`。
- `ddiServicesAvailable` 是否为 `true`。
- `tunnelState` 是否为 `connected`。

DDI 正常后，Xcode 会识别 Series 8 为 `arm64_32`。

### 5.5 `Timed out while attempting to establish tunnel`

处理顺序：

1. 解锁 Watch 和 iPhone。
2. Watch 靠近 iPhone 与 Mac，并保持屏幕点亮。
3. iPhone 打开 Watch App。
4. 重新发起开发配对：

```bash
xcrun devicectl manage pair --device <WATCH_COREDEVICE_ID>
```

5. 再次检查详情：

```bash
xcrun devicectl device info details --device <WATCH_COREDEVICE_ID>
```

### 5.6 `This app could not be installed at this time`

优先怀疑 Watch Provisioning Profile 不包含 Watch UDID。

处理：

1. 确认 Watch 已启用主开发者模式并建立 DDI。
2. 用 Watch UDID 作为 `xcodebuild -destination`。
3. 加上：

```text
-allowProvisioningUpdates
-allowProvisioningDeviceRegistration
```

4. 重新构建。
5. 按 4.3 节核验 `ProvisionedDevices`。
6. 使用 `devicectl device install app` 直接安装 Watch App。

只把 iPhone App 安装成功，并不能证明嵌入的 Watch App 已获得正确的 Watch Provisioning Profile。

### 5.7 `The specified device was not found`

说明使用了缓存的 CoreDevice ID，但 Watch 当前没有广播或尚未被重新发现。

先运行：

```bash
xcrun devicectl list devices
```

不要在 Watch 未出现时反复执行 `manage pair`。先恢复设备发现，再使用列表中的当前标识。

### 5.8 Watch 重启后仍显示旧的开发者模式状态

重启设备发现服务并重新配对开发连接：

```bash
killall CoreDeviceService remotepairingd
xcrun devicectl list devices
xcrun devicectl manage pair --device <WATCH_COREDEVICE_ID>
xcrun devicectl device info details --device <WATCH_COREDEVICE_ID>
```

最终必须读取到：

```text
developerModeStatus: enabled
ddiServicesAvailable: true
tunnelState: connected
```

### 5.9 Mac 锁屏后自动化或连接中断

Mac 锁屏会阻止 Xcode UI 自动化，也可能让正在恢复的设备发现流程停住。

部署期间保持：

- Mac 已解锁。
- iPhone 已解锁。
- Watch 已解锁。
- Watch 靠近并尽量充电。

## 6. 最短恢复顺序

遇到安装失败时，按这个顺序处理，避免同时改多个变量：

1. 解锁 Mac、iPhone 和 Watch。
2. 确认 iPhone USB 信任正常。
3. 确认 Watch 主开发者模式为开启。
4. 确认 macOS 已给 Xcode 蓝牙和本地网络权限。
5. 重启 Xcode。
6. `xcrun devicectl list devices` 确认两台设备都出现。
7. `device info details` 确认 Developer Mode、DDI 和 tunnel。
8. 使用 Watch UDID 真机构建。
9. 核验 Provisioning Profile 包含 Watch UDID。
10. 使用 `devicectl` 直接安装、启动并检查进程。

## 7. 高风险操作说明

下列操作不应作为第一选择：

- `devicectl manage unpair`：只解除 Mac 与设备的开发配对，但会要求重新建立信任。
- 在 Watch 中“清除受信任电脑”：会清除之前配对过的所有开发电脑记录。
- 解除 iPhone 与 Watch 的日常配对：耗时且会触发备份/恢复，只能在用户明确同意后执行。

除非前面的恢复顺序全部无效，否则不要使用这些操作。

