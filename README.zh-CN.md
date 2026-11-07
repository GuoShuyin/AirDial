<p align="right"><a href="README.md">English</a> · <b>中文</b></p>

# AirDial

用 MacBook 自带摄像头，做 BMW 风格的隔空手势来控制音乐。不需要深度摄像头，也不需要训练模型。

| 手势 | 动作 |
| --- | --- |
| ☝️ 只伸食指，在空中**顺时针**画圈 | 音量 +（每转一圈调一格，像旋钮） |
| ☝️ 只伸食指，**逆时针**画圈 | 音量 − |
| ☝️ 伸食指**指着** | 移动鼠标光标，可以跨你所有的显示器 |
| ☝️ 指着的时候，拇指和食指**捏一下** | 左键单击（捏住不放就是拖拽） |
| ✌️ 伸食指 + 中指（V 字），**向上或向下**快速一划 | 下一首 |
| ✌️ V 字向右 / 向左一划 | 下一首 / 上一首 |
| 🖐 手掌张开、正对镜头，快速**向右**挥 | 切到左边的桌面 |
| 🖐 张开手掌，快速**向左**挥 | 切到右边的桌面 |
| 🖐 张开手掌，快速**向上或向下**挥 | 打开调度中心（展开所有窗口），再挥一次关闭 |
| 🖐 → ✊ 张开的手握成拳 | 最前面的窗口退出全屏 |
| ✊ → 🖐 拳头张开成手掌 | 最前面的窗口进入全屏 |

## 原理（为什么不需要训练）

1. **手部关键点**：用 Apple Vision 自带的 `VNDetectHumanHandPoseRequest`。这是苹果预训练好的模型，每帧给出 21 个手部关节点，在 Apple Silicon 上每帧大约 7 ms。摄像头锁定在 30 fps：光线暗的时候，摄像头本来会自动降到约 15 fps，曝光拉长，运动中的手就拍糊了。
2. **手型判断**：比较每根手指"指尖到手腕"和"PIP 关节到手腕"的距离比例，判断这根手指是否伸直，从而区分 ☝️ 单指、✌️ 双指、🖐 手掌和其他手型。用比例而不是绝对距离，所以手离摄像头远近都可以。
3. **画圈识别**：不拟合圆，而是累加指尖运动方向的转角。转一圈就是 ±360°，直线和来回晃动加起来接近 0。启动时要求：转了 270° 以上、85% 以上的转动是同一个方向、圈够大、不扁、足够圆。之后每多转一圈（360°）就再调一格音量，所以转几圈就调几格。从转到的最远位置往回转 120°，就停止调节。
4. **滑动识别**：两指指尖的中点在 0.45 秒内移动超过画面高度的 16%，并且主方向的位移是另一方向的 1.8 倍以上。向上和向下都是"下一首"：在网络摄像头上，挥动开头常带一个反方向的预备动作，两个方向分不可靠（`--vertical-prev` 可以恢复"向下 = 上一首"）。
5. **手掌挥动**（切桌面、调度中心）：手掌中心在 0.3 秒内移动画面高度的 25%，并且手掌要显得够宽（食指根部到小指根部的距离至少是画面高度的 14%）。真正挥手时，手掌是平着、近距离正对镜头的（实测 0.135–0.17）；路过的手或搭在键盘附近的手是侧着的或离得更远（0.08–0.12）。加上 `--palm-hold` 后，还要求手掌先停稳 0.25 秒，可以去掉剩下的少量误触发。向上和向下都是发送 Control+↑，macOS 自己会把它当作开关：按一次打开调度中心，再按一次关闭。
6. **手指光标**：把食指尖在摄像头画面里的一块"活动范围"，映射到你在 系统设置 → 显示器 里排好的屏幕上：横向把屏幕从左到右接起来，纵向按光标所在那块屏的高度来算（屏幕上下可以错开）。活动范围一开始只是画面中间的一小块，你的指尖伸到哪里它就扩到哪里，所以刚开始会偏灵敏，动几下就校准好了。动了真鼠标或触控板，手指光标会暂停 1.5 秒。
   **捏一下点击**的规则比较严格：你指着摄像头的时候，在 2D 画面里拇指尖和食指尖经常"看起来"挨在一起（宽松的规则在每段约一分钟的画圈录像里会误点 18–37 次，现在的规则是 0 次）。要求是：两个指尖几乎碰到（距离小于指根宽度的 18%）、Vision 确实看到了拇指（置信度 ≥ 0.4）、手基本停住，并且连续 4 帧都满足。捏的时候光标会停在捏之前那一刻的位置，所以点到的就是你指着的地方。捏的过程中偶尔有一帧距离略大，不会让计数重来（在一段录下来的捏合测试里，这让大约 11 次捏合的识别从 5 次提高到 8 次，画圈时误点仍是 0 次）。
