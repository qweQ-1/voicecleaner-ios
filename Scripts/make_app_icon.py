#!/usr/bin/env python3
"""生成「净声」的 App 图标（1024x1024，**不含透明通道**）。

设计：左侧是杂乱抖动的噪声波形，右侧是平滑干净的声波，
中间一道亮色「净化线」。

两个必须遵守的点：
1. **App 图标不能带 alpha**：iOS 会自动裁圆角，图本身必须是满幅正方形、
   不带透明通道，否则 Xcode 会报 "icon must not have transparency"。
2. 纯代码绘制、零资源依赖，方便在任意环境重新生成。

PNG 编码手写（color type 2 = RGB，无 alpha），避免依赖 PIL 的版本差异。
"""
import math
import struct
import zlib
from pathlib import Path

SIZE = 1024
OUT = Path(__file__).resolve().parent.parent / "VoiceCleaner/Assets.xcassets/AppIcon.appiconset/icon-1024.png"


def lerp(a, b, t):
    return a + (b - a) * t


def rand01(i):
    """确定性伪随机（0..1），保证每次生成结果一致。"""
    x = (i * 2654435761) & 0xFFFFFFFF
    x ^= (x >> 15)
    x = (x * 2246822519) & 0xFFFFFFFF
    x ^= (x >> 13)
    return (x & 0xFFFF) / 65535.0


def main():
    w = h = SIZE
    top = (26, 44, 88)
    bottom = (10, 16, 34)

    mid = h * 0.5
    wave_x0, wave_x1 = w * 0.11, w * 0.89
    split = w * 0.50
    bars = 30
    max_amp = h * 0.34

    pixels = bytearray()
    for y in range(h):
        pixels.append(0)                       # PNG filter: none
        for x in range(w):
            t = y / (h - 1)
            r = int(lerp(top[0], bottom[0], t))
            g = int(lerp(top[1], bottom[1], t))
            b = int(lerp(top[2], bottom[2], t))

            # 中心柔光
            dx = (x - w * 0.5) / (w * 0.5)
            dy = (y - h * 0.5) / (h * 0.5)
            glow = max(0.0, 1.0 - math.sqrt(dx * dx + dy * dy))
            r = min(255, int(r + glow * 22))
            g = min(255, int(g + glow * 26))
            b = min(255, int(b + glow * 36))

            if wave_x0 <= x <= wave_x1:
                u = (x - wave_x0) / (wave_x1 - wave_x0)
                bi = int(u * bars)
                frac = u * bars - bi
                if frac < 0.66:
                    if x < split:
                        # ---- 噪声侧：高度随机抖动、暗淡偏红 ----
                        jitter = rand01(bi * 7 + 1)
                        amp = max_amp * (0.18 + 0.62 * jitter)
                        edge = min(1.0, (split - x) / (w * 0.05))
                        half = amp * 0.5 * (0.80 + 0.20 * edge)
                        if abs(y - mid) <= half:
                            k = 1.0 - abs(y - mid) / max(half, 1)
                            r = min(255, int(r + 150 + 60 * k))
                            g = min(255, int(g + 78 + 30 * k))
                            b = min(255, int(b + 62 + 24 * k))
                    else:
                        # ---- 干净侧：平滑正弦包络、明亮青色 ----
                        env = math.sin(math.pi * (bi + 0.5) / bars) ** 0.62
                        amp = max_amp * (0.30 + 0.70 * env)
                        edge = min(1.0, (x - split) / (w * 0.06))
                        half = amp * 0.5 * (0.86 + 0.14 * edge)
                        if abs(y - mid) <= half:
                            k = 1.0 - abs(y - mid) / max(half, 1)
                            r = min(255, int(r + 46 + 74 * k))
                            g = min(255, int(g + 206 + 44 * k))
                            b = min(255, int(b + 186 + 60 * k))

            # 净化线
            d = abs(x - split)
            if d < 6:
                a = 1.0 - d / 6.0
                r = min(255, int(r + a * 190))
                g = min(255, int(g + a * 240))
                b = min(255, int(b + a * 250))

            pixels.extend((r, g, b))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    # color type 2 = RGB（无 alpha），bit depth 8
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(pixels), 9))
    png += chunk(b"IEND", b"")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(png)
    print(f"wrote {OUT} ({len(png)} bytes, {w}x{h}, RGB 无 alpha)")


if __name__ == "__main__":
    main()
