"""產生 APP 圖示（PWA、iPhone 主畫面、瀏覽器分頁）：橘底白色吊車，和電腦版圖示相同造型。

需要 PySide6（電腦版已安裝）：

    python tool/make_icons.py
"""
from __future__ import annotations

import os
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import QPointF, QRectF, Qt  # noqa: E402
from PySide6.QtGui import QColor, QGuiApplication, QImage, QPainter, QPen  # noqa: E402

APP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB = os.path.join(APP, "web")
ORANGE = QColor("#f29100")


def draw_crane(p: QPainter, size: float, inset: float) -> None:
    """在 size×size 的畫布中央（四周留 inset 比例）畫白色吊車線條。"""
    s = size * (1 - 2 * inset) / 64.0
    o = size * inset
    pt = lambda x, y: QPointF(o + x * s, o + y * s)  # noqa: E731
    pen = QPen(QColor("#ffffff"), 5 * s)
    pen.setCapStyle(Qt.RoundCap)
    pen.setJoinStyle(Qt.RoundJoin)
    p.setPen(pen)
    p.setBrush(Qt.NoBrush)
    p.drawLine(pt(16, 50), pt(48, 16))  # 吊臂
    p.drawLine(pt(10, 50), pt(54, 50))  # 車身
    thin = QPen(QColor("#ffffff"), 3 * s)
    thin.setCapStyle(Qt.RoundCap)
    p.setPen(thin)
    p.drawLine(pt(48, 16), pt(48, 33))  # 鋼索
    p.drawArc(QRectF(pt(44, 31), pt(52, 39)), 90 * 16, 270 * 16)  # 吊鉤
    p.setPen(Qt.NoPen)
    p.setBrush(QColor("#ffffff"))
    p.drawEllipse(pt(16, 50), 3.5 * s, 3.5 * s)  # 鉸點


def icon(size: int, rounded: bool, inset: float) -> QImage:
    img = QImage(size, size, QImage.Format_ARGB32)
    img.fill(Qt.transparent)
    p = QPainter(img)
    p.setRenderHint(QPainter.Antialiasing)
    p.setPen(Qt.NoPen)
    p.setBrush(ORANGE)
    if rounded:
        r = size * 12 / 64
        p.drawRoundedRect(QRectF(size * 4 / 64, size * 4 / 64, size * 56 / 64, size * 56 / 64), r, r)
        draw_crane(p, size, 0.12)
    else:  # 滿版底色（maskable、iPhone 會自己裁圓角）
        p.drawRect(QRectF(0, 0, size, size))
        draw_crane(p, size, inset)
    p.end()
    return img


def main() -> int:
    QGuiApplication(sys.argv)
    os.makedirs(os.path.join(WEB, "icons"), exist_ok=True)
    out = {
        "icons/Icon-192.png": icon(192, True, 0),
        "icons/Icon-512.png": icon(512, True, 0),
        "icons/Icon-maskable-192.png": icon(192, False, 0.2),
        "icons/Icon-maskable-512.png": icon(512, False, 0.2),
        "icons/apple-touch-icon.png": icon(180, False, 0.14),
        "favicon.png": icon(32, True, 0),
    }
    for name, img in out.items():
        path = os.path.join(WEB, name)
        if not img.save(path):
            print("無法寫入", path)
            return 1
        print(name, img.width(), "px")
    return 0


if __name__ == "__main__":
    sys.exit(main())
