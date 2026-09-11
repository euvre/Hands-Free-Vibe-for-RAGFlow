#!/usr/bin/env python3
"""issue-vision.py — transcribe issue screenshots to text via Kimi vision.

Only meaningful under the `glm` model profile (text-only main agent): for
every image under issues/attachments/<message_id>/ a sibling <stem>.md
description is written (img_01.png -> img_01.md, reply_02.jpg -> reply_02.md).
Descriptions fresher than the image are kept; failures are logged and skipped
so the pre-pass never blocks. --force re-transcribes everything.
"""
import base64
import glob
import json
import os
import signal
import sys
import time
import urllib.error
import urllib.request

DIR = os.path.dirname(os.path.abspath(__file__))
ATTACH_DIR = os.path.join(DIR, "attachments")
CONFIG = os.path.join(DIR, "config")

VIDEO_EXTS = (".mp4", ".m4v", ".mov", ".mkv", ".webm", ".avi")

PROMPT = (
    "你是缺陷报告截图转写器。请用中文完整转写这张截图，供无法看图的工程师使用：\n"
    "1) 页面/弹窗结构与各控件的可见状态；\n"
    "2) 所有可见文字逐字转写（标题、按钮、输入框、表格、报错与日志文本，保留原文，不要翻译）；\n"
    "3) 明显异常之处（红字报错、空数据、错位、加载失败图标等）。\n"
    "只输出描述正文，不要加评论，不要用 Markdown 代码块包裹。"
)

VIDEO_PROMPT = (
    "你是缺陷报告录屏转写器。请用中文完整转写这段操作录屏，供无法观看视频的工程师使用：\n"
    "1) 按时间顺序描述用户的关键操作（点击了什么、输入了什么、切换到哪个页面）；\n"
    "2) 界面随操作发生的变化（弹窗出现、页面跳转、加载状态）；\n"
    "3) 所有可见文字逐字转写（标题、按钮、输入框内容、表格、报错与日志文本，保留原文，不要翻译）；\n"
    "4) 明显异常之处（红字报错、空数据、错位、加载失败图标等）及其出现时机。\n"
    "只输出描述正文，不要加评论，不要用 Markdown 代码块包裹。"
)


def load_config():
    cfg = {}
    for line in open(CONFIG):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip()
    return cfg


def probe_media_kind(path):
    """Classify an attachment by magic bytes: 'image', 'video', or None for
    anything the Kimi vision API cannot ingest (other binaries — a stray file
    saved with an image extension would otherwise abort the pass with HTTP 400)."""
    with open(path, "rb") as f:
        head = f.read(12)
    if head[:4] == b"\x89PNG" or head[:2] == b"\xff\xd8":
        return "image"
    if head[4:8] == b"ftyp" or head[:4] == b"\x1a\x45\xdf\xa3":
        return "video"  # mp4/mov/m4v (ISO container) or webm/mkv
    return None


def transcribe(path, cfg, media_kind):
    with open(path, "rb") as f:
        data = f.read()
    b64 = base64.b64encode(data).decode()
    if media_kind == "video":
        mime = "video/webm" if data[:4] == b"\x1a\x45\xdf\xa3" else "video/mp4"
        media_part = {"type": "video_url",
                      "video_url": {"url": f"data:{mime};base64,{b64}"}}
        prompt = VIDEO_PROMPT
        timeout = 300  # video understanding takes far longer than one frame
    else:
        mime = "image/jpeg" if data[:2] == b"\xff\xd8" else "image/png"
        media_part = {"type": "image_url",
                      "image_url": {"url": f"data:{mime};base64,{b64}"}}
        prompt = PROMPT
        timeout = 120
    body = {
        "model": cfg.get("KIMI_VISION_MODEL", "k3-256k"),
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": prompt},
                media_part,
            ],
        }],
        "max_tokens": 2048,
        # NOTE: no temperature — the Kimi coding endpoint only allows 1 and
        # rejects anything else with HTTP 400 "invalid temperature".
    }
    url = cfg.get("KIMI_BASE_URL", "https://api.kimi.com/coding/v1").rstrip("/")
    req = urllib.request.Request(url + "/chat/completions", method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", f"Bearer {cfg['KIMI_API_KEY']}")
    with urllib.request.urlopen(req, data=json.dumps(body).encode(), timeout=timeout) as resp:
        r = json.loads(resp.read())
    text = r["choices"][0]["message"]["content"]
    if isinstance(text, list):  # some providers return content parts
        text = "".join(p.get("text", "") for p in text if isinstance(p, dict))
    return (text or "").strip()


def main():
    force = "--force" in sys.argv
    cfg = load_config()
    if not cfg.get("KIMI_API_KEY"):
        print("vision: KIMI_API_KEY missing in config, nothing to do")
        return 0
    done = skipped = failed = 0
    media = sorted(glob.glob(os.path.join(ATTACH_DIR, "*", "*.png"))
                   + glob.glob(os.path.join(ATTACH_DIR, "*", "*.jpg"))
                   + [p for ext in VIDEO_EXTS
                      for p in glob.glob(os.path.join(ATTACH_DIR, "*", "*" + ext))])
    for img in media:
        desc = os.path.splitext(img)[0] + ".md"
        if (not force and os.path.exists(desc)
                and os.path.getmtime(desc) >= os.path.getmtime(img)):
            skipped += 1
            continue
        kind = probe_media_kind(img)
        if kind is None:
            # a binary the vision API cannot ingest (zip/pdf saved with an
            # image extension, etc.) — a local fact, not an API error: skip
            # just this file; other media in the pass must still be handled.
            print(f"vision: {os.path.relpath(img, DIR)}: not an image or video, skipping")
            continue
        try:
            # Hard wall-clock cap per transcribe() call. urllib's timeout only
            # bounds individual socket reads: a server that dribbles bytes (or
            # holds the connection open) keeps the call alive indefinitely.
            # SIGALRM aborts the call outright so the pass always terminates.
            def _alarm_handler(signum, frame):
                raise TimeoutError("vision call exceeded wall-clock cap")

            cap = 330 if kind == "video" else 150
            signal.signal(signal.SIGALRM, _alarm_handler)
            # 429 backoff: the Kimi vision endpoint rate-limits bursts. Retry
            # the same media after a backoff, up to 3 times; other errors raise.
            text = ""
            for attempt_429 in range(4):
                signal.alarm(cap)
                try:
                    text = transcribe(img, cfg, kind)
                    break
                except urllib.error.HTTPError as e:
                    if e.code == 429 and attempt_429 < 3:
                        print(f"vision: {os.path.relpath(img, DIR)}: 429 rate-limited, "
                              f"backing off 30s ({attempt_429 + 1}/3)", flush=True)
                        time.sleep(30)
                        continue
                    raise
                finally:
                    signal.alarm(0)
            if not text:
                raise ValueError("empty transcription")
            with open(desc, "w") as f:
                f.write(text + "\n")
            done += 1
        except Exception as e:
            failed += 1
            print(f"vision: {os.path.relpath(img, DIR)}: {e}")
            break  # quota/network errors won't heal within this pass
        time.sleep(0.5)
    print(f"vision transcribed={done} skipped={skipped} failed={failed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
