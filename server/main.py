"""Loop 后端入口：API + 静态托管 Flutter 产物。"""
from __future__ import annotations

import os
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles

from db import init_db
from routes import router

app = FastAPI(title="Loop", version="0.1.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

init_db()
app.include_router(router)

WEB = Path(os.environ.get("LOOP_WEB_DIR") or (Path(__file__).resolve().parent / "web"))
PLACEHOLDER = """<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<title>Loop</title>
<style>
 body{font-family:system-ui,-apple-system,"Segoe UI",sans-serif;max-width:640px;margin:80px auto;padding:0 24px;line-height:1.7;color:#1f2937}
 code{background:#f3f4f6;padding:2px 6px;border-radius:4px}
 .box{border:1px solid #e5e7eb;border-radius:12px;padding:20px 24px;margin-top:20px}
</style>
<h1>Loop 后端已启动</h1>
<p>还没有 Flutter 前端构建产物（<code>server/web</code> 不存在）。</p>
<div class="box">
<p>构建一次即可：</p>
<pre><code>cd app
flutter pub get
flutter build web --release
xcopy /E /I /Y build\\web ..\\server\\web</code></pre>
<p>然后刷新本页。</p>
</div>
<p style="color:#6b7280;margin-top:32px">API 文档：<a href="/docs">/docs</a> · 健康检查：<a href="/api/health">/api/health</a></p>
</html>"""


@app.get("/", include_in_schema=False)
def index():
    index_file = WEB / "index.html"
    if index_file.exists():
        return RedirectResponse("/index.html")
    return HTMLResponse(PLACEHOLDER)


if WEB.exists() and (WEB / "index.html").exists():
    app.mount("/", StaticFiles(directory=str(WEB), html=True), name="web")
