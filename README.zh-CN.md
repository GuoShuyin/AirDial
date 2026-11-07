<p align="right"><a href="README.md">English</a> · <b>中文</b></p>

# AirDial

用 MacBook 自带摄像头，做 BMW 风格的隔空手势来控制音乐。不需要深度摄像头，也不需要训练模型。

| 手势 | 动作 |
| --- | --- |
| ☝️ 伸食指**指着** | 移动鼠标光标，可以跨你所有的显示器（启动时校准） |
| ☝️ 指着的时候，拇指尖**点一下**中指第一指关节（靠指尖的那个） | 左键 |
| ☝️ 指着的时候，拇指尖**点一下**中指第二指关节 | 右键（仅 3D 跟踪） |
| ☝️ 指着的时候，拇指贴着中指**滑动** | 鼠标滚轮：往指尖方向滑是向上滚（仅 3D） |
| 🤞 食指和中指**并拢**，**顺时针**画圈 | 音量 +（每圈一格） |
| 🤞 同样的手势，**逆时针**画圈 | 音量 − |
| ✌️ 食指和中指**分开**（V 字），快速**向上或向下**一划 | 下一首 |
| 🖐 手掌张开、正对镜头，快速**向右**挥 | 切到左边的桌面 |
| 🖐 张开手掌，快速**向左**挥 | 切到右边的桌面 |
| 🖐 张开手掌，快速**向上或向下**挥 | 打开调度中心（展开所有窗口），再挥一次关闭 |
| 🖐 → ✊ 张开的手握成拳 | 最前面的窗口退出全屏 |
| ✊ → 🖐 拳头张开成手掌 | 最前面的窗口进入全屏 |
| 👍 竖起大拇指（保持） | 按住 Fn / 地球键，放下大拇指就松开（仅 3D） |

## 原理（为什么不需要训练）

1. **手部关键点**：用 Apple Vision 自带的 `VNDetectHumanHandPoseRequest`。这是苹果预训练好的模型，每帧给出 21 个手部关节点，在 Apple Silicon 上每帧大约 7 ms。摄像头锁定在 30 fps：光线暗的时候，摄像头本来会自动降到约 15 fps，曝光拉长，运动中的手就拍糊了。
2. **手型判断**：比较每根手指"指尖到手腕"和"PIP 关节到手腕"的距离比例，判断这根手指是否伸直，从而区分 ☝️ 单指、✌️ 双指、🖐 手掌和其他手型。用比例而不是绝对距离，所以手离摄像头远近都可以。
3. **画圈调音量**：食指和中指并拢（3D 指尖距离小于 2.5 cm，2D 下小于指根宽度的 35%）；分开超过 3.5 cm 就是 V 字，用来挥动切歌。不拟合圆，而是累加指尖运动方向的转角：转一圈就是 ±360°，直线和来回晃动加起来接近 0。启动时要求转了 270° 以上、85% 以上的转动是同一个方向、圈够大、不扁、足够圆。之后每多转一圈（360°）就调一格音量，转几圈就调几格。从转到的最远位置往回转 120° 就停止。
   可选的替代方式：`--circle-volume`（单指画圈；默认关闭，因为单指是光标），`--knob`（拇指、食指、中指像拧旋钮一样转，用 3D 计算手绕自身轴线的转动）。
