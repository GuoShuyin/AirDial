#!/usr/bin/env python3
"""AirDial's voice-command agent: Claude computer use on the display under your cursor.

AirDial starts this when your dictated sentence contains the trigger word ("AGI"):

    agent.py --command "open tomorrow in my calendar" --region X,Y,W,H --cursor X,Y

--region is the display (global points, top-left origin) and --cursor the mouse position in
the same space. The script sends Claude the command, the cursor position and a screenshot of
that display, then carries out Claude's mouse / keyboard actions on it until the task is done.
Progress goes to stdout as JSON lines ({"status": ...}, {"done": ...}, {"error": ...}).
AirDial stops it (terminates the process) when you press Esc.

Needs: `pip install anthropic pyobjc-framework-Quartz`, ANTHROPIC_API_KEY in the environment,
and Screen Recording + Accessibility permission for the app that started AirDial.
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time

import anthropic
import Quartz

MODEL = "claude-opus-5-5"
MAX_LONG_EDGE = 1568          # screenshot long edge sent to the model (pixels)
TOOLSET = {"type": "computer_toolset_20260801"}
NOT_EXECUTED = "Not executed: an earlier computer action in this turn failed."

SYSTEM = """You operate the user's Mac on their behalf, on the one display shown in the screenshots.
The user spoke a command while pointing at this display; "this", "here" or "that" usually means
what is under their mouse cursor, whose position you are given. Carry the command out with the
computer tools, check the result with a screenshot, then stop and reply with one short sentence
saying what you did.

Be careful, this is the user's real computer:
- Before anything hard to undo (sending a message or email, deleting, buying, submitting a form,
  changing settings), stop and describe what you are about to do instead of doing it.
