# -*- coding: utf-8 -*-
"""t4 流式输出开关 live E2E：真实 Backend（临时副本 8767）+ mock LLM(9999) + 隔离数据目录。

用法：
  python e2e.py full      # 全量断言（fresh DB，默认 stream_output=true）
  python e2e.py restart   # 重启后持久化/健康检查（同 LOOP_DATA_DIR）
结果写入同目录 evidence/e2e-<mode>.json，失败返回非 0。
"""
from __future__ import annotations

import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8767"
MOCK = "http://127.0.0.1:9999"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EVID = os.path.join(ROOT, "evidence")
WORKSPACE = os.path.join(ROOT, "workspace")
SHORT = "直接回答：这是一条普通问答，不调用工具。"
PLAN_TEXT = "计划已执行：已创建 2 个待办并回读确认。"
FILE_TEXT = "已写入并回读工作区文件 agent-mock.md。"
SLOW_TEXT = "慢速回答：第一段内容和第二段内容，用于验证运行中切换设置的请求级快照。"

RESULTS = []
COUNTER = {"pass": 0, "fail": 0}


def long_text() -> str:
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
    return "# 长回复渲染检查\n\n" + block * 18


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


def http(method, path, body=None, raw=None, content_type="application/json", headers=None):
    data = raw if raw is not None else (None if body is None else json.dumps(body).encode("utf-8"))
    hdrs = {"Content-Type": content_type}
    if headers:
        hdrs.update(headers)
    req = urllib.request.Request(BASE + path, data=data, method=method, headers=hdrs)
    with urllib.request.urlopen(req, timeout=60) as resp:
        payload = resp.read()
        return json.loads(payload) if payload else {}


def get_settings():
    return http("GET", "/api/settings")


def put_settings(**kw):
    out = http("PUT", "/api/settings", kw)
    return out, get_settings()


def create_conv(title="e2e"):
    return http("POST", "/api/conversations", {"title": title})


def list_messages(cid):
    return http("GET", f"/api/conversations/{cid}/messages")


def sse_chat(body, on_event=None, timeout=180):
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(BASE + "/api/chat", data=data, method="POST",
                                 headers={"Content-Type": "application/json"})
    events = []
    event, data_lines = None, []
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").rstrip("\n").rstrip("\r")
            if line == "":
                if event is not None or data_lines:
                    payload = json.loads("\n".join(data_lines)) if data_lines else {}
                    ev = (event or "message", payload, round(time.time() - t0, 3))
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
        ev = (event or "message", payload, round(time.time() - t0, 3))
        events.append(ev)
        if on_event:
            on_event(ev)
    return events


def names(events):
    return [e[0] for e in events]


def deltas(events):
    return [e[1].get("text", "") for e in events if e[0] == "delta"]


def one(events, name):
    found = [e for e in events if e[0] == name]
    return found[0] if found else None


def assistant_msgs(cid):
    return [m for m in list_messages(cid) if m.get("role") == "assistant"]


def wait_health(timeout=60):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            return http("GET", "/api/health")
        except Exception as exc:  # noqa: BLE001
            last = exc
            time.sleep(0.3)
    raise RuntimeError(f"health not ready: {last}")


def expect(name, cond, detail):
    return record(name, cond, detail)