4. **滑动识别**：V 字时，两指指尖的中点在 0.45 秒内移动超过画面高度的 16%，并且上下位移是左右位移的 1.8 倍以上。向上和向下都是"下一首"：在网络摄像头上，挥动开头常带一个反方向的预备动作，两个方向分不可靠（`--vertical-prev` 可以恢复"向下 = 上一首"）。两指左右移动不做任何操作（`--horizontal-tracks` 可以让它切下一首 / 上一首）。
5. **手掌挥动**（切桌面、调度中心）：手掌中心在 0.3 秒内移动画面高度的 25%，并且手掌要显得够宽（食指根部到小指根部的距离至少是画面高度的 14%）。真正挥手时，手掌是平着、近距离正对镜头的（实测 0.135–0.17）；路过的手或搭在键盘附近的手是侧着的或离得更远（0.08–0.12）。加上 `--palm-hold` 后，还要求手掌先停稳 0.25 秒，可以去掉剩下的少量误触发。向上和向下都是发送 Control+↑，macOS 自己会把它当作开关：按一次打开调度中心，再按一次关闭。
6. **手指光标**：启动时，每块屏幕都会提示你把食指举到摄像头画面中间，然后倒数 2 秒。接着依次在每块屏幕的正中心显示一个点（从左到右）；带摄像头的那块屏还会加上四个角（指着摄像头是最难的情况），并单独拟合一个完整的二维映射；最后是主屏的正上方和正下方。每个点出现后有 1 秒时间把手指移过去，然后指尖停稳 0.8 秒，"叮"一声就记下。根据记下的指尖位置，把你的指向映射到屏幕上：横向按各屏中心分段线性，纵向用主屏上下两个点算出统一的像素比例，再用每块屏自己的中心点对齐（屏幕可以上下错开）。按 Cmd+R 可以重新校准。校准会保存下来，`--no-calibrate` 直接用上次的结果。没有校准时，用一个会自动扩大的"活动范围"。动了真鼠标或触控板，手指光标暂停 1.5 秒。
   **点击**是拇指尖在中指上"点一下"：靠近第一指关节（靠指尖）是左键，靠近第二指关节是右键，按拇指落在手指上的位置来判断。拇指落下 0.2 秒后（或抬起时）才确认点击，而且这期间不能沿着手指滑动；滑动了就是滚动。用中指是为了让食指尖（也就是光标）不动；点的时候光标还会停在点之前那一刻的位置。有 3D 关节时，"点一下"指的是：0.6 秒内拇指先从中指上抬起至少 1.5 cm，再落到目标 2.5 cm 以内；两个目标都靠近时，取更近的那个。指着的时候拇指搭在弯着的中指上很常见，这不会触发点击。拇指贴着中指滑动（一直接触，到手指的距离不变）则是滚轮，每毫米 15 像素，也不会触发点击。2D（Vision）下只有左键，用相对指根宽度的严格距离判断。每次点击会响一声 "Tink"，并打印点击的位置。`--pinch-index` 可以改成拇指点食指指尖为左键。
7. **握拳和张开**：两种手型都要连续出现 4 帧、手掌正对镜头，第二个手型要在第一个结束后 0.4 秒内出现。全屏是通过辅助功能接口（`AXFullScreen`）直接设定的，不是来回切换。有些 App（基于 Chromium / Electron 的）报告的这个状态不准，所以窗口正好铺满整块屏幕时也算全屏；设置 0.6 秒后状态还没变，AirDial 会改发 Ctrl+Cmd+F。每次尝试都会打印一行诊断信息。因此张开手不会把已经全屏的窗口退出全屏，握拳也不会让没全屏的窗口进入全屏。握拳之后你自然会把手放松张开，这时不会又进入全屏；要再用，先换成别的手势或把手拿开 0.4 秒。你在单指指着或用两指时，手掌/握拳的识别会被忽略（模型常把指着的食指误认成握拳）。
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

### 3D 手部跟踪（推荐）

AirDial 默认使用 Google 的 MediaPipe Hand Landmarker，它能给出 3D 关节：手指弯曲、捏合、拧旋钮都按 3D 计算，从任何角度拍都能用。它在一个本地 Python 小进程（`Support/mediapipe_hands.py`）里离线运行；摄像头仍由 AirDial 打开，画面不会离开你的电脑。没装的话会自动退回 Apple Vision（只有 2D，准确度差一些）。

```bash
python3 -m venv .venv && .venv/bin/pip install mediapipe numpy
mkdir -p models && curl -L -o models/hand_landmarker.task \
  https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/latest/hand_landmarker.task
```

