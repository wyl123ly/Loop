# -*- coding: utf-8 -*-
"""t4 浮窗截图问答 live E2E：真实 Backend（隔离副本 8767）+ mock LLM(9999) + 隔离数据。

覆盖：
  E1  健康/版本/隔离端口
  E2  截图 PNG 上传 → img_ 附件 → 随问题发送 → mock 收到 image_url → 流式回答
  E3  stream_output=true：多 delta；关闭：单 delta（同一 mock 文本）
  E4  运行中切换 stream_output：当前请求保持多 delta，下一条生效单 delta
  E5  停止：慢速生成中 cancel → cancelled / 无 done / 部分正文保留
  E6  审批 allow：fs_write 审批实时 → 允许 → 文件写入 + audit
  E7  审批 reject：拒绝 → 工具不执行、audit rejected
  E8  空回复：run → done，无 delta，无空助手消息
  E9  上游失败：run → error（无 done），服务不崩，下一条可用
  E10 无 Key：error 可读；恢复 Key 后可用
  E11 长回复：多 delta 拼接 == 落库 == 8160+ 字，含公式/代码块/表格；重载一致
  E12 计划/工具：plan/step 实时，最终完成
  E13 图片附件元数据落库（is_image/name）
  E14 会话与消息历史（供真实窗口重载与同会话可见断言）

用法：
  python e2e_floating.py full     # 全量
  python e2e_floating.py restart  # 重启后持久化检查（同一隔离数据目录）
结果写入 docs/floating-evidence/logs/e2e-floating-<mode>.json。
"""
from __future__ import annotations

import base64
import json
import os
import sys
import threading
import time
import urllib.request
from urllib.parse import quote

BASE = os.environ.get("LOOP_BASE", "http://127.0.0.1:8767")
MOCK = os.environ.get("MOCK_BASE", "http://127.0.0.1:9999")
EVID = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "logs")
MOCK_LOG = os.environ.get("MOCK_LOG", os.path.join(os.environ.get("TEMP", "."), "loop-floating-t4", "mock_requests.jsonl"))
WORKSPACE = os.environ.get("LOOP_T4_WORKSPACE", os.path.join(os.environ.get("TEMP", "."), "loop-floating-t4", "workspace"))

# 8x8 红色 PNG（截图/图片附件的代表；真实 UI 截图走 floating_ui.ps1 + PrintWindow）
PNG_8X8 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAFUlEQVR42mP8z8Dwn4EIwDiqkL4K"
    "AQB1oQr/9O0mQwAAAABJRU5ErkJggg=="
)

RESULTS = []
COUNTER = {"pass": 0, "fail": 0}


def record(name, ok, detail):
    entry = {"name": name, "ok": bool(ok), "detail": detail}
    RESULTS.append(entry)
    if ok:
        COUNTER["pass"] += 1
        print("PASS", name, "-", detail)
    else:
        COUNTER["fail"] += 1
        print("FAIL", name, "-", detail)
    return ok


def http(method, path, body=None, raw=None, content_type="application/json", headers=None, timeout=120):
    data = raw if raw is not None else (None if body is None else json.dumps(body).encode("utf-8"))
    hdrs = {"Content-Type": content_type}
    if headers:
        hdrs.update(headers)
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=hdrs)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        payload = resp.read()
        return json.loads(payload) if payload else {}


def get_settings():
    return http("GET", "/api/settings")


def put_settings(**kw):
    return http("PUT", "/api/settings", kw)