def main_full():
    os.makedirs(EVID, exist_ok=True)
    os.makedirs(WORKSPACE, exist_ok=True)
    summary = {}

    health = wait_health()
    record("E0 启动健康", health.get("ok") is True and health.get("version") == "0.3.9",
           f"health={health}")

    s = get_settings()
    record("E1 新库默认 stream_output=true 且为布尔",
           s.get("stream_output") is True, f"stream_output={s.get('stream_output')!r}")

    out, s = put_settings(api_key="test-key", base_url=MOCK, stream_output=False,
                          auto_check_updates=False, sidebar_collapsed=False)
    record("E2 PUT 后 GET stream_output=false / base_url/mock/has_key",
           s.get("stream_output") is False and s.get("base_url") == MOCK and s.get("has_key") is True,
           f"settings={ {k: s.get(k) for k in ('stream_output','base_url','has_key')} }")
    agent_settings = http("PUT", "/api/agent/settings",
                          {"workspace_path": WORKSPACE, "shell": False, "browser": False, "mcp": False})
    gs = http("GET", "/api/agent/settings")
    record("E2b 工作区隔离", os.path.normcase(gs.get("workspace_path", "")) == os.path.normcase(WORKSPACE),
           f"workspace_path={gs.get('workspace_path')}")

    # E3 false 普通问答
    cid = create_conv("false-normal")["id"]
    ev = sse_chat({"conversation_id": cid, "text": "直接回答"})
    ds = deltas(ev)
    done = one(ev, "done")
    saved = assistant_msgs(cid)
    record("E3 false 普通问答：仅 1 条 delta 且内容完整、落库一致、token 正确",
           len(ds) == 1 and ds[0] == SHORT and len(saved) == 1 and saved[0]["content"] == SHORT
           and done is not None and done[1].get("tokens_in") == 260 and done[1].get("tokens_out") == 90
           and names(ev)[-1] == "done" and done[1].get("cost", 0) > 0,
           f"events={names(ev)} deltas={len(ds)} tokens={done[1].get('tokens_in')}/{done[1].get('tokens_out')} cost={done[1].get('cost')}")
    summary["false_normal"] = {"events": names(ev), "delta_count": len(ds), "t0": ev[0][2],
                               "delta_t": [e[2] for e in ev if e[0] == "delta"], "done_t": done[2]}
    false_short_text = ds[0] if ds else None

    # E4 true 普通问答
    put_settings(stream_output=True)
    cid2 = create_conv("true-normal")["id"]
    ev2 = sse_chat({"conversation_id": cid2, "text": "直接回答"})
    ds2 = deltas(ev2)
    saved2 = assistant_msgs(cid2)
    record("E4 true 普通问答：多个 delta 逐段，拼接与 false 单条一致",
           len(ds2) > 1 and "".join(ds2) == false_short_text and saved2[0]["content"] == false_short_text
           and names(ev2)[-1] == "done",
           f"delta_count={len(ds2)} first_deltas={ds2[:3]}")
    summary["true_normal"] = {"events": names(ev2), "delta_count": len(ds2),
                              "first_delta_t": next((e[2] for e in ev2 if e[0] == "delta"), None),
                              "done_t": one(ev2, "done")[2]}

    # E5 false 计划：plan/step 实时、最终单 delta
    put_settings(stream_output=False)
    cid3 = create_conv("false-plan")["id"]
    ev3 = sse_chat({"conversation_id": cid3, "text": "帮我做个计划"})
    ds3 = deltas(ev3)
    done3 = one(ev3, "done")
    steps3 = done3[1].get("steps") if done3 else []
    plan_events = [e for e in ev3 if e[0] == "plan"]
    step_events = [e for e in ev3 if e[0] == "step"]
    delta3 = next((e for e in ev3 if e[0] == "delta"), None)
    saved3 = assistant_msgs(cid3)
    plan_raw = saved3[0].get("plan") if saved3 else None
    plan_saved = plan_raw if isinstance(plan_raw, list) else json.loads(plan_raw or "[]")
    record("E5 false 计划：plan/step 先于 delta，delta 恰好 1 条且含完成文本，plan/steps 落库",
           len(ds3) == 1 and "计划已执行" in ds3[0] and bool(plan_events) and len(step_events) >= 3
           and delta3 is not None and plan_events[0][2] < delta3[2] and step_events[0][2] < delta3[2]
           and saved3 and saved3[0]["content"] == ds3[0] and len(plan_saved) >= 3
           and {s.get("name") for s in steps3} >= {"update_plan", "create_tasks", "list_tasks"},
           f"events={names(ev3)} plan_t={[e[2] for e in plan_events]} step_t={[e[2] for e in step_events]} delta_t={delta3[2] if delta3 else None}")
    summary["false_plan"] = {"events": names(ev3), "delta_count": len(ds3),
                             "plan_t": [e[2] for e in plan_events],
                             "step_t": [e[2] for e in step_events],
                             "delta_t": delta3[2] if delta3 else None}
    false_plan_text = ds3[0] if ds3 else None

    # E5b true 计划：多 delta，拼接一致，plan/step 仍实时
    put_settings(stream_output=True)
    cid3b = create_conv("true-plan")["id"]
    ev3b = sse_chat({"conversation_id": cid3b, "text": "帮我做个计划"})
    ds3b = deltas(ev3b)
    record("E5b true 计划：多 delta 拼接 == false 单条；plan/step 仍出现",
           len(ds3b) > 1 and "".join(ds3b) == false_plan_text
           and bool([e for e in ev3b if e[0] == "plan"]) and bool([e for e in ev3b if e[0] == "step"]),
           f"delta_count={len(ds3b)} events={names(ev3b)}")

    # E7 false 审批：approval 实时、allow 后工具执行、单 delta
    put_settings(stream_output=False)
    cid4 = create_conv("false-approval")["id"]
    approvals = []

    def on_approval(ev):
        if ev[0] == "approval":
            approvals.append(ev[1])
            http("POST", "/api/agent/approve", {"run_id": ev[1].get("run_id"), "allow": True})

    ev4 = sse_chat({"conversation_id": cid4, "text": "写个文件"}, on_event=on_approval)
    ds4 = deltas(ev4)
    done4 = one(ev4, "done")
    target = os.path.join(WORKSPACE, "agent-mock.md")
    audit = http("GET", "/api/audit?limit=50")
    record("E7 false 审批：approval 实时、allow 后工具执行、文件生成、audit 记录、单 delta",
           len(approvals) == 1 and approvals[0].get("tool") == "fs_write"
           and os.path.exists(target) and len(ds4) == 1 and ds4[0] == FILE_TEXT
           and any(a.get("tool") == "fs_write" for a in audit)
           and done4 is not None and names(ev4)[-1] == "done",
           f"approvals={approvals} file={os.path.exists(target)} deltas={len(ds4)} audit_tools={[a.get('tool') for a in audit][:5]}")
    summary["false_approval"] = {"events": names(ev4), "delta_count": len(ds4),
                                 "approval_t": [e[2] for e in ev4 if e[0] == "approval"],
                                 "delta_t": next((e[2] for e in ev4 if e[0] == "delta"), None)}

    # E8 审批等待时取消
    cid5 = create_conv("cancel-approval")["id"]

    def on_approval_cancel(ev):
        if ev[0] == "approval":
            http("POST", "/api/agent/cancel", {"run_id": ev[1].get("run_id")})

    ev5 = sse_chat({"conversation_id": cid5, "text": "写个文件"}, on_event=on_approval_cancel)
    record("E8 false 审批等待中取消：cancelled 一次、无 delta、无 done",
           names(ev5).count("cancelled") == 1 and not deltas(ev5) and one(ev5, "done") is None,
           f"events={names(ev5)}")

    # E8b 流式过程中取消：已生成部分只补发一次
    cid6 = create_conv("cancel-stream")["id"]

    def cancel_later(run_id):
        time.sleep(0.45)
        try:
            http("POST", "/api/agent/cancel", {"run_id": run_id})
        except Exception:  # noqa: BLE001
            pass

    def on_run(ev):
        if ev[0] == "run" and ev[1].get("run_id"):
            threading.Thread(target=cancel_later, args=(ev[1]["run_id"],), daemon=True).start()

    ev6 = sse_chat({"conversation_id": cid6, "text": "慢速"}, on_event=on_run)
    ds6 = deltas(ev6)
    record("E8b false 流式过程中取消：delta<=1 且为已生成前缀、cancelled 一次、无 done",
           len(ds6) <= 1 and (not ds6 or SLOW_TEXT.startswith(ds6[0])) and names(ev6).count("cancelled") == 1
           and one(ev6, "done") is None,
           f"events={names(ev6)} delta={ds6}")

    # 取消后服务仍可用
    cid6b = create_conv("after-cancel")["id"]
    ev6b = sse_chat({"conversation_id": cid6b, "text": "直接回答"})
    record("E8c 取消后下一条消息正常", deltas(ev6b) == [SHORT] and names(ev6b)[-1] == "done",
           f"events={names(ev6b)}")

    # E9 空回复
    cid7 = create_conv("empty")["id"]
    ev7 = sse_chat({"conversation_id": cid7, "text": "空回复"})
    done7 = one(ev7, "done")
    record("E9 false 空回复：0 delta、done 一次、token 正常、无空助手消息",
           not deltas(ev7) and done7 is not None and len([e for e in ev7 if e[0] == "done"]) == 1
           and done7[1].get("tokens_in") == 17 and done7[1].get("tokens_out") == 0
           and done7[1].get("message_id") is None and not assistant_msgs(cid7),
           f"events={names(ev7)} done={done7[1] if done7 else None}")

    # E10 长回复 Markdown/公式/代码块
    expected_long = long_text()
    cid8 = create_conv("long-false")["id"]
    ev8 = sse_chat({"conversation_id": cid8, "text": "长回复"})
    ds8 = deltas(ev8)
    saved8 = assistant_msgs(cid8)
    record("E10 false 长回复：单条 delta >5000 字且与 Markdown/公式/代码块原文一致、落库一致",
           len(ds8) == 1 and ds8[0] == expected_long and len(ds8[0]) > 5000
           and "```dart" in ds8[0] and "$r(A)$" in ds8[0] and "## 矩阵的秩" in ds8[0]
           and saved8 and saved8[0]["content"] == expected_long,
           f"chars={len(ds8[0]) if ds8 else 0} deltas={len(ds8)}")

    put_settings(stream_output=True)
    cid8b = create_conv("long-true")["id"]
    ev8b = sse_chat({"conversation_id": cid8b, "text": "长回复"})
    ds8b = deltas(ev8b)
    record("E10b true 长回复：多个 delta 拼接与 false 单条一致",
           len(ds8b) > 1 and "".join(ds8b) == expected_long,
           f"delta_count={len(ds8b)} chars={len(''.join(ds8b))}")

    # E11 运行中切换：请求级快照
    put_settings(stream_output=False)
    cid9 = create_conv("snapshot")["id"]
    box = {}

    def run_slow():
        try:
            box["events"] = sse_chat({"conversation_id": cid9, "text": "慢速"})
        except Exception as exc:  # noqa: BLE001
            box["error"] = repr(exc)

    th = threading.Thread(target=run_slow, daemon=True)
    th.start()
    time.sleep(0.5)
    put_settings(stream_output=True)  # 运行中切到 true，不应影响本次
    th.join(timeout=60)
    ev9 = box.get("events", [])
    ds9 = deltas(ev9)
    record("E11 运行中切换：本次仍单 delta，下一次多 delta（请求级快照）",
           len(ds9) == 1 and ds9[0] == SLOW_TEXT,
           f"delta_count={len(ds9)} events={names(ev9)}")
    cid9b = create_conv("snapshot-next")["id"]
    ev9b = sse_chat({"conversation_id": cid9b, "text": "慢速"})
    ds9b = deltas(ev9b)
    record("E11b 切换后的下一条：按新值 true 逐段", len(ds9b) > 1 and "".join(ds9b) == SLOW_TEXT,
           f"delta_count={len(ds9b)}")

    # E12 错误：模型不可达（false 模式，正文为空 → error 事件）
    put_settings(stream_output=False)
    put_settings(base_url="http://127.0.0.1:9998")
    cid10 = create_conv("error")["id"]
    ev10 = sse_chat({"conversation_id": cid10, "text": "直接回答"})
    err = one(ev10, "error")
    record("E12 模型不可达：error 事件可读、无 done、服务不崩",
           err is not None and bool(err[1].get("message")) and one(ev10, "done") is None,
           f"events={names(ev10)} error={err[1] if err else None}")
    put_settings(base_url=MOCK)
    cid10b = create_conv("after-error")["id"]
    ev10b = sse_chat({"conversation_id": cid10b, "text": "直接回答"})
    record("E12b 恢复 base_url 后正常", deltas(ev10b) == [SHORT], f"events={names(ev10b)}")

    # E13 设置校验/字段不互相重置
    put_settings(stream_output=True, sidebar_collapsed=False)
    http("PUT", "/api/settings", {"stream_output": "false"})  # 字符串应被忽略
    s13a = get_settings()
    http("PUT", "/api/settings", {"sidebar_collapsed": True})
    s13b = get_settings()
    record("E13 布尔校验 + 侧栏开关不重置 stream_output",
           s13a.get("stream_output") is True and s13b.get("stream_output") is True
           and s13b.get("sidebar_collapsed") is True,
           f"after_string={s13a.get('stream_output')} after_sidebar={s13b.get('stream_output')}/{s13b.get('sidebar_collapsed')}")
    http("PUT", "/api/settings", {"sidebar_collapsed": False})

    # E14 自定义模式 + 思考强度
    put_settings(stream_output=False)
    cid11 = create_conv("custom-mode")["id"]
    ev11 = sse_chat({"conversation_id": cid11, "text": "直接回答", "mode": "custom-t4",
                     "mode_prompt": "你是 t4 验证助手。", "thinking": "high"})
    ds11 = deltas(ev11)
    record("E14 自定义模式 + thinking=high：false 仍单 delta 完整",
           len(ds11) == 1 and ds11[0] == SHORT, f"events={names(ev11)}")

    # E15 图片附件 / 截图附件（同一上传通道）
    img_path = os.path.join("D:\\DSH_Workspace\\Prog2_app\\.tools", "native-window.png")
    uploads = []
    for name in ("t4-image.png", "截图-t4.png"):
        with open(img_path, "rb") as fh:
            data = fh.read()
        up = http("POST", "/api/upload", raw=data, content_type="image/png",
                  headers={"X-Filename": urllib.request.quote(name)})
        uploads.append(up)
    cid12 = create_conv("image")["id"]
    ev12 = sse_chat({"conversation_id": cid12, "text": "看图", "attachments": [u["id"] for u in uploads]})
    ds12 = deltas(ev12)
    msgs12 = list_messages(cid12)
    user12 = [m for m in msgs12 if m.get("role") == "user"]
    atts_raw = user12[0].get("attachments") if user12 else None
    atts = atts_raw if isinstance(atts_raw, list) else json.loads(atts_raw or "[]")
    record("E15 图片/截图附件：上传、false 单 delta、附件落库",
           all(u.get("kind") == "image" for u in uploads) and len(ds12) == 1
           and len(atts) == 2 and all(a.get("is_image") for a in atts),
           f"uploads={uploads} deltas={len(ds12)} attachments={atts}")

    # E16 历史重载一致性（false/true 同问题）
    m_false = list_messages(cid)
    m_true = list_messages(cid2)
    a_false = [m for m in m_false if m.get("role") == "assistant"][0]
    a_true = [m for m in m_true if m.get("role") == "assistant"][0]
    record("E16 历史重载：false/true 正文、token 一致",
           a_false["content"] == a_true["content"]
           and a_false["tokens_in"] == a_true["tokens_in"] == 260
           and a_false["tokens_out"] == a_true["tokens_out"] == 90,
           f"false={a_false['content']!r} tokens={a_false['tokens_in']}/{a_false['tokens_out']}")

    # 收尾：保持 false，供重启持久化验证
    put_settings(stream_output=False)
    final = get_settings()
    record("E17 收尾设置为 false（供重启验证）", final.get("stream_output") is False,
           f"stream_output={final.get('stream_output')}")

    evidence = {"mode": "full", "base": BASE, "pass": COUNTER["pass"], "fail": COUNTER["fail"],
                "results": RESULTS, "summary": summary}
    os.makedirs(EVID, exist_ok=True)
    with open(os.path.join(EVID, "e2e-full.json"), "w", encoding="utf-8") as fh:
        json.dump(evidence, fh, ensure_ascii=False, indent=2)
    print(f"\nE2E full: {COUNTER['pass']} passed, {COUNTER['fail']} failed")
    return 0 if COUNTER["fail"] == 0 else 1