`--tracker vision` 强制用 Apple Vision；`--python 路径` / `--model 路径` 可以指定别的位置。

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
.build/release/AirDial --ccw-up            # 画圈反过来：逆时针加音量
.build/release/AirDial --no-calibrate      # 跳过启动时的光标校准，用上次的结果
.build/release/AirDial --vertical-prev     # 两指：向上 = 下一首，向下 = 上一首（默认两个方向都是下一首）
.build/release/AirDial --horizontal-tracks # 两指向右 / 向左 = 下一首 / 上一首
.build/release/AirDial --no-desktops       # 关掉所有手掌挥动
.build/release/AirDial --no-mission-control  # 关掉手掌上下挥 = 调度中心
.build/release/AirDial --palm-follows      # 反过来：手掌向右 = 切到右边的桌面
.build/release/AirDial --palm-hold         # 严格模式：手掌要先停稳一下再挥
.build/release/AirDial --no-cursor         # 不用食指控制鼠标光标
.build/release/AirDial --pinch-index       # 左键改成拇指点食指指尖（默认是中指指尖）
.build/release/AirDial --no-scroll         # 关掉拇指滑动滚屏（--scroll-reverse 反转方向）
.build/release/AirDial --circle-volume     # 同时允许单指画圈调音量
.build/release/AirDial --knob              # 同时允许三指拧旋钮调音量
.build/release/AirDial --no-hand-shapes    # 关掉握拳退出全屏 / 张开进入全屏
.build/release/AirDial --no-thumbs-up      # 竖大拇指时不按 Fn / 地球键
.build/release/AirDial --list-cameras      # 列出摄像头（用 --camera 名字 选择）
.build/release/AirDial --debug             # 打印每帧识别到的手型
.build/release/AirDial --log frames.csv    # 逐帧记录诊断数据（见下文）
```

## 使用技巧

- 手离屏幕 30–60 cm，并且**举得够高，让手腕也在画面里**。手腕被画面下沿切掉时，识别会差很多。
- 音量：食指和中指并拢（像合起来的 V），画大约一个拳头大小的圈，0.5–2 秒一圈。
- 切歌：比出 V 字，干脆地划一下就停。想连续切歌时，划完先放松手指，再把手收回来。
- 光标：启动校准时，用你之后会用的姿势来指。点击时先停住，拇指稍微抬起，再点到中指指尖（左键）或中指第二指关节（右键）上。
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
  KnobTracker.swift     三指旋钮
  SwipeDetector.swift   滑动识别
  HandShapeTransition.swift  张开手 <-> 握拳
  PointerTracker.swift  手指光标：自动校准范围、平滑、捏一下点击
  ScreenMapper.swift    光标位置 -> 你排好的显示器上的点
  GestureEngine.swift   去抖、滤波、调度
  Geometry.swift        向量、One Euro 滤波
Sources/AirDial/        macOS App
  HandTracker.swift     摄像头 + 手部关键点（MediaPipe 或 Vision）
  MediaPipeBackend.swift 和本地 MediaPipe 进程通信
  MediaController.swift 媒体键 / AppleScript / 切换桌面
  CursorController.swift 移动 / 点击真实的鼠标光标
  PreviewWindow.swift   预览窗口和调试叠加层
  main.swift            启动、参数、权限、--log
Support/mediapipe_hands.py  MediaPipe 手部跟踪进程
Sources/AirDialReplay/  把 --log 录像回放给手势引擎
Tests/AirDialCoreTests/ 用合成的手部轨迹测试识别和防误触
```

## 已知局限

- 手指正对摄像头时，Vision 的 2D 关键点不可靠：在网络摄像头上，这类帧里大约三分之一会把伸着的食指认成握拳。上面说的"手型消失 0.5 秒才退出"能弥补大部分。
- 两指向上和向下分不可靠（挥动开头常带一个反方向的预备动作），所以两个方向都是"下一首"。

## License

[PolyForm Noncommercial 1.0.0](LICENSE)：个人、学习、研究等非商业用途可以免费使用，也可以修改。**商业用途需要另外取得作者授权**，请通过 [GitHub](https://github.com/GuoShuyin) 联系。

MediaPipe 手部模型（`models/hand_landmarker.task`，需要单独下载）属于 Google，采用 Apache License 2.0。