def sse_chat(body, on_event=None, timeout=240):
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(BASE + "/api/chat", data=data, method="POST",
                                 headers={"Content-Type": "application/json"})
    events = []
    event, data_lines = None, []
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for raw_line in resp:
            line = raw_line.decode("utf-8", "replace").rstrip("\n").rstrip("\r")
            if line == "":
                if event is not None or data_lines:
                    payload = json.loads("\n".join(data_lines)) if data_lines else {}
                    ev = {"event": event or "message", "data": payload, "t": round(time.time() - t0, 3)}
                    events.append(ev)
                    if on_event:
                        on_event(ev)
                event, data_lines = None, []
            elif line.startswith("event:"):
                event = line[6:].strip()
            elif line.startswith("data:"):
                data_lines.append(line[5:].strip())
    if event is not None or data_lines:
        payload = json.loads("\n".join(data_lines)) if data_lines else {}
        ev = {"event": event or "message", "data": payload, "t": round(time.time() - t0, 3)}
        events.append(ev)
        if on_event:
            on_event(ev)
    return events


def names(events):
    return [e["event"] for e in events]


def deltas(events):
    return [e["data"].get("text", "") for e in events if e["event"] == "delta"]


def first(events, name):
    for ev in events:
        if ev["event"] == name:
            return ev
    return None


def read_mock_log(limit=None):
    if not os.path.exists(MOCK_LOG):
        return []
    with open(MOCK_LOG, "r", encoding="utf-8") as fh:
        lines = fh.readlines()
    if limit is not None:
        lines = lines[-limit:]
    return [json.loads(line) for line in lines if line.strip()]


def create_conv(title):
    return http("POST", "/api/conversations", {"title": title})["id"]


def messages(cid):
    return http("GET", f"/api/conversations/{cid}/messages")


def upload_png(name="截图-t4.png"):
    return http("POST", "/api/upload", raw=PNG_8X8, content_type="image/png",
                headers={"X-Filename": quote(name)})


