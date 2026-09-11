#!/usr/bin/env python3
# browser-login.py <base-url> <profile-dir> — session keep-alive for the
# persistent chrome profile the browser MCP will use. Runs headless chrome on
# that SAME profile, checks the session, and refreshes it through the
# sanctioned FORM login (1@1.com / 1 — the task file's hard-rule path, only
# script-driven; no API login, no token planting, no DB touch).
#
# Prints exactly one result line:
#   LOGIN_OK            session still valid — the LLM's login dance is skippable
#   LOGIN_REFRESHED     session was expired; form login re-established it
#   LOGIN_NEEDED        login did not stick — the LLM logs in via the MCP
#   LOGIN_FAILED ...    infra/DOM trouble — the LLM logs in via the MCP
# Runs BEFORE the LLM starts; never concurrently with the MCP's chrome
# (profile Singleton lock).
import sys

base, profile = sys.argv[1], sys.argv[2]


def main():
    from playwright.sync_api import sync_playwright

    def needs_login(page):
        return "login" in page.url or page.query_selector('input[name="password"]') is not None

    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            profile,
            channel="chrome",
            headless=True,
            args=["--no-sandbox", "--disable-dev-shm-usage"],
            viewport={"width": 1280, "height": 800},
            ignore_default_args=["--enable-automation"],
        )
        try:
            page = ctx.pages[0] if ctx.pages else ctx.new_page()
            page.goto(base, wait_until="domcontentloaded", timeout=30000)
            page.wait_for_timeout(4000)  # SPA settle + auth redirect
            if not needs_login(page):
                print("LOGIN_OK")
                return
            page.fill('input[name="email"]', "1@1.com")
            page.fill('input[name="password"]', "1")
            page.click('button[type="submit"]')
            try:
                page.wait_for_url(lambda u: "login" not in u, timeout=30000)
            except Exception:
                pass
            page.wait_for_timeout(3000)
            if needs_login(page):
                print("LOGIN_NEEDED form login did not stick")
            else:
                print("LOGIN_REFRESHED")
        finally:
            ctx.close()


try:
    main()
except Exception as e:  # infra/DOM trouble — never hard-fail the pre-flight
    print("LOGIN_FAILED " + str(e).replace("\n", " ")[:200])