def main_restart():
    os.makedirs(EVID, exist_ok=True)
    health = wait_health()
    s = get_settings()
    ok = (s.get("stream_output") is False and health.get("ok") is True
          and health.get("version") == "0.3.9")
    record("R1 重启后 stream_output=false 仍持久化、后端健康", ok,
           f"stream_output={s.get('stream_output')!r} health={health}")
    # 其他设置也不丢
    ok2 = s.get("base_url") == MOCK and s.get("has_key") is True and s.get("auto_check_updates") is False
    record("R2 重启后 base_url/api_key/auto_check_updates 保持", ok2,
           f"base_url={s.get('base_url')} has_key={s.get('has_key')} auto_check_updates={s.get('auto_check_updates')}")
    evidence = {"mode": "restart", "pass": COUNTER["pass"], "fail": COUNTER["fail"],
                "results": RESULTS}
    with open(os.path.join(EVID, "e2e-restart.json"), "w", encoding="utf-8") as fh:
        json.dump(evidence, fh, ensure_ascii=False, indent=2)
    print(f"\nE2E restart: {COUNTER['pass']} passed, {COUNTER['fail']} failed")
    return 0 if COUNTER["fail"] == 0 else 1


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "full"
    if mode == "full":
        sys.exit(main_full())
    elif mode == "restart":
        sys.exit(main_restart())
    else:
        print("unknown mode", mode)
        sys.exit(2)