def setup(mode):
    if mode == "restart":
        return setup_restart()
    health = http("GET", "/api/health")
    record("E1 健康检查", health.get("ok") is True and os.environ.get("LOOP_T4_EXPECT_VERSION", "0.4.0") == health.get("version"),
           {"health": health, "base": BASE})
    settings = get_settings()
    record("E1b 初始流式默认", settings.get("stream_output") is True,
           {"stream_output": settings.get("stream_output"), "theme": settings.get("theme")})

    put_settings(api_key="test-key", base_url=MOCK, model="mock")
    put_settings(stream_output=True, theme="dark", auto_check_updates=False)
    http("PUT", "/api/agent/settings", {"workspace_path": WORKSPACE})
    os.makedirs(WORKSPACE, exist_ok=True)
    record("E1c 配置 mock 模型", get_settings().get("base_url") == MOCK,
           {"base_url": get_settings().get("base_url"), "workspace": WORKSPACE})

    # E2 图片上传 + 截图问答（流式）
    shot = upload_png()
    record("E2a PNG 上传为 img_ 附件", str(shot.get("id", "")).startswith("img_") and shot.get("kind") == "image", shot)
    cid = create_conv("浮窗截图问答 E2E")
    log_before = len(read_mock_log())
    events = sse_chat({
        "conversation_id": cid,
        "text": "请看这张截图，解释一下公式",
        "attachments": [shot["id"]],
    })
    text = "".join(deltas(events))
    record("E2b SSE run→delta→done", names(events)[:1] == ["run"] and names(events)[-1] == "done" and len(deltas(events)) > 1,
           {"events": names(events), "deltas": len(deltas(events)), "t": [e["t"] for e in events][:3]})
    record("E2c mock 收到图片 data URI", "已收到 1 张图片附件" in text, {"text": text[:160]})
    log = read_mock_log()[log_before:]
    img_rec = [r for r in log if r.get("images") == 1]
    record("E2d 请求体 image_url 计数/长度", bool(img_rec) and img_rec[-1].get("image_data_len", 0) > 100,
           img_rec[-1] if img_rec else {"log": log[-1:]})
    msgs = messages(cid)
    user = [m for m in msgs if m["role"] == "user"]
    assistant = [m for m in msgs if m["role"] == "assistant"]
    record("E2e 落库附件元数据 is_image", bool(user) and any(a.get("id") == shot["id"] and a.get("is_image") for a in user[-1].get("attachments", [])),
           {"attachments": user[-1].get("attachments") if user else None})
    record("E2f 落库助手正文一致", bool(assistant) and assistant[-1]["content"] == text,
           {"stored_len": len(assistant[-1]["content"]) if assistant else 0, "delta_len": len(text)})

    # E3 stream on/off
    put_settings(stream_output=True)
    cid_on = create_conv("stream-on")
    on_events = sse_chat({"conversation_id": cid_on, "text": "普通问答-开启流式"})
    put_settings(stream_output=False)
    cid_off = create_conv("stream-off")
    off_events = sse_chat({"conversation_id": cid_off, "text": "普通问答-关闭流式"})
    joined_on = "".join(deltas(on_events))
    joined_off = "".join(deltas(off_events))
    record("E3a stream=true 多 delta", len(deltas(on_events)) > 1 and on_events[-1]["event"] == "done",
           {"deltas": len(deltas(on_events))})
    record("E3b stream=false 单 delta", len(deltas(off_events)) == 1 and off_events[-1]["event"] == "done",
           {"deltas": len(deltas(off_events))})
    record("E3c 两种模式正文一致", joined_on == joined_off, {"len": len(joined_on)})

    # E4 运行中切换（请求级快照）
    put_settings(stream_output=True)
    cid_mid = create_conv("stream-mid-switch")
    state = {"deltas": 0, "run_id": None}

    def on_ev(ev):
        if ev["event"] == "run":
            state["run_id"] = ev["data"]["run_id"]
        if ev["event"] == "delta":
            state["deltas"] += 1
            if state["deltas"] == 1:
                put_settings(stream_output=False)

    mid_events = sse_chat({"conversation_id": cid_mid, "text": "慢速回答-运行中切换"}, on_event=on_ev)
    record("E4a 运行中切换不影响当前 run", len(deltas(mid_events)) > 1 and mid_events[-1]["event"] == "done",
           {"deltas": len(deltas(mid_events))})
    next_events = sse_chat({"conversation_id": cid_mid, "text": "普通问答-切换后下一条"})
    record("E4b 下一条按关闭生效（单 delta）", len(deltas(next_events)) == 1 and get_settings().get("stream_output") is False,
           {"deltas": len(deltas(next_events)), "setting": get_settings().get("stream_output")})

    # E5 停止
    put_settings(stream_output=True)
    cid_stop = create_conv("stop")
    stop_state = {"run_id": None, "deltas": 0}

    def on_stop(ev):
        if ev["event"] == "run":
            stop_state["run_id"] = ev["data"]["run_id"]
        if ev["event"] == "delta":
            stop_state["deltas"] += 1
            if stop_state["deltas"] == 2 and stop_state["run_id"] is not None:
                try:
                    http("POST", "/api/agent/cancel", {"run_id": stop_state["run_id"]})
                except Exception as exc:  # pragma: no cover
                    print("cancel failed", exc)

    stop_events = sse_chat({"conversation_id": cid_stop, "text": "慢速回答-停止"}, on_event=on_stop)
    stop_text = "".join(deltas(stop_events))
    stop_msgs = messages(cid_stop)
    assistant = [m for m in stop_msgs if m["role"] == "assistant"]
    record("E5a 停止 → cancelled 且无 done", "cancelled" in names(stop_events) and "done" not in names(stop_events),
           {"events": names(stop_events), "deltas": len(deltas(stop_events))})
    record("E5b 部分正文保留", bool(assistant) and assistant[-1]["content"] == stop_text and len(stop_text) > 0,
           {"stored": assistant[-1]["content"][:80] if assistant else None})
    next_events = sse_chat({"conversation_id": cid_stop, "text": "停止后继续可用"})
    record("E5c 停止后下一条正常", next_events[-1]["event"] == "done", {"events": names(next_events)[:4]})

    # E6 审批 allow（审批事件在 SSE 流中阻塞，必须在回调里放行）
    cid_appr = create_conv("approval-allow")
    appr_state = {"approval": None}

    def on_appr(ev):
        if ev["event"] == "approval" and appr_state["approval"] is None:
            appr_state["approval"] = ev
            try:
                http("POST", "/api/agent/approve", {"run_id": ev["data"]["run_id"], "allow": True})
            except Exception as exc:  # pragma: no cover
                print("approve failed", exc)

    appr_events = sse_chat({"conversation_id": cid_appr, "text": "tool approval allow"}, on_event=on_appr)
    appr = appr_state["approval"]
    record("E6a 审批事件实时", appr is not None and appr["data"].get("tool") == "fs_write",
           {"approval": appr["data"] if appr else None})
    if appr:
        appr_msgs = messages(cid_appr)
        audit = http("GET", "/api/audit?limit=20")
        wrote = os.path.exists(os.path.join(WORKSPACE, "floating-approval.md"))
        record("E6b allow 后文件写入 + audit", wrote and audit and any(a.get("tool") == "fs_write" and a.get("approval") == "approved" for a in audit),
               {"file": os.path.join(WORKSPACE, "floating-approval.md"), "audit": audit[:1]})
        record("E6c 审批后回答完成", len(deltas(appr_events)) > 0 and appr_events[-1]["event"] == "done",
               {"deltas": len(deltas(appr_events)), "events": names(appr_events)[-4:]})
    else:
        record("E6b allow 后文件写入 + audit", False, "no approval event")
        record("E6c 审批后回答完成", False, "no approval event")

    # E7 审批 reject
    cid_rej = create_conv("approval-reject")
    rej_state = {"approval": None}

    def on_rej(ev):
        if ev["event"] == "approval" and rej_state["approval"] is None:
            rej_state["approval"] = ev
            try:
                http("POST", "/api/agent/approve", {"run_id": ev["data"]["run_id"], "allow": False})
            except Exception as exc:  # pragma: no cover
                print("reject failed", exc)

    reject_events = sse_chat({"conversation_id": cid_rej, "text": "tool approval reject"}, on_event=on_rej)
    rej = rej_state["approval"]
    if rej:
        reject_final = messages(cid_rej)
        audit = http("GET", "/api/audit?limit=20")
        rejected = [a for a in audit if a.get("tool") == "fs_write" and a.get("approval") == "rejected"]
        record("E7 拒绝审批 → rejected + 回答收尾", bool(rejected) and any(m["role"] == "assistant" for m in reject_final)
               and reject_events[-1]["event"] == "done",
               {"rejected": rejected[:1], "events": names(reject_events)[-4:]})
    else:
        record("E7 拒绝审批 → rejected + 回答收尾", False, {"events": names(reject_events)})

    # E8 空回复
    cid_empty = create_conv("empty")
    empty_events = sse_chat({"conversation_id": cid_empty, "text": "empty reply"})
    empty_msgs = messages(cid_empty)
    record("E8 空回复 → 0 delta / done / 无空助手消息",
           len(deltas(empty_events)) == 0 and empty_events[-1]["event"] == "done"
           and not [m for m in empty_msgs if m["role"] == "assistant"],
           {"events": names(empty_events), "messages": [(m["role"], len(m["content"])) for m in empty_msgs]})

    # E9 上游失败
    cid_err = create_conv("error")
    err_events = sse_chat({"conversation_id": cid_err, "text": "error500"})
    record("E9 上游失败 → error 无 done，可读", "error" in names(err_events) and "done" not in names(err_events),
           {"events": names(err_events), "error": first(err_events, "error")})
    ok_after = sse_chat({"conversation_id": cid_err, "text": "恢复请求 normal"})
    record("E9b 失败后服务仍可用", ok_after[-1]["event"] == "done", {"events": names(ok_after)[:4]})

    # E10 无 Key
    put_settings(api_key="")
    cid_nokey = create_conv("no-key")
    nokey = sse_chat({"conversation_id": cid_nokey, "text": "没有 Key 的请求"})
    record("E10 无 Key → error 可读", "error" in names(nokey) and bool(first(nokey, "error")),
           {"events": names(nokey), "error": first(nokey, "error")})
    put_settings(api_key="test-key")

    # E11 长回复
    put_settings(stream_output=True)
    cid_long = create_conv("long")
    long_events = sse_chat({"conversation_id": cid_long, "text": "long answer"})
    long_text = "".join(deltas(long_events))
    long_msgs = messages(cid_long)
    stored = [m for m in long_msgs if m["role"] == "assistant"]
    reloaded = stored[-1]["content"] if stored else ""
    record("E11 长回复（>8000 字，公式/代码块/表格）",
           len(long_text) > 8000 and "```dart" in long_text and "$r(A)$" in long_text and "|" in long_text
           and reloaded == long_text,
           {"len": len(long_text), "deltas": len(deltas(long_events)), "reload_equal": reloaded == long_text})

    # E12 计划
    cid_plan = create_conv("plan")
    plan_events = sse_chat({"conversation_id": cid_plan, "text": "plan a review"})
    plan_msgs = messages(cid_plan)
    stored_assistant = [m for m in plan_msgs if m["role"] == "assistant"]
    record("E12 计划/步骤实时 + 最终完成",
           bool(first(plan_events, "plan")) and bool(first(plan_events, "step"))
           and plan_events[-1]["event"] == "done"
           and bool(stored_assistant) and bool(stored_assistant[-1].get("plan")),
           {"events": names(plan_events), "plan": bool(stored_assistant and stored_assistant[-1].get("plan"))})

    # E14 保留会话供真实 UI 重载/同会话断言
    with open(os.path.join(EVID, "e2e-state.json"), "w", encoding="utf-8") as fh:
        json.dump({
            "screenshot_conversation": cid,
            "long_conversation": cid_long,
            "stream_on_conversation": cid_on,
            "stream_off_conversation": cid_off,
            "approval_conversation": cid_appr,
            "workspace": WORKSPACE,
        }, fh, ensure_ascii=False, indent=2)
    return conclude("full")


