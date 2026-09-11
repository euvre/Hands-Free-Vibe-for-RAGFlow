#!/usr/bin/env python3
"""cdp-drive.py — minimal Chrome DevTools Protocol driver for the Feishu
developer-console automation (browser MCP profile is busy with the issue
line, so this uses a dedicated chrome instance on port 9333).

Subcommands:
  snap                        → print page title+url and save a screenshot
  eval <js>                   → evaluate JS in the page (prints result)
  shot <file>                 → save screenshot to file
  wait-text <text> [timeout]  → block until text appears on page
  click-text <text>           → click the element whose text matches
  input-text <selector> <val> → set input value via JS
"""
import base64
import json
import sys
import time
import urllib.request

import websocket

PORT = 9333


def _ws_url():
    for _ in range(30):
        try:
            r = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/json/list", timeout=2).read())
            pages = [t for t in r if t.get("type") == "page"]
            if pages:
                return pages[0]["webSocketDebuggerUrl"]
        except Exception:
            pass
        time.sleep(1)
    raise SystemExit("no debuggable page on port %d" % PORT)


class CDP:
    def __init__(self):
        self.ws = websocket.create_connection(_ws_url(), timeout=30)
        self.mid = 0

    def call(self, method, params=None):
        self.mid += 1
        self.ws.send(json.dumps({"id": self.mid, "method": method, "params": params or {}}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == self.mid:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg.get("result", {})

    def eval(self, expr):
        r = self.call("Runtime.evaluate", {
            "expression": expr, "returnByValue": True, "awaitPromise": True})
        return r.get("result", {}).get("value")


def snap(cdp):
    info = cdp.eval("JSON.stringify({title: document.title, url: location.href})")
    print(info)


def shot(cdp, path):
    cdp.call("Page.enable")
    data = cdp.call("Page.captureScreenshot", {"format": "png"})["data"]
    open(path, "wb").write(base64.b64decode(data))
    print("saved", path)


def wait_text(cdp, text, timeout_s=120):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        found = cdp.eval(
            "document.body && document.body.innerText.includes(%s)" % json.dumps(text))
        if found:
            print("found:", text)
            return True
        time.sleep(2)
    print("timeout waiting for:", text)
    return False


def click_text(cdp, text):
    js = """(() => {
      const want = %s;
      const els = [...document.querySelectorAll('button, [role=button], a, span, div')];
      const el = els.find(e => e.innerText && e.innerText.trim() === want && e.offsetParent);
      if (!el) return 'NOT FOUND: ' + want;
      el.scrollIntoView({block: 'center'}); el.click();
      return 'clicked: ' + want;
    })()""" % json.dumps(text)
    print(cdp.eval(js))


def input_text(cdp, selector, value):
    js = """(() => {
      const el = document.querySelector(%s);
      if (!el) return 'NOT FOUND';
      el.focus();
      const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
      setter.call(el, %s);
      el.dispatchEvent(new Event('input', {bubbles: true}));
      return 'set';
    })()""" % (json.dumps(selector), json.dumps(value))
    print(cdp.eval(js))


def main():
    args = sys.argv[1:]
    cdp = CDP()
    cmd = args[0]
    if cmd == "snap":
        snap(cdp)
    elif cmd == "eval":
        out = cdp.eval(args[1])
        print(json.dumps(out, ensure_ascii=False)[:3000] if not isinstance(out, str) else out[:3000])
    elif cmd == "shot":
        shot(cdp, args[1])
    elif cmd == "wait-text":
        wait_text(cdp, args[1], int(args[2]) if len(args) > 2 else 120)
    elif cmd == "click-text":
        click_text(cdp, args[1])
    elif cmd == "input-text":
        input_text(cdp, args[1], args[2])
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
