"""Regenerates the screenshots and animations in srs/docs/images.

Every image is a real srs session — run in a pseudo-terminal, emulated with
pyte, drawn as a Ghostty-looking window and photographed by headless Chrome.
Nothing is mocked: the text and colours are what srs prints. SRS_SEED pins the
generated cards, so a rerun produces the same pictures unless srs changed.

Needs pyte, Google Chrome, ImageMagick and DuckDB:

    python3 -m venv /tmp/srs-media && /tmp/srs-media/bin/pip install pyte
    /tmp/srs-media/bin/python srs/docs/make-media.py
"""
import fcntl
import html
import importlib.machinery
import importlib.util
import os
import pty
import select
import shutil
import struct
import subprocess
import tempfile
import termios
import time

import pyte

HERE = os.path.dirname(os.path.abspath(__file__))
SRS = os.path.join(HERE, "..", "bin", "srs")
IMAGES = os.path.join(HERE, "images")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
MAGICK = shutil.which("magick") or "/opt/homebrew/bin/magick"
SEED = "7"

COLORS = {
    "default": "#f8f8f2", "black": "#21222c", "red": "#ff5555", "green": "#50fa7b", "brown": "#f1fa8c",
    "yellow": "#f1fa8c", "blue": "#bd93f9", "magenta": "#ff79c6", "cyan": "#8be9fd", "white": "#f8f8f2",
    "brightblack": "#6272a4",
}
BACKGROUND = "#16171d"
CHAR_W, LINE_H = 8.45, 19.4

PAGE = """<!DOCTYPE html><html><head><meta charset="utf-8"><style>
body{{margin:0;background:{page_bg};}}
.win{{margin:18px;border-radius:12px;background:{bg};box-shadow:0 10px 40px rgba(0,0,0,.45);overflow:hidden;
display:inline-block;border:1px solid #2c2e3a;}}
.bar{{height:30px;background:#21222c;display:flex;align-items:center;padding:0 12px;position:relative;}}
.dot{{width:12px;height:12px;border-radius:50%;margin-right:8px;}}
.t{{position:absolute;left:0;right:0;text-align:center;color:#9aa3d0;font:13px -apple-system,sans-serif;}}
pre{{margin:0;padding:14px 16px 16px;font:14px/1.38 'JetBrains Mono',Menlo,monospace;color:#f8f8f2;}}
</style></head><body><div class="win"><div class="bar"><div class="dot" style="background:#ff5f57"></div>
<div class="dot" style="background:#febc2e"></div><div class="dot" style="background:#28c840"></div>
<div class="t">SRS</div></div><pre>{rows}</pre></div></body></html>"""


def load_srs():
    loader = importlib.machinery.SourceFileLoader("srs", SRS)
    spec = importlib.util.spec_from_loader("srs", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def chrome_png(page_html, width, height, path, scale):
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as f:
        f.write(page_html)
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=%d" % scale, "--window-size=%d,%d" % (width, height),
                    "--screenshot=" + path, "file://" + f.name], capture_output=True, timeout=60, check=True)
    os.unlink(f.name)


class Screen(pyte.Screen):
    """vim sends CSI > … m to set up the keyboard; pyte mistakes it for a
    colour change and falls over. It changes nothing on screen, so drop it."""

    def select_graphic_rendition(self, *attrs, private=False):
        if not private:
            super().select_graphic_rendition(*attrs)