def setup_restart():
    health = http("GET", "/api/health")
    settings = get_settings()
    state_file = os.path.join(EVID, "e2e-state.json")
    state = {}
    if os.path.exists(state_file):
        with open(state_file, "r", encoding="utf-8") as fh:
            state = json.load(fh)
    record("R1 重启后健康", health.get("ok") is True, {"health": health})
    record("R2 重启后 stream_output 持久化", settings.get("stream_output") is True,
           {"stream_output": settings.get("stream_output")})
    record("R3 重启后 mock/Key 设置保留", settings.get("base_url") == MOCK and settings.get("has_key") is True,
           {"base_url": settings.get("base_url"), "has_key": settings.get("has_key")})
    cid = state.get("screenshot_conversation")
    if cid:
        msgs = messages(cid)
        record("R4 重启后会话历史仍在（截图问答）", len(msgs) >= 2 and any(m["role"] == "assistant" for m in msgs),
               {"messages": len(msgs), "roles": [m["role"] for m in msgs]})
    else:
        record("R4 重启后会话历史仍在（截图问答）", False, "no state file")
    return conclude("restart")


def conclude(mode):
    os.makedirs(EVID, exist_ok=True)
    path = os.path.join(EVID, f"e2e-floating-{mode}.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"mode": mode, "base": BASE, "pass": COUNTER["pass"], "fail": COUNTER["fail"],
                   "results": RESULTS, "at": time.strftime("%Y-%m-%dT%H:%M:%S")}, fh,
                  ensure_ascii=False, indent=2)
    print(f"RESULT pass={COUNTER['pass']} fail={COUNTER['fail']} -> {path}")
    return 0 if COUNTER["fail"] == 0 else 1


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "full"
    try:
        code = setup(mode)
    except Exception as exc:  # pragma: no cover
        record("EXCEPTION", False, repr(exc))
        code = conclude(mode + "-exception")
    sys.exit(code)
