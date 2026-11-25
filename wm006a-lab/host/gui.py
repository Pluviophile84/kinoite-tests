#!/usr/bin/env python3
"""Drive the VM's real display from the runner: QMP screendump + Tesseract OCR + absolute
pointer clicks through the virtio tablet. Usage:
  gui.py shot NAME
  gui.py click-text "Test local IPC" NAME
  gui.py wait-text "gateway replied" TIMEOUT NAME
  gui.py absent-text "gateway replied" NAME   (exit 0 if the text is NOT on screen)
Screenshots go to $OUT/wm006a/gui/NAME.png. Exit 0 on success, 1 when text is not found."""
import json
import os
import re
import socket
import subprocess
import sys
import time

QMP = os.path.join(os.environ.get("WORK", "/mnt/kt"), "qmp.sock")
SHOTS = os.path.join(os.environ.get("OUT", "/mnt/kt/results"), "wm006a", "gui")
os.makedirs(SHOTS, exist_ok=True)


class Qmp:
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(QMP)
        self.f = self.s.makefile("rwb")
        self.f.readline()  # greeting
        self.cmd("qmp_capabilities")

    def cmd(self, execute, **args):
        self.f.write(json.dumps({"execute": execute, "arguments": args}).encode() + b"\n")
        self.f.flush()
        while True:
            reply = json.loads(self.f.readline())
            if "return" in reply or "error" in reply:
                if "error" in reply:
                    raise RuntimeError(reply["error"])
                return reply["return"]


def shot(name):
    path = os.path.join(SHOTS, f"{name}.png")
    Qmp().cmd("screendump", filename=path, format="png")
    for _ in range(50):
        if os.path.exists(path) and os.path.getsize(path) > 0:
            break
        time.sleep(0.1)
    return path


def words(path):
    from PIL import Image
    img = Image.open(path)
    w, h = img.size
    big = os.path.join(SHOTS, ".ocr.png")
    img.convert("L").resize((w * 2, h * 2)).save(big)
    tsv = subprocess.run(["tesseract", big, "stdout", "--psm", "11", "tsv"],
                         capture_output=True, text=True).stdout
    out = []
    for line in tsv.splitlines()[1:]:
        p = line.split("\t")
        if len(p) == 12 and p[11].strip():
            x, y, bw, bh = (int(v) // 2 for v in p[6:10])
            out.append((re.sub(r"[^a-z0-9+]", "", p[11].lower()), x, y, bw, bh, p[11]))
    return out, (w, h)


def find(path, phrase):
    target = [re.sub(r"[^a-z0-9+]", "", t.lower()) for t in phrase.split()]
    ws, size = words(path)
    tokens = [w[0] for w in ws]
    for i in range(len(ws) - len(target) + 1):
        if tokens[i:i + len(target)] == target:
            x0 = ws[i][1]; y0 = min(w[2] for w in ws[i:i + len(target)])
            x1 = ws[i + len(target) - 1][1] + ws[i + len(target) - 1][3]
            y1 = max(w[2] + w[4] for w in ws[i:i + len(target)])
            return ((x0 + x1) // 2, (y0 + y1) // 2), size, ws
    return None, size, ws


def click(x, y, size):
    q = Qmp()
    w, h = size
    ax, ay = x * 0x7FFF // max(w - 1, 1), y * 0x7FFF // max(h - 1, 1)
    q.cmd("input-send-event", events=[
        {"type": "abs", "data": {"axis": "x", "value": ax}},
        {"type": "abs", "data": {"axis": "y", "value": ay}}])
    time.sleep(0.3)
    for down in (True, False):
        q.cmd("input-send-event", events=[{"type": "btn", "data": {"down": down, "button": "left"}}])
        time.sleep(0.15)


def main():
    cmd = sys.argv[1]
    if cmd == "shot":
        print(shot(sys.argv[2]))
    elif cmd == "click-text":
        phrase, name = sys.argv[2], sys.argv[3]
        pos, size, ws = find(shot(name), phrase)
        if not pos:
            print("not found; OCR saw: " + " ".join(w[5] for w in ws)[:300])
            sys.exit(1)
        click(*pos, size)
        print(f"clicked '{phrase}' at {pos} on {size[0]}x{size[1]}")
    elif cmd == "absent-text":
        phrase, name = sys.argv[2], sys.argv[3]
        pos, _, ws = find(shot(name), phrase)
        if pos:
            print(f"'{phrase}' still on screen at {pos}")
            sys.exit(1)
        print(f"'{phrase}' not on screen")
    elif cmd == "wait-text":
        phrase, timeout, name = sys.argv[2], float(sys.argv[3]), sys.argv[4]
        end = time.time() + timeout
        while True:
            pos, size, ws = find(shot(name), phrase)
            if pos:
                print(f"found '{phrase}' at {pos}")
                return
            if time.time() > end:
                print("not found; OCR saw: " + " ".join(w[5] for w in ws)[:300])
                sys.exit(1)
            time.sleep(3)


if __name__ == "__main__":
    main()
