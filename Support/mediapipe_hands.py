#!/usr/bin/env python3
"""AirDial's 3D hand tracker: MediaPipe Hand Landmarker as a local sidecar process.

AirDial owns the camera. For every frame it writes to this process's stdin:

    8 bytes  timestamp (float64, seconds, little endian)
    4 bytes  width (uint32), 4 bytes height (uint32), 4 bytes bytes-per-row (uint32)
    height * bytes-per-row bytes of BGRA pixels

and reads back one JSON line per frame:

    {"hands": [{"score": 0.97, "image": [[x, y, z] * 21], "world": [[x, y, z] * 21]}]}

"image" is normalized to the frame (x right, y down, z relative depth); "world" is in metres
around the hand's centre (MediaPipe's world landmarks). Everything runs offline; frames never
leave this machine.
"""

import argparse
import json
import struct
import sys

import numpy as np
import mediapipe as mp
from mediapipe.tasks import python as mp_tasks
from mediapipe.tasks.python import vision


def read_exact(stream, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = stream.read(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return bytes(buf)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--min-detection", type=float, default=0.5)
    ap.add_argument("--min-tracking", type=float, default=0.5)
    args = ap.parse_args()

    options = vision.HandLandmarkerOptions(
        base_options=mp_tasks.BaseOptions(model_asset_path=args.model),
        running_mode=vision.RunningMode.VIDEO,
        num_hands=1,
        min_hand_detection_confidence=args.min_detection,
        min_hand_presence_confidence=args.min_detection,
        min_tracking_confidence=args.min_tracking,
    )
    landmarker = vision.HandLandmarker.create_from_options(options)

    stdin = sys.stdin.buffer
    stdout = sys.stdout
    stdout.write(json.dumps({"ready": True}) + "\n")
    stdout.flush()

    last_ms = -1
    while True:
        header = read_exact(stdin, 20)
        if header is None:
            break
        t, w, h, bpr = struct.unpack("<dIII", header)
        data = read_exact(stdin, h * bpr)
        if data is None:
            break
        frame = np.frombuffer(data, dtype=np.uint8).reshape(h, bpr)[:, : w * 4].reshape(h, w, 4)
        rgb = np.ascontiguousarray(frame[:, :, [2, 1, 0]])  # BGRA -> RGB
        image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)

        # VIDEO mode needs strictly increasing timestamps (milliseconds).
        ms = int(t * 1000)
        if ms <= last_ms:
            ms = last_ms + 1
        last_ms = ms

        result = landmarker.detect_for_video(image, ms)
        hands = []
        for i, lms in enumerate(result.hand_landmarks):
            world = result.hand_world_landmarks[i] if i < len(result.hand_world_landmarks) else []
            score = result.handedness[i][0].score if i < len(result.handedness) and result.handedness[i] else 1.0
            hands.append({
                "score": round(float(score), 3),
                "image": [[round(p.x, 5), round(p.y, 5), round(p.z, 5)] for p in lms],
                "world": [[round(p.x, 5), round(p.y, 5), round(p.z, 5)] for p in world],
            })
        stdout.write(json.dumps({"hands": hands}) + "\n")
        stdout.flush()


if __name__ == "__main__":
    main()
