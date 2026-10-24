"""t4 浮窗 E2E 专用 OpenAI 兼容 mock（127.0.0.1:9999）。

在 docs/streaming-evidence/tools/mock_llm.py 基础上扩展：
- 记录每次请求到 MOCK_LOG（JSONL），用于断言 image_url/data URI 是否随问题发送；
- ASCII 触发词（slow/long/empty/error/tool/plan/screenshot），方便真实窗口键盘输入；
- 中文触发词保持兼容（慢速/长回复/空回复/失败/文件/计划/截图）。

stdlib only，不依赖第三方包。
"""
from __future__ import annotations

import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SLOW_DELAY = 0.22
LOG_PATH = os.environ.get("MOCK_LOG", os.path.join(os.environ.get("TEMP", "."), "mock_requests.jsonl"))
LONG = None


def long_text() -> str:
    global LONG
    if LONG is not None:
        return LONG
    block = (
        "## 矩阵的秩\n\n"
        "矩阵的秩是行阶梯形中非零行的个数，记作 $r(A)$。它满足 "
        "$r(A)=\\dim\\operatorname{col}(A)=\\dim\\operatorname{row}(A)$，"
        "并且 $r(AB)\\le \\min(r(A),r(B))$。\n\n"
        "```dart\n"
        "int rankOf(List<List<double>> m) {\n"
        "  var r = 0;\n"
        "  for (var c = 0; c < m.first.length; c++) {\n"
        "    final pivot = m.indexWhere((row) => row[c] != 0);\n"
        "    if (pivot < 0) continue;\n"
        "    r++;\n"
        "  }\n"
        "  return r;\n"
        "}\n"
        "```\n\n"
        "> 引用：行秩与列秩相等，所以矩阵的秩没有歧义。\n\n"
        "| 操作 | 是否改变秩 |\n|---|---|\n"
        "| 初等行变换 | 否 |\n| 转置 | 否 |\n| 左乘可逆矩阵 | 否 |\n\n"
        "- 列表项 1：初等行变换不改变秩\n"
        "- 列表项 2：$r(A+B)\\le r(A)+r(B)$\n"
        "- 列表项 3：可逆矩阵乘上去不改变秩\n\n"
    )
    LONG = "# 长回复渲染检查（浮窗）\n\n" + block * 22
    return LONG


def user_parts(messages):
    """返回 (text, image_count, image_sample_len)。"""
    for msg in reversed(messages):
        if msg.get("role") != "user":
            continue
        content = msg.get("content")
        if isinstance(content, str):
            return content, 0, 0
        if isinstance(content, list):
            texts, images = [], 0
            sample = 0
            for part in content:
                if not isinstance(part, dict):
                    continue
                if part.get("type") == "text":
                    texts.append(part.get("text", ""))
                elif part.get("type") == "image_url":
                    images += 1
                    url = ((part.get("image_url") or {}).get("url") or "")
                    sample = max(sample, len(url))
            return " ".join(texts), images, sample
    return "", 0, 0


def called_tools(messages):
    names = set()
    for msg in messages:
        if msg.get("role") == "tool":
            names.add("tool_result")
        for call in msg.get("tool_calls") or []:
            fn = call.get("function") or {}
            if fn.get("name"):
                names.add(fn["name"])
    return names


