import AirDialCore
import Foundation

// Replays a `AirDial --log` CSV through GestureEngine so thresholds can be tuned on real recordings.
// Usage: AirDialReplay FILE.csv [--min-conf X] [--set key=value ...] [--timeline]

let args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
    print("Usage: AirDialReplay FILE.csv [--min-conf X] [--set key=value ...] [--timeline]")
    exit(2)
}

var minConf: Float = 0.1
var timeline = false
var trace: (Double, Double)?
var config = GestureConfig()
var i = 1
while i < args.count {
    switch args[i] {
    case "--min-conf": i += 1; minConf = Float(args[i])!
    case "--timeline": timeline = true
    case "--trace": i += 1; let r = args[i].split(separator: "-").map { Double($0)! }; trace = (r[0], r[1])
    case "--set":
        i += 1
        let kv = args[i].split(separator: "=").map(String.init)
        let v = Double(kv[1])!
        switch kv[0] {
        case "extendedRatio": config.extendedRatio = v
        case "curledRatio": config.curledRatio = v
        case "poseConfirmFrames": config.poseConfirmFrames = Int(v)
        case "poseDropSeconds": config.poseDropSeconds = v
        case "circleStartDegrees": config.circleStartDegrees = v
        case "circleStepDegrees": config.circleStepDegrees = v
        case "circleMinStep": config.circleMinStep = v
        case "circleMaxTurnDegrees": config.circleMaxTurnDegrees = v
        case "circleMinDiameter": config.circleMinDiameter = v
        case "circleConsistency": config.circleConsistency = v
        case "circleEngagedConsistency": config.circleEngagedConsistency = v
        case "circleMinAspect": config.circleMinAspect = v
        case "circleMaxRadiusSpread": config.circleMaxRadiusSpread = v
        case "circleIdleReset": config.circleIdleReset = v
        case "swipeWindow": config.swipeWindow = v
        case "swipeMinDistance": config.swipeMinDistance = v
        case "swipeAxisRatio": config.swipeAxisRatio = v
        case "palmSwipeMinDistance": config.palmSwipeMinDistance = v
        case "palmStillSpeed": config.palmStillSpeed = v
        case "palmArmSeconds": config.palmArmSeconds = v
        case "palmArmedWindow": config.palmArmedWindow = v
        case "palmMinHeight": config.palmMinHeight = v
        case "palmMinWidth": config.palmMinWidth = v
        case "palmRequireHold": config.palmRequireHold = v != 0
        case "palmSwipeWindow": config.palmSwipeWindow = v
        case "palmTrackFingertips": config.palmTrackFingertips = v != 0
        case "palmMaxJump": config.palmMaxJump = v
        case "filterMinCutoff": config.filterMinCutoff = v
        case "filterBeta": config.filterBeta = v
        default: print("unknown key \(kv[0])"); exit(2)
        }
    default: print("unknown arg \(args[i])"); exit(2)
    }
    i += 1
}

let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
let header = lines[0]
func col(_ name: String) -> Int { header.firstIndex(of: name)! }
let tCol = col("t")

func joint(_ row: [String], _ name: String) -> Vec2? {
    let xi = col("\(name)_x")
    guard row.count > xi + 2, let x = Double(row[xi]), let y = Double(row[xi + 1]), let c = Float(row[xi + 2]),
          c >= minConf else { return nil }
    return Vec2(x, y)
}

let engine = GestureEngine(config: config)
var poseCounts: [HandPose: Int] = [:]
var rawCounts: [HandPose: Int] = [:]
var actions: [(Double, GestureAction)] = []
let t0 = Double(lines[1][tCol])!
var lastSec = -1
var secRaw = ""
for row in lines.dropFirst() {
    let t = Double(row[tCol])!
    var sample: HandSample?
    if row.count > col("wrist_c"), !row[col("wrist_c")].isEmpty {
        func fj(_ f: String) -> HandSample.FingerJoints { .init(tip: joint(row, "\(f)Tip"), pip: joint(row, "\(f)PIP"), mcp: joint(row, "\(f)MCP")) }
        sample = HandSample(time: t, wrist: joint(row, "wrist"),
                            fingers: [.index: fj("index"), .middle: fj("middle"), .ring: fj("ring"), .little: fj("little")],
                            thumbTip: joint(row, "thumbTip"),
                            thumbConfidence: Float(row[col("thumbTip_c")]) ?? 0)
    }
    let acts = engine.process(sample, time: t, aspect: 4.0 / 3.0)
    poseCounts[engine.status.pose, default: 0] += 1
    rawCounts[engine.status.rawPose, default: 0] += 1
    for a in acts { actions.append((t - t0, a)) }
    if let (a, b) = trace, t - t0 >= a, t - t0 < b {
        let st = engine.status
        print(String(format: "%.2f raw=%@ pose=%@ cur=%@ deg=%.0f%@ %@", t - t0, st.rawPose.rawValue, st.pose.rawValue,
                     st.cursor.map { String(format: "(%.2f,%.2f)", $0.x, $0.y) } ?? "-", st.circleDegrees,
                     st.circleEngaged ? " ENG" : (st.palmArmed ? " ARMED" : ""), acts.map { $0.rawValue }.joined(separator: ",")))
    }
    if timeline {
        let s = Int(t - t0)
        if s != lastSec {
            if lastSec >= 0 { print(String(format: "%3d s  %@", lastSec, secRaw)) }
            lastSec = s
            secRaw = ""
        }
        let ch: Character = ["none": ".", "point": "1", "twoFingers": "2", "openPalm": "5", "fist": "f", "other": "o"][engine.status.pose.rawValue]!
        secRaw.append(ch)
        for a in acts { secRaw += "[\(a.rawValue)]" }
    }
}
if timeline, lastSec >= 0 { print(String(format: "%3d s  %@", lastSec, secRaw)) }

func fmt(_ c: [HandPose: Int]) -> String {
    [HandPose.none, .point, .twoFingers, .openPalm, .fist, .other].map { "\($0.rawValue)=\(c[$0, default: 0])" }.joined(separator: " ")
}
print("raw:    \(fmt(rawCounts))")
print("active: \(fmt(poseCounts))")
var counts: [GestureAction: Int] = [:]
for (_, a) in actions { counts[a, default: 0] += 1 }
print("actions: " + [GestureAction.volumeUp, .volumeDown, .nextTrack, .previousTrack, .desktopLeft, .desktopRight, .missionControl, .pointerPress, .minimizeWindow, .fullScreen].map { "\($0.rawValue)=\(counts[$0, default: 0])" }.joined(separator: " "))
print("action times: " + actions.map { String(format: "%.1f:%@", $0.0, $0.1.rawValue) }.joined(separator: " "))