class Terminal:
    """One srs process in a pty, with a pyte screen tracking what it shows."""

    def __init__(self, args, env, cols=100, rows=40):
        self.cols, self.rows = cols, rows
        self.screen = Screen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)
        self.frames = []
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.environ.update(env)
            os.environ.update(TERM="xterm-256color", SRS_SEED=SEED, COLUMNS=str(cols), LINES=str(rows))
            os.environ.pop("AI_AGENT", None)
            os.execv(args[0], args)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            if select.select([self.fd], [], [], 0.03)[0]:
                try:
                    self.stream.feed(os.read(self.fd, 65536))
                except OSError:
                    return

    def type(self, text, every=1, gap=0.03, hold=60):
        """Sends text a key at a time, recording a frame every `every` keys."""
        for i, ch in enumerate(text):
            try:
                os.write(self.fd, ch.encode())
            except OSError:
                return
            self.pump(gap)
            if (i + 1) % every == 0 or i == len(text) - 1:
                self.frame(hold)

    def key(self, text, wait=0.8):
        try:
            os.write(self.fd, text.encode())
        except OSError:
            pass
        self.pump(wait)

    def rows_html(self, trim):
        out, last = [], 0
        cursor = self.screen.cursor
        for y in range(self.rows):
            line = self.screen.buffer[y]
            spans = []
            for x in range(self.cols):
                ch = line[x]
                color = COLORS.get(ch.fg) or ("#" + ch.fg if len(ch.fg) == 6 else COLORS["default"])
                if ch.bold and ch.fg == "default":
                    color = "#ffffff"
                style = "color:%s;%s" % (color, "font-weight:700;" if ch.bold else "")
                if ch.reverse:
                    style = "color:%s;background:%s;" % (BACKGROUND, color)
                if (x, y) == (cursor.x, cursor.y) and not cursor.hidden:
                    style += "background:#f8f8f2;color:%s;" % BACKGROUND
                spans.append('<span style="%s">%s</span>' % (style, html.escape(ch.data or " ")))
                if ch.data.strip():
                    last = y
            out.append("".join(spans))
        if trim:
            out = out[:max(last, cursor.y) + 2]
        return out

    def shot(self, name):
        """A still of the screen as it stands, trimmed to its content, at 2x —
        lossless WebP, a third the size of the same PNG."""
        rows = self.rows_html(trim=True)
        page = PAGE.format(page_bg="transparent", bg=BACKGROUND, rows="\n".join(rows))
        width, height = int(self.cols * CHAR_W + 70), int(len(rows) * LINE_H + 100)
        png = tempfile.mktemp(suffix=".png")
        chrome_png(page.replace("transparent", "#ffffff00"), width, height, png, scale=2)
        path = os.path.join(IMAGES, name + ".webp")
        subprocess.run([MAGICK, png, "-define", "webp:lossless=true", "-define", "webp:method=6", path], check=True)
        os.unlink(png)
        print("wrote", os.path.relpath(path))

    def frame(self, hold_ms):
        """Records the screen as an animation frame shown for hold_ms. A frame that
        looks like the one before just extends it."""
        rows = "\n".join(self.rows_html(trim=False))
        if self.frames and self.frames[-1][0] == rows:
            self.frames[-1][1] += hold_ms
        else:
            self.frames.append([rows, hold_ms])

    def animation(self, name):
        """An animated WebP: lossless, so the text stays crisp, and a fraction
        of the size of a GIF of the same frames."""
        work = tempfile.mkdtemp()
        width, height = int(self.cols * CHAR_W + 70), int(self.rows * LINE_H + 100)
        args = [MAGICK, "-loop", "0"]
        for i, (rows, hold) in enumerate(self.frames):
            png = os.path.join(work, "%04d.png" % i)
            chrome_png(PAGE.format(page_bg="#ffffff", bg=BACKGROUND, rows=rows), width, height, png, scale=1)
            args += ["-delay", str(max(hold // 10, 2)), png]
        path = os.path.join(IMAGES, name + ".webp")
        subprocess.run(args + ["-define", "webp:lossless=true", "-define", "webp:method=6", path], check=True)
        shutil.rmtree(work)
        print("wrote", os.path.relpath(path), "(%d frames)" % len(self.frames))

    def close(self):
        try:
            os.kill(self.pid, 9)
            os.waitpid(self.pid, 0)
        except OSError:
            pass


def home_with(srs, tweak=None):
    """A throwaway SRS_HOME, optionally with progress already in it."""
    home = tempfile.mkdtemp(prefix="srs-media-")
    if tweak:
        os.environ["SRS_HOME"] = home
        srs.HOME = home
        srs.STATE_PATH = os.path.join(home, "state.json")
        state = srs.load_state()
        tweak(state)
        srs.save_state(state)
    return home


def only_due(module, tid):
    def tweak(state):
        m = state["modules"][module]
        m["primer_seen"] = True
        for t, c in m["cards"].items():
            c.update(seen=1, box=2, due=0 if t == tid else 10 ** 12)
    return tweak


def first_contact(srs):
    """A first-ever popup: the gate, the primer, a lesson with its rehearsal,
    then the card itself — and the offer of the next module."""
    t = Terminal([SRS, "run", "keys", "--popup"], {"SRS_HOME": home_with(srs)}, rows=36)
    t.pump(1.6)
    t.shot("popup")
    t.frame(1800)
    t.key("\r", 0.9)
    t.shot("primer-terminal-editing")
    t.frame(5000)
    t.key("\r", 0.9)
    t.frame(3500)
    t.type("\x0b", hold=900)
    t.shot("lesson-and-rehearsal")
    t.key("\r", 0.8)
    t.frame(1500)
    t.key("\r", 0.9)
    t.frame(2200)
    t.type("\x0b", hold=700)
    t.key("\r", 0.9)
    t.frame(4500)
    t.shot("card-graded")
    t.animation("first-contact")
    t.close()


def stash_card(srs):
    """The stash-and-restore card, solved at par."""
    t = Terminal([SRS, "run", "keys"], {"SRS_HOME": home_with(srs, only_due("keys", "stash"))}, rows=24)
    t.pump(1.2)
    card = srs.KEYS.templates["stash"].gen(srs.random.Random(int(SEED)))
    t.frame(2600)
    first, restore = card["phases"]
    t.type("\x15", hold=900)
    t.type(first["route"][1:], every=3, gap=0.04, hold=90)
    t.frame(500)
    t.key("\r", 0.6)
    t.frame(900)
    t.type("\x19", hold=1100)
    t.key("\r", 0.9)
    t.frame(5000)
    t.animation("stash-and-restore")
    t.close()


def lateral(srs):
    """The lateral primer and a worked example, from srs learn."""
    t = Terminal([SRS, "learn", "lateral", "as-of"], {"SRS_HOME": home_with(srs)}, rows=80)
    t.pump(1.5)
    t.key("\r", 0.8)
    t.key("\r", 3.0)
    t.shot("lateral-worked-example")
    t.close()
    t = Terminal([SRS, "learn", "lateral"], {"SRS_HOME": home_with(srs)}, rows=44)
    t.pump(1.5)
    t.shot("primer-lateral-joins")
    t.close()


def sql_card(srs):
    """An as-of card answered in vim: CROSS JOIN first, which loses the sale
    from before any price, then fixed to LEFT JOIN … ON true."""
    tweak = only_due("lateral", "as-of")
    home = home_with(srs, tweak)
    sc = srs.make_scenario(srs.LATERAL.templates["as-of"].gen, srs.random.Random(int(SEED)), tempfile.mkdtemp())
    wrong = srs.pretty_sql(sc["solution"].replace("LEFT JOIN LATERAL", "CROSS JOIN LATERAL").replace(" ON true", ""))
    editor = "vim -u NONE -N -i NONE"
    t = Terminal([SRS, "run", "lateral"], {"SRS_HOME": home, "EDITOR": editor}, rows=46)
    t.pump(3.0)
    t.shot("sql-card-asked")
    t.frame(6000)
    t.key("\r", 1.2)
    t.frame(1200)
    t.key("o", 0.3)
    t.type(wrong, every=14, gap=0.012, hold=140)
    t.frame(1500)
    t.key("\x1b", 1.3)
    t.type(":wq", hold=300)
    t.key("\r", 3.0)
    t.shot("sql-wrong-attempt")
    t.frame(6000)
    t.key("\r", 1.2)
    t.frame(1000)
    for command in [":%s/CROSS JOIN/LEFT JOIN/", ":%s/^) r$/) r ON true/"]:
        t.type(command, every=2, gap=0.03, hold=80)
        t.key("\r", 0.5)
        t.frame(1600)
    t.type(":wq", hold=300)
    t.key("\r", 3.0)
    t.shot("sql-solved")
    t.frame(6000)
    t.animation("sql-card")
    t.close()


def main():
    os.makedirs(IMAGES, exist_ok=True)
    srs = load_srs()
    first_contact(srs)
    stash_card(srs)
    lateral(srs)
    sql_card(srs)


if __name__ == "__main__":
    main()