def call_count(messages, name):
    count = 0
    for msg in messages:
        for call in msg.get("tool_calls") or []:
            fn = call.get("function") or {}
            if fn.get("name") == name:
                count += 1
    return count


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) or b"{}"
        try:
            body = json.loads(raw)
        except Exception:
            body = {}
        messages = body.get("messages", [])
        called = called_tools(messages)
        user, image_count, image_sample = user_parts(messages)
        self._log({
            "at": time.time(),
            "path": self.path,
            "user": user[:200],
            "images": image_count,
            "image_data_len": image_sample,
            "messages": len(messages),
            "stream": body.get("stream"),
        })

        low = user.lower()
        if "error500" in low or "失败" in user:
            payload = json.dumps({"error": {"message": "mock upstream failure", "type": "server_error"}},
                                 ensure_ascii=False).encode()
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        def send(obj, delay=0.01):
            try:
                self.wfile.write(f"data: {json.dumps(obj, ensure_ascii=False)}\n\n".encode())
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                raise SystemExit
            time.sleep(delay)

        def tool(name, args):
            send({"choices": [{"index": 0, "delta": {
                "role": "assistant", "content": "",
                "tool_calls": [{"index": 0, "id": f"call_{name}", "type": "function",
                                "function": {"name": name, "arguments": ""}}],
            }}]})
            raw_args = json.dumps(args, ensure_ascii=False)
            for i in range(0, len(raw_args), 40):
                send({"choices": [{"index": 0, "delta": {"tool_calls": [
                    {"index": 0, "function": {"arguments": raw_args[i:i + 40]}}]}}]})
            send({"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}],
                  "usage": {"prompt_tokens": 120, "completion_tokens": 30}})

        def text(value, size=6, delay=0.01, tokens=(260, 90)):
            for i in range(0, len(value), size):
                send({"choices": [{"index": 0, "delta": {"content": value[i:i + size]}}]}, delay)
            send({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                  "usage": {"prompt_tokens": tokens[0], "completion_tokens": tokens[1]}})

        try:
            if "多步笔记" in user:
                searched = call_count(messages, "search_materials")
                if searched < 9:
                    tool("search_materials", {"query": f"矩阵的秩 测试检索 {searched}"})
                elif "update_plan" not in called:
                    tool("update_plan", {"items": [
                        {"id": "1", "title": "检索矩阵的秩资料", "status": "done"},
                        {"id": "2", "title": "写测试笔记", "status": "in_progress"},
                        {"id": "3", "title": "回读核对", "status": "pending"},
                    ]})
                elif "create_note" not in called:
                    tool("create_note", {"title": "测试：矩阵的秩", "body": "# 测试笔记\n\n矩阵的秩。"})
                elif "list_notes" not in called:
                    tool("list_notes", {"limit": 5})
                else:
                    text("已完成：测试笔记已写入。")
            elif "tool" in low or "文件" in user or "审批" in user:
                if "fs_write" not in called:
                    tool("fs_write", {"path": "floating-approval.md", "content": "# floating approval\nok", "mode": "overwrite"})
                elif "fs_read" not in called:
                    tool("fs_read", {"path": "floating-approval.md"})
                else:
                    text("已写入并回读工作区文件 floating-approval.md。")
            elif "plan" in low or "计划" in user:
                if "update_plan" not in called:
                    tool("update_plan", {"items": [
                        {"id": "1", "title": "制定复习计划", "status": "in_progress"},
                        {"id": "2", "title": "创建待办", "status": "pending"},
                        {"id": "3", "title": "回读核对", "status": "pending"},
                    ]})
                elif "create_tasks" not in called:
                    tool("create_tasks", {"tasks": [
                        {"title": "复习特征值", "estimate_min": 30},
                        {"title": "做 3 道二次型题", "estimate_min": 40},
                    ]})
                else:
                    text("计划已执行：已创建待办并回读确认。")
            elif "empty" in low or "空回复" in user:
                send({"choices": [], "usage": {"prompt_tokens": 17, "completion_tokens": 0}})
            elif image_count and ("见附件" in user or not user.strip()):
                # 浮窗真实截图（无文字直接发送）→ 慢速流式，用于验证切换不中断/停止。
                text(
                    f"已收到 {image_count} 张截图附件（data URI 长度 {image_sample}）。"
                    "慢速回答：第一段内容和第二段内容，用于验证浮窗切换期间回答不中断、停止可用。",
                    size=4, delay=SLOW_DELAY, tokens=(300, 60),
                )
            elif image_count and "slow" in low:
                text(
                    f"已收到 {image_count} 张截图附件（data URI 长度 {image_sample}）。"
                    "慢速回答：第一段内容和第二段内容，用于验证浮窗切换期间回答不中断、停止可用。",
                    size=4, delay=SLOW_DELAY, tokens=(300, 60),
                )
            elif "screenshot" in low or "截图" in user or image_count:
                text(
                    f"已收到 {image_count} 张图片附件（data URI 长度 {image_sample}）。"
                    "这是悬浮窗截图问答的 mock 回答：$r(A)$ 与 $r(AB)\\le\\min(r(A),r(B))$。",
                    tokens=(300, 60),
                )
            elif "long" in low or "长回复" in user:
                text(long_text(), size=80, delay=0.002, tokens=(900, 1500))
            elif "slow" in low or "慢速" in user:
                text("慢速回答：第一段内容和第二段内容，用于验证浮窗切换期间回答不中断、停止可用。"
                     "这是第三段内容，足够长以覆盖多次形态切换的观测窗口。"
                     "这是第四段内容，停止按钮与流式增量都应保持可见。"
                     "这是第五段内容，最终正文必须完整且不重复。",
                     size=4, delay=SLOW_DELAY, tokens=(50, 10))
            elif "搜索" in user:
                tool("search_materials", {"query": "特征值"})
            else:
                text("直接回答：这是一条普通问答，不调用工具。$r(A)$ 公式渲染检查。")
        except SystemExit:
            raise
        except (BrokenPipeError, ConnectionResetError):
            return

        try:
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _log(self, record):
        try:
            with open(LOG_PATH, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(record, ensure_ascii=False) + "\n")
        except Exception:
            pass

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(os.environ.get("MOCK_PORT", "9999"))
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