- Never type passwords or payment details.
- If the command is unclear or you can't find what it refers to, stop and say so briefly.
On macOS the Command key is "super" (e.g. "super+c" to copy)."""


def emit(**kw):
    print(json.dumps(kw), flush=True)


class Display:
    """The display region in global points, and the screenshot pixel space the model sees."""

    def __init__(self, x, y, w, h):
        self.x, self.y, self.w, self.h = x, y, w, h
        self.scale = min(1.0, MAX_LONG_EDGE / max(w, h))   # screenshot pixels per point
        self.sw, self.sh = round(w * self.scale), round(h * self.scale)

    def to_global(self, c):
        return (self.x + c[0] / self.scale, self.y + c[1] / self.scale)

    def to_shot(self, gx, gy):
        return (round((gx - self.x) * self.scale), round((gy - self.y) * self.scale))

    def capture(self, region=None):
        """PNG (base64) of the display, or of `region` [x0, y0, x1, y1] in screenshot pixels."""
        if region:
            x0, y0 = self.to_global(region[:2])
            x1, y1 = self.to_global(region[2:])
            rx, ry, rw, rh = min(x0, x1), min(y0, y1), abs(x1 - x0), abs(y1 - y0)
        else:
            rx, ry, rw, rh = self.x, self.y, self.w, self.h
        with tempfile.TemporaryDirectory() as d:
            raw, out = os.path.join(d, "raw.png"), os.path.join(d, "out.png")
            subprocess.run(["screencapture", "-x", "-t", "png", "-R", f"{rx:.0f},{ry:.0f},{rw:.0f},{rh:.0f}", raw],
                           check=True, capture_output=True)
            if region:
                # Full resolution, fitted into the usual screenshot size, aspect kept.
                subprocess.run(["sips", "-Z", str(max(self.sw, self.sh)), raw, "--out", out], check=True, capture_output=True)
            else:
                subprocess.run(["sips", "-z", str(self.sh), str(self.sw), raw, "--out", out], check=True, capture_output=True)
            with open(out, "rb") as f:
                return base64.b64encode(f.read()).decode()


# --- input events --------------------------------------------------------------------------

KEYCODES = {
    "return": 36, "enter": 36, "tab": 48, "space": 49, "backspace": 51, "delete": 51, "escape": 53, "esc": 53,
    "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "page_up": 116,
    "pagedown": 121, "page_down": 121, "forwarddelete": 117,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
    "f11": 103, "f12": 111,
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
    "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
    "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
}
MODIFIERS = {
    "shift": Quartz.kCGEventFlagMaskShift, "ctrl": Quartz.kCGEventFlagMaskControl, "control": Quartz.kCGEventFlagMaskControl,
    "alt": Quartz.kCGEventFlagMaskAlternate, "option": Quartz.kCGEventFlagMaskAlternate,
    "super": Quartz.kCGEventFlagMaskCommand, "cmd": Quartz.kCGEventFlagMaskCommand, "command": Quartz.kCGEventFlagMaskCommand,
    "meta": Quartz.kCGEventFlagMaskCommand, "fn": Quartz.kCGEventFlagMaskSecondaryFn,
}


def post(e):
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)


def release_modifiers():
    # A posted event with modifier flags leaves them "held" in this process's event state.
    for code in (59, 55, 58, 56, 63):
        e = Quartz.CGEventCreateKeyboardEvent(None, code, False)
        Quartz.CGEventSetType(e, Quartz.kCGEventFlagsChanged)
        Quartz.CGEventSetFlags(e, 0)
        post(e)


def parse_mods(text):
    flags = 0
    for part in (text or "").lower().split("+"):
        if part.strip():
            if part.strip() not in MODIFIERS:
                raise ValueError(f"unknown modifier {part!r}")
            flags |= MODIFIERS[part.strip()]
    return flags


def mouse(kind, gx, gy, button=Quartz.kCGMouseButtonLeft, clicks=1, flags=0):
    e = Quartz.CGEventCreateMouseEvent(None, kind, (gx, gy), button)
    Quartz.CGEventSetIntegerValueField(e, Quartz.kCGMouseEventClickState, clicks)
    Quartz.CGEventSetFlags(e, flags)
    post(e)


def cursor_global():
    return Quartz.CGEventGetLocation(Quartz.CGEventCreate(None))


def click(d, inp, button, count):
    flags = parse_mods(inp.get("text"))
    if inp.get("coordinate"):
        gx, gy = d.to_global(inp["coordinate"])
        mouse(Quartz.kCGEventMouseMoved, gx, gy)
    else:
        p = cursor_global()
        gx, gy = p.x, p.y
    down, up = {
        Quartz.kCGMouseButtonLeft: (Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp),
        Quartz.kCGMouseButtonRight: (Quartz.kCGEventRightMouseDown, Quartz.kCGEventRightMouseUp),
        Quartz.kCGMouseButtonCenter: (Quartz.kCGEventOtherMouseDown, Quartz.kCGEventOtherMouseUp),
    }[button]
    for i in range(1, count + 1):
        mouse(down, gx, gy, button, i, flags)
        mouse(up, gx, gy, button, i, flags)
        time.sleep(0.05)
    if flags:
        release_modifiers()


def key_combo(text, down_up=True, hold=None):
    parts = [p.strip() for p in text.split("+") if p.strip()]
    mods = [p for p in parts[:-1]]
    key = parts[-1].lower() if parts else ""
    flags = parse_mods("+".join(mods))
    if key in MODIFIERS and not mods:
        flags, key = MODIFIERS[key], None
    code = KEYCODES.get(key) if key else None
    if key and code is None:
        if len(key) == 1:          # any other single character: type it
            type_text(parts[-1])
            return
        raise ValueError(f"unknown key {parts[-1]!r}")
    if code is not None:
        e = Quartz.CGEventCreateKeyboardEvent(None, code, True)
        Quartz.CGEventSetFlags(e, flags)
        post(e)
        if hold:
            time.sleep(hold)
        e = Quartz.CGEventCreateKeyboardEvent(None, code, False)
        Quartz.CGEventSetFlags(e, flags)
        post(e)
    release_modifiers()


def type_text(text):
    for i in range(0, len(text), 16):
        chunk = text[i:i + 16]
        for down in (True, False):
            e = Quartz.CGEventCreateKeyboardEvent(None, 0, down)
            Quartz.CGEventKeyboardSetUnicodeString(e, len(chunk), chunk)
            Quartz.CGEventSetFlags(e, 0)
            post(e)
        time.sleep(0.02)


def image_result(b64):
    return [{"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": b64}}]


def handle(d, name, inp):
    """Run one computer toolset member; returns tool_result content."""
    if name == "screenshot":
        return image_result(d.capture())
    if name == "zoom":
        return image_result(d.capture(inp["region"]))
    if name in ("left_click", "right_click", "middle_click", "double_click", "triple_click"):
        button = {"right_click": Quartz.kCGMouseButtonRight, "middle_click": Quartz.kCGMouseButtonCenter}.get(name, Quartz.kCGMouseButtonLeft)
        click(d, inp, button, {"double_click": 2, "triple_click": 3}.get(name, 1))
        return "OK"
    if name == "mouse_move":
        mouse(Quartz.kCGEventMouseMoved, *d.to_global(inp["coordinate"]))
        return "OK"
    if name == "left_click_drag":
        flags = parse_mods(inp.get("text"))
        sx, sy = d.to_global(inp["start_coordinate"])
        ex, ey = d.to_global(inp["coordinate"])
        mouse(Quartz.kCGEventMouseMoved, sx, sy)
        mouse(Quartz.kCGEventLeftMouseDown, sx, sy, flags=flags)
        for k in range(1, 21):
            f = k / 20
            mouse(Quartz.kCGEventLeftMouseDragged, sx + (ex - sx) * f, sy + (ey - sy) * f, flags=flags)
            time.sleep(0.01)
        mouse(Quartz.kCGEventLeftMouseUp, ex, ey, flags=flags)
        if flags:
            release_modifiers()
        return "OK"
    if name in ("left_mouse_down", "left_mouse_up"):
        p = cursor_global()
        mouse(Quartz.kCGEventLeftMouseDown if name == "left_mouse_down" else Quartz.kCGEventLeftMouseUp, p.x, p.y)
        return "OK"
    if name == "cursor_position":
        p = cursor_global()
        x, y = d.to_shot(p.x, p.y)
        return f"X={x}, Y={y}"
    if name == "scroll":
        if inp.get("coordinate"):
            mouse(Quartz.kCGEventMouseMoved, *d.to_global(inp["coordinate"]))
        n = int(inp.get("scroll_amount", 3))
        dy = {"up": n, "down": -n}.get(inp["scroll_direction"], 0)
        dx = {"left": n, "right": -n}.get(inp["scroll_direction"], 0)
        e = Quartz.CGEventCreateScrollWheelEvent(None, Quartz.kCGScrollEventUnitLine, 2, dy, dx)
        Quartz.CGEventSetFlags(e, parse_mods(inp.get("text")))
        post(e)
        return "OK"
    if name == "type":
        type_text(inp["text"])
        return "OK"
    if name == "key":
        for _ in range(int(inp.get("repeat", 1))):
            key_combo(inp["text"])
            time.sleep(0.03)
        return "OK"
    if name == "hold_key":
        key_combo(inp["text"], hold=min(float(inp.get("duration", 1)), 300))
        return "OK"
    if name == "wait":
        time.sleep(min(float(inp.get("duration", 1)), 300))
        return "OK"
    raise ValueError(f"unsupported action {name}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--command", required=True)
    ap.add_argument("--region", required=True, help="display X,Y,W,H in global points")
    ap.add_argument("--cursor", required=True, help="mouse X,Y in global points")
    ap.add_argument("--max-steps", type=int, default=40)
    args = ap.parse_args()

    d = Display(*[float(v) for v in args.region.split(",")])
    cx, cy = d.to_shot(*[float(v) for v in args.cursor.split(",")])
    client = anthropic.Anthropic()   # ANTHROPIC_API_KEY from the environment

    emit(status=f"Looking at the screen for: {args.command}")
    messages = [{"role": "user", "content": [
        {"type": "text", "text": f"Command: {args.command}\n\nThe mouse cursor is at x={cx}, y={cy} in this "
                                 f"screenshot ({d.sw}x{d.sh} pixels)."},
        *image_result(d.capture()),
    ]}]

    for step in range(args.max_steps):
        try:
            response = client.beta.messages.create(
                model=MODEL,
                max_tokens=16000,
                betas=["server-side-fallback-2026-07-01"],
                extra_body={"fallbacks": "default"},   # re-run a declined request on Anthropic's recommended model
                thinking={"type": "adaptive"},
                output_config={"effort": "medium"},
                system=SYSTEM,
                tools=[TOOLSET],
                messages=messages,
            )
        except anthropic.RateLimitError as e:
            emit(error=f"Rate limited: {e}")
            return 1
        except anthropic.APIStatusError as e:
            emit(error=f"API error {e.status_code}: {e.message}")
            return 1
        except anthropic.APIConnectionError as e:
            emit(error=f"Connection error: {e}")
            return 1

        if response.stop_reason == "refusal":
            emit(error="Claude declined this request.")
            return 1
        messages.append({"role": "assistant", "content": response.content})

        results, failed = [], False
        for block in response.content:
            if block.type != "tool_use" or getattr(block, "toolset_name", None) != "computer":
                continue
            result = {"type": "tool_result", "tool_use_id": block.id, "toolset_name": "computer"}
            if failed:
                result["content"], result["is_error"] = NOT_EXECUTED, True
            else:
                emit(status=f"{block.name} {json.dumps(block.input)[:120]}")
                try:
                    result["content"] = handle(d, block.name, dict(block.input))
                except Exception as err:   # report to Claude, stop this turn's batch
                    result["content"], result["is_error"] = f"Error: {err}", True
                    failed = True
            results.append(result)

        if not results:
            text = " ".join(b.text for b in response.content if b.type == "text").strip()
            emit(done=text or "Done.")
            return 0
        messages.append({"role": "user", "content": results})

    emit(error=f"Stopped after {args.max_steps} steps.")
    return 1


SCREEN_RECORDING_HINT = ("Can't take a screenshot: give Screen Recording permission to the app you started "
                         "AirDial from (System Settings > Privacy & Security > Screen & System Audio Recording), "
                         "then quit and reopen that app.")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as e:
        if e.cmd and e.cmd[0] == "screencapture":
            emit(error=SCREEN_RECORDING_HINT)
        else:
            emit(error=f"{e.cmd[0]} failed: {(e.stderr or b'').decode(errors='replace').strip()}")
        sys.exit(1)
    except Exception as e:   # anything else: say what happened instead of dying silently
        emit(error=f"{type(e).__name__}: {e}")
        sys.exit(1)