7. **握拳和张开**：两种手型都要连续出现 4 帧、手掌正对镜头，第二个手型要在第一个结束后 0.4 秒内出现。全屏是通过辅助功能接口（`AXFullScreen`）直接设定的，不是来回切换：张开手不会把已经全屏的窗口退出全屏，握拳也不会让没全屏的窗口进入全屏。握拳之后你自然会把手放松张开，这时不会又进入全屏；要再用，先换成别的手势或把手拿开 0.4 秒。你在单指指着或用两指时，手掌/握拳的识别会被忽略（模型常把指着的食指误认成握拳）。
   手掌挥动和握拳/张开互相排斥：握拳前后 0.5 秒内的手掌挥动作废；手掌挥动要等手保持张开 0.1 秒后才执行；握拳/张开触发后 1 秒内不认手掌挥动。所以一边张开手一边往上抬，只会进入全屏，不会同时打开调度中心。
8. **防误触**：One Euro 滤波去抖。手型连续出现 3 帧才生效，两个手势之间直接切换要 10 帧。手型消失 0.5 秒才退出：手指转向摄像头时，模型会连续几帧认错，不能因此打断画圈。滑动后有 0.8 秒冷却；把手收回来的反向动作在 1.4 秒内会被忽略。任意一个动作触发后，其他手势会被锁住 0.6 秒。

所有阈值都在 [`Sources/AirDialCore/GestureConfig.swift`](Sources/AirDialCore/GestureConfig.swift) 里，也可以用 `--sensitivity` 整体调节主要阈值。

## 安装和运行

需要 macOS 12+，以及 Xcode 或 Command Line Tools（`xcode-select --install`）。

```bash
git clone https://github.com/GuoShuyin/AirDial.git
cd AirDial
swift build -c release          # 编译
swift test                      # 跑手势逻辑的单元测试（可选）
.build/release/AirDial          # 运行，会弹出摄像头预览窗口
```

只装了 Command Line Tools、没装 Xcode 时，`swift test` 找不到测试框架，改用：

```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test --disable-xctest --enable-swift-testing -Xswiftc -F -Xswiftc $F -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F
```

第一次运行时 macOS 会请求权限，都是授予**你启动它的那个 App**（Terminal / iTerm / VS Code）：

1. **摄像头**：弹窗点"允许"。如果之前拒绝过：系统设置 → 隐私与安全性 → 摄像头 → 打开你的终端 App，然后**完全退出并重新打开**它。
2. **辅助功能**（推荐；手指光标和切换桌面必须要有）：系统设置 → 隐私与安全性 → 辅助功能 → 打开你的终端 App，然后重新打开它。
   有了这个权限，AirDial 会模拟键盘上的媒体键，对任何播放器都有效（Apple Music、Spotify、网页里的 YouTube 等），调音量时还会显示系统的音量浮窗。
   没有这个权限时会自动退回 AppleScript：只能调系统音量，切歌只支持 Music 和 Spotify（第一次会弹"自动化"权限，点允许）。

手掌挥动是模拟 Control+← / Control+→ / Control+↑，也就是 macOS 默认的"向左/向右移动一个空间"和"调度中心"快捷键（系统设置 → 键盘 → 键盘快捷键 → 调度中心）。切换桌面至少要有两个桌面。

### 常用参数

