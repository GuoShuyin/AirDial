# AirDial

用 MacBook 自带摄像头做 BMW 风格的隔空手势控制音乐。不需要深度摄像头，也不需要训练模型。

Mid-air, BMW-style gestures for music on macOS using the regular built-in webcam.

| 手势 | 动作 |
| --- | --- |
| ☝️ 只伸食指，在空中**顺时针**画圈 | 音量 + （一直转就一直加，像旋钮） |
| ☝️ 只伸食指，**逆时针**画圈 | 音量 − |
| ✌️ 伸食指+中指（V 字），**向上**快速一划 | 下一首 |
| ✌️ V 字**向下**快速一划 | 上一首 |
| ✌️ V 字向右 / 向左一划 | 下一首 / 上一首 |

## 原理（为什么不需要训练）

1. **手部关键点**：用 Apple Vision 自带的 `VNDetectHumanHandPoseRequest`。这是苹果预训练好的模型，每帧给出 21 个手部关节点，在 Apple Silicon 上 640×480 能跑 30fps，用的是神经网络引擎，不吃 GPU。
2. **手型判断**：比较每根手指"指尖到手腕"和"PIP 关节到手腕"的距离比例，判断哪根手指伸直，从而区分 ☝️ 单指 / ✌️ 双指 / 其他。用比例而不是绝对距离，所以手离摄像头远近都可以。
3. **画圈识别**：不拟合圆，而是累加指尖运动方向的转角。转一圈就是 ±360°，直线和来回晃动加起来接近 0。启动时还要求：转了 270° 以上、85% 以上的转动都是同一方向、圈够大、不扁、足够圆。之后每多转 90° 就再调一格音量。
4. **滑动识别**：两指中点在 0.45 秒内移动超过画面高度的 16%，且主方向位移是另一方向的 1.8 倍以上。
5. **防误触**：One Euro 滤波去抖；手型需要连续 3 帧才生效、丢失 6 帧才退出；滑动后有 0.8 秒冷却；把手收回来的反向动作在 1.4 秒内会被忽略；两种手势之间互相锁 0.6 秒。

效果好坏主要取决于这些阈值，全部集中在 [`Sources/AirDialCore/GestureConfig.swift`](Sources/AirDialCore/GestureConfig.swift)，也可以用 `--sensitivity` 整体调。

## 安装和运行

需要 macOS 12+，以及 Xcode 或 Command Line Tools（`xcode-select --install`）。

```bash
git clone <this repo> AirDial
cd AirDial
swift build -c release          # 编译
swift test                      # 跑手势识别的单元测试（可选）
.build/release/AirDial          # 运行，会弹出摄像头预览窗口
```

只装了 Command Line Tools、没装 Xcode 时，`swift test` 找不到测试框架，改用：

```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test --disable-xctest --enable-swift-testing -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F
```

第一次运行会请求两个权限，都是给**你启动它的那个 App**（Terminal / iTerm / VS Code）：

1. **摄像头**：弹窗点允许。如果之前拒绝过：系统设置 → 隐私与安全性 → 摄像头 → 打开 Terminal，然后**完全退出并重开 Terminal**。
2. **辅助功能**（推荐）：系统设置 → 隐私与安全性 → 辅助功能 → 打开 Terminal，然后重开 Terminal。
   有了它，AirDial 会模拟键盘上的媒体键，对任何播放器都有效（Apple Music、Spotify、网页里的 YouTube / 网易云等），音量会显示系统的音量浮窗。
   没有这个权限时会自动退回 AppleScript：只能调系统音量，切歌只支持 Music 和 Spotify（第一次会弹"自动化"权限，点允许）。

### 常用参数

```bash
.build/release/AirDial --dry-run        # 只识别不执行，先练手势
.build/release/AirDial --headless       # 不要预览窗口，后台运行（Ctrl+C 退出）
.build/release/AirDial --sensitivity 1.3   # 更灵敏（0.5 更严格 … 1.5 更灵敏）
.build/release/AirDial --ccw-up         # 反过来：逆时针加音量
.build/release/AirDial --swipe-down-next   # 反过来：向下 = 下一首
.build/release/AirDial --no-horizontal  # 关掉左右滑
.build/release/AirDial --list-cameras   # 列出摄像头（--camera 名字 选择）
.build/release/AirDial --debug          # 打印每帧识别到的手型
```

## 使用技巧

- 手离摄像头 40–80 cm，手指**朝上**，手掌大致对着屏幕。手指直接指向摄像头时会被遮挡，识别会变差。
- 画圈：圈大概一个拳头大小，0.5–2 秒一圈都可以。屏幕上点变绿说明"旋钮"已经接上，继续转就继续调。
- 切歌：V 字手势，干脆地划一下就停。想连续切歌时，划完先放松手指再把手收回来。
- 光线越好越稳。背光（背后是窗户）时效果会明显下降。
- 预览窗口里的数字和轨迹可以帮你判断：如果圈转了很多度还不触发，用 `--sensitivity 1.3`；如果误触发，用 `--sensitivity 0.8`。

## 项目结构

```
Sources/AirDialCore/   纯手势逻辑（不依赖摄像头，可单元测试）
  GestureConfig.swift  所有阈值
  HandPose.swift       手型判断
  CircleTracker.swift  画圈识别
  SwipeDetector.swift  滑动识别
  GestureEngine.swift  去抖 + 滤波 + 调度
  Geometry.swift       向量、One Euro 滤波
Sources/AirDial/       macOS App
  HandTracker.swift    摄像头 + Vision 手部关键点
  MediaController.swift 媒体键 / AppleScript
  PreviewWindow.swift  预览窗口和调试叠加层
  main.swift           启动、参数、权限
Tests/AirDialCoreTests/ 用合成手部轨迹测试识别和防误触
```

## License

MIT
