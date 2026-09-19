#!/usr/bin/env python3
"""极简 X11 自动化：windows / click x y / type TEXT / key NAME / sleep SEC
仅用于无头环境下对 Witseek 界面做无人值守验证（python-xlib + XTest）。

依赖（conda env 内，无需 sudo）：
    ~/miniconda3/envs/xwt_seek/bin/python -m pip install python-xlib
例：
    DISPLAY=:100 python scripts/xdrive.py click 352 149 sleep 0.5 type ls key Return
坐标为屏幕绝对坐标（Xvfb :100 为 1920x1080）；请用 PIL 读未缩放截图程序化定位，勿目测。
"""
import os
import sys
import time
from Xlib import X, display
from Xlib.XK import string_to_keysym
from Xlib.ext.xtest import fake_input
from Xlib.protocol import request

D = display.Display(os.environ.get('DISPLAY', ':100'))
ROOT = D.screen().root


def warp(x, y):
    request.WarpPointer(
        display=D.display,
        src_window=0,
        dst_window=ROOT,
        src_x=0,
        src_y=0,
        src_width=0,
        src_height=0,
        dst_x=int(x),
        dst_y=int(y),
    )
    D.sync()
    time.sleep(0.12)


def list_windows():
    def walk(w, depth=0):
        try:
            name = w.get_wm_name()
        except Exception:
            name = None
        if name:
            try:
                geo = w.get_geometry()
                t = w.translate_coords(ROOT, 0, 0)
                print(f"{'  '*depth}win sx={t.root_x} sy={t.root_y} w={geo.width} h={geo.height} name={name!r}")
            except Exception:
                pass
        try:
            kids = w.query_tree().children
        except Exception:
            kids = []
        for k in kids:
            walk(k, depth + 1)
    walk(ROOT)


def click(x, y):
    warp(x, y)
    time.sleep(0.15)
    fake_input(D, X.ButtonPress, 1)
    D.sync()
    time.sleep(0.05)
    fake_input(D, X.ButtonRelease, 1)
    D.sync()
    time.sleep(0.2)


def press_keycode(kc, shift=False):
    if shift:
        fake_input(D, X.KeyPress, 50)  # Shift_L keycode 常见为 50
        D.sync()
    fake_input(D, X.KeyPress, kc)
    D.sync()
    fake_input(D, X.KeyRelease, kc)
    D.sync()
    if shift:
        fake_input(D, X.KeyRelease, 50)
        D.sync()
    time.sleep(0.03)


def type_text(s):
    for ch in s:
        if ch == '\n':
            key('Return')
            continue
        ks = string_to_keysym(ch)
        if ks == 0 and ch == '-':
            ks = string_to_keysym('minus')
        kc = D.keysym_to_keycode(ks) if ks else 0
        if not kc:
            continue
        # 大写或上档字符
        need_shift = ch.isupper() or ch in '~!@#$%^&*()_+{}|:"<>?'
        press_keycode(kc, need_shift)


def key(name):
    ks = string_to_keysym(name)
    kc = D.keysym_to_keycode(ks) if ks else 0
    if kc:
        press_keycode(kc)


def main():
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        cmd = args[i]
        if cmd == 'windows':
            list_windows()
            i += 1
        elif cmd == 'click':
            click(args[i + 1], args[i + 2])
            i += 3
        elif cmd == 'type':
            type_text(args[i + 1])
            i += 2
        elif cmd == 'key':
            key(args[i + 1])
            i += 2
        elif cmd == 'sleep':
            time.sleep(float(args[i + 1]))
            i += 2
        else:
            print('unknown', cmd)
            i += 1


if __name__ == '__main__':
    main()