```bash
.build/release/AirDial --dry-run           # 只识别不执行，适合先练手势
.build/release/AirDial --headless          # 不要预览窗口，后台运行（Ctrl+C 退出）
.build/release/AirDial --sensitivity 1.3   # 更灵敏（0.5 更严格 … 1.5 更灵敏）
.build/release/AirDial --ccw-up            # 反过来：逆时针加音量
.build/release/AirDial --vertical-prev     # 两指：向上 = 下一首，向下 = 上一首（默认两个方向都是下一首）
.build/release/AirDial --no-horizontal     # 关掉两指左右滑
.build/release/AirDial --no-desktops       # 关掉所有手掌挥动
.build/release/AirDial --no-mission-control  # 关掉手掌上下挥 = 调度中心
.build/release/AirDial --palm-follows      # 反过来：手掌向右 = 切到右边的桌面
.build/release/AirDial --palm-hold         # 严格模式：手掌要先停稳一下再挥
.build/release/AirDial --no-cursor         # 不用食指控制鼠标光标
.build/release/AirDial --no-hand-shapes    # 关掉握拳退出全屏 / 张开进入全屏
.build/release/AirDial --list-cameras      # 列出摄像头（用 --camera 名字 选择）
.build/release/AirDial --debug             # 打印每帧识别到的手型
.build/release/AirDial --log frames.csv    # 逐帧记录诊断数据（见下文）
```

## 使用技巧

- 手离屏幕 30–60 cm，并且**举得够高，让手腕也在画面里**。手腕被画面下沿切掉时，识别会差很多。
- 画圈：圈大概一个拳头大小，0.5–2 秒一圈都可以。屏幕上的点变绿，说明"旋钮"已经接上，继续转就继续调。
- 切歌：比出 V 字，干脆地划一下就停。想连续切歌时，划完先放松手指，再把手收回来。
- 光标：先用指着的手指，把你想到达的最左、最右、最上、最下都扫一遍，之后映射就校准好了。点击时先停住，再把拇指和食指快速捏一下。
- 全屏作用于最前面的窗口。先点一下你想操作的 App，不要停在 AirDial 的预览窗口上。
- 切桌面 / 调度中心：手掌张开、平着正对镜头，快速挥一下。认出手掌时，预览窗口会显示 "Ready: swipe now"。
- 光线越好越稳。背光（背后是窗户）时效果会明显下降。

## 用真实录像调参

`--log FILE` 每帧写一行 CSV：Vision 耗时、丢帧数、21 个关节的坐标和置信度、识别出的手型、触发的动作。`AirDialReplay` 把这样的录像重新喂给手势引擎，不用开摄像头，就能拿你自己的动作试不同的阈值：

```bash
.build/release/AirDial --dry-run --log run.csv     # 边做手势边录
swift build -c release --product AirDialReplay
.build/release/AirDialReplay run.csv --timeline                  # 按秒查看手型和动作
.build/release/AirDialReplay run.csv --set circleStepDegrees=180 # 试一个不同的阈值
.build/release/AirDialReplay run.csv --min-conf 0.2 --trace 10-14
```

日志里只有关键点坐标，没有任何画面。

## 项目结构

```
Sources/AirDialCore/    纯手势逻辑（不依赖摄像头，可以单元测试）
  GestureConfig.swift   所有阈值
  HandPose.swift        手型判断
  CircleTracker.swift   画圈识别
  SwipeDetector.swift   滑动识别
  HandShapeTransition.swift  张开手 <-> 握拳
  PointerTracker.swift  手指光标：自动校准范围、平滑、捏一下点击
  ScreenMapper.swift    光标位置 -> 你排好的显示器上的点
  GestureEngine.swift   去抖、滤波、调度
  Geometry.swift        向量、One Euro 滤波
Sources/AirDial/        macOS App
  HandTracker.swift     摄像头 + Vision 手部关键点
  MediaController.swift 媒体键 / AppleScript / 切换桌面
  CursorController.swift 移动 / 点击真实的鼠标光标
  PreviewWindow.swift   预览窗口和调试叠加层
  main.swift            启动、参数、权限、--log
Sources/AirDialReplay/  把 --log 录像回放给手势引擎
Tests/AirDialCoreTests/ 用合成的手部轨迹测试识别和防误触
```

## 已知局限

- 手指正对摄像头时，Vision 的 2D 关键点不可靠：在网络摄像头上，这类帧里大约三分之一会把伸着的食指认成握拳。上面说的"手型消失 0.5 秒才退出"能弥补大部分。
- 两指向上和向下分不可靠（挥动开头常带一个反方向的预备动作），所以两个方向都是"下一首"。

## License

MIT
