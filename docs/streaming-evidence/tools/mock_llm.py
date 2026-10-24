"""t4 流式开关 E2E 专用 OpenAI 兼容 mock（127.0.0.1:9999）。

在正式版 .tools/mock_llm.py 的基础上增加：空回复、长回复（Markdown/公式/代码块）、
慢速回复（验证运行中切换设置的请求级快照）。stdlib only。
"""
from __future__ import annotations

import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

SLOW = 0.15
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
        "- 列表项 1：初等行变换不改变秩\n"
        "- 列表项 2：$r(A+B)\\le r(A)+r(B)$\n"
        "- 列表项 3：可逆矩阵乘上去不改变秩\n\n"
    )
    LONG = "# 长回复渲染检查\n\n" + block * 18
    return LONG


def last_user_text(messages):
    for msg in reversed(messages):
        if msg.get("role") != "user":
            continue;
        content = msg.get("content")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            return " ".join(part.get("text", "") for part in content if isinstance(part, dict))
    return ""


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
    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        messages = body.get("messages", [])
        called = called_tools(messages)
        user = last_user_text(messages)

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def send(obj, delay=0.01):
            self.wfile.write(f"data: {json.dumps(obj, ensure_ascii=False)}\n\n".encode())
            self.wfile.flush()
            time.sleep(delay)

        def tool(name, args):
            send({"choices": [{"index": 0, "delta": {
                "role": "assistant", "content": "",
                "tool_calls": [{"index": 0, "id": f"call_{name}", "type": "function",
                                "function": {"name": name, "arguments": ""}}],
            }}]})
            raw = json.dumps(args, ensure_ascii=False)
            for i in range(0, len(raw), 40):
                send({"choices": [{"index": 0, "delta": {"tool_calls": [
                    {"index": 0, "function": {"arguments": raw[i:i + 40]}}]}}]})
            send({"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}],
                  "usage": {"prompt_tokens": 120, "completion_tokens": 30}})

        def text(value, size=6, delay=0.01, tokens=(260, 90)):
            for i in range(0, len(value), size):
                send({"choices": [{"index": 0, "delta": {"content": value[i:i + size]}}]}, delay)
            send({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                  "usage": {"prompt_tokens": tokens[0], "completion_tokens": tokens[1]}})

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
                tool("create_note", {"title": "测试：矩阵的秩", "body": "# 测试笔记\n\n矩阵的秩的一种算法是化为行阶梯形后数非零行。"})
            elif "list_notes" not in called:
                tool("list_notes", {"limit": 5})
            else:
                text("已完成：测试笔记已写入。")
        elif "文件" in user:
            if "fs_write" not in called:
                tool("fs_write", {"path": "agent-mock.md", "content": "# mock\nhello", "mode": "overwrite"})
            elif "fs_read" not in called:
                tool("fs_read", {"path": "agent-mock.md"})
            else:
                text("已写入并回读工作区文件 agent-mock.md。")
        elif "计划" in user:
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
            elif "list_tasks" not in called:
                tool("list_tasks", {})
            else:
                text("计划已执行：已创建 2 个待办并回读确认。")
        elif "空回复" in user:
            send({"choices": [], "usage": {"prompt_tokens": 17, "completion_tokens": 0}})
        elif "长回复" in user:
            text(long_text(), size=80, delay=0.002, tokens=(900, 1500))
        elif "慢速" in user:
            text("慢速回答：第一段内容和第二段内容，用于验证运行中切换设置的请求级快照。",
                 size=4, delay=SLOW, tokens=(50, 10))
        elif "搜索" in user:
            tool("search_materials", {"query": "特征值"})
        else:
            text("直接回答：这是一条普通问答，不调用工具。")

        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 9999), Handler).serve_forever()
