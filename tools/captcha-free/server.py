#!/usr/bin/env python3
"""captcha-free: a single MCP server bundling free, open-source CAPTCHA solvers.

Tools, each backed by a free library (no paid API):
  solve_image_ocr     distorted image/text captchas   -> ddddocr
  solve_turnstile     Cloudflare Turnstile/Interstitial-> playwright-captcha + camoufox
  solve_hcaptcha      hCaptcha                         -> hcaptcha-challenger
  solve_recaptcha_v2  reCAPTCHA v2                      -> PyPasser (audio)

Backends load lazily, so the server starts (and lists its tools) even before
the browser/model dependencies are installed; a tool returns a clear error if
its backend isn't ready. Install extras with:  pip install -r requirements.txt
then: python -m camoufox fetch  (downloads the stealth browser)
"""
import base64
import io
import sys

try:
    from mcp.server.fastmcp import FastMCP
except Exception:  # pragma: no cover - import guidance
    sys.stderr.write("missing dep: pip install 'mcp[cli]<2'\n")
    raise

mcp = FastMCP("captcha-free")

_ddddocr = None


def _ocr_engine():
    global _ddddocr
    if _ddddocr is None:
        import ddddocr  # type: ignore
        _ddddocr = ddddocr.DdddOcr(show_ad=False)
    return _ddddocr


@mcp.tool()
def solve_image_ocr(image_base64: str = "", image_path: str = "") -> str:
    """Read the text in a distorted image/text CAPTCHA (base64 PNG/JPEG or a file path)."""
    try:
        if image_path:
            with open(image_path, "rb") as f:
                data = f.read()
        elif image_base64:
            data = base64.b64decode(image_base64.split(",")[-1])
        else:
            return "error: pass image_base64 or image_path"
        return _ocr_engine().classification(data)
    except ModuleNotFoundError:
        return "error: ddddocr not installed (pip install ddddocr)"
    except Exception as e:  # noqa: BLE001
        return f"error: {e}"


@mcp.tool()
async def solve_turnstile(url: str, timeout_s: int = 60) -> str:
    """Pass a Cloudflare Turnstile / Interstitial challenge at url; returns the cf token or status."""
    try:
        from camoufox.async_api import AsyncCamoufox  # type: ignore
        from playwright_captcha import CaptchaType, ClickSolver, FrameworkType  # type: ignore
    except ModuleNotFoundError as e:
        return f"error: backend not installed ({e.name}); see requirements.txt and run 'python -m camoufox fetch'"
    try:
        async with AsyncCamoufox(headless=True) as browser:
            page = await browser.new_page()
            await page.goto(url)
            async with ClickSolver(framework=FrameworkType.CAMOUFOX, page=page) as solver:
                await solver.solve_captcha(captcha_container=page, captcha_type=CaptchaType.CLOUDFLARE_TURNSTILE)
            token = await page.evaluate(
                "() => { const e=document.querySelector('[name=cf-turnstile-response]'); return e && e.value; }"
            )
            return token or "solved (no token field found; challenge likely passed)"
    except Exception as e:  # noqa: BLE001
        return f"error: {e}"


@mcp.tool()
async def solve_hcaptcha(url: str, timeout_s: int = 180) -> str:
    """Solve an hCaptcha challenge at url (hcaptcha-challenger + camoufox).

    Needs GEMINI_API_KEY set (free tier from Google AI Studio) — recent
    hcaptcha-challenger uses Gemini for the visual reasoning."""
    try:
        from camoufox.async_api import AsyncCamoufox  # type: ignore
        from hcaptcha_challenger import AgentV, AgentConfig  # type: ignore
    except ModuleNotFoundError as e:
        return f"error: backend not installed ({e.name}); pip install hcaptcha-challenger camoufox, then 'python -m camoufox fetch'"
    try:
        async with AsyncCamoufox(headless=True) as browser:
            page = await browser.new_page()
            await page.goto(url)
            agent = AgentV(page=page, agent_config=AgentConfig(DISABLE_BEZIER_TRAJECTORY=True))
            await agent.robotic_arm.click_checkbox()
            await agent.wait_for_challenge()
            if getattr(agent, "cr_list", None):
                cr = agent.cr_list[-1]
                tok = getattr(cr, "generated_pass_UUID", None) or getattr(cr, "c", None)
                return str(tok) if tok else "solved (see agent response)"
            return "solved (no CaptchaResponse captured)"
    except Exception as e:  # noqa: BLE001
        return f"error: {e} (is GEMINI_API_KEY set?)"


@mcp.tool()
def solve_recaptcha_v2(url: str, timeout_s: int = 120) -> str:
    """Solve a reCAPTCHA v2 checkbox via its audio challenge (PyPasser + undetected-chromedriver)."""
    try:
        import undetected_chromedriver as uc  # type: ignore
        from pypasser import reCaptchaV2  # type: ignore
    except ModuleNotFoundError as e:
        return f"error: backend not installed ({e.name}); pip install PyPasser undetected-chromedriver"
    driver = None
    try:
        opts = uc.ChromeOptions()
        opts.add_argument("--headless=new")
        opts.add_argument("--no-sandbox")
        driver = uc.Chrome(options=opts)
        driver.set_page_load_timeout(timeout_s)
        driver.get(url)
        ok = reCaptchaV2(driver)
        if not ok:
            return "error: could not solve the reCAPTCHA (challenge may have changed)"
        token = driver.execute_script(
            "return (document.getElementById('g-recaptcha-response')||{}).value || '';"
        )
        return token or "solved (no g-recaptcha-response token found)"
    except Exception as e:  # noqa: BLE001
        return f"error: {e}"
    finally:
        if driver is not None:
            try:
                driver.quit()
            except Exception:  # noqa: BLE001
                pass


if __name__ == "__main__":
    mcp.run()
