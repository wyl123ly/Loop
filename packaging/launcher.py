"""Loop Windows 启动器：内嵌后端 + Edge 应用窗口。

打包命令（PyInstaller）见 packaging/build.ps1。
"""
from __future__ import annotations

import ctypes
import multiprocessing
import os
import socket
import subprocess
import sys
import threading
import time
import webbrowser
from pathlib import Path

APP_NAME = "Loop"
PORT = int(os.environ.get("LOOP_PORT", "8765") or 8765)
URL = f"http://127.0.0.1:{PORT}"


def base_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent.parent


def bundle_dir() -> Path:
    return Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))


def resolve_data_dir() -> Path:
    override = os.environ.get("LOOP_DATA_DIR")
    if override:
        return Path(override)
    candidates = [
        base_dir() / "data",
        base_dir().parent / "data",
        Path.cwd() / "data",
        Path(os.environ.get("LOCALAPPDATA") or Path.home()) / APP_NAME / "data",
    ]
    for candidate in candidates:
        if (candidate / "loop.db").exists():
            return candidate
    return candidates[-1]


def message_box(text: str, title: str = APP_NAME) -> None:
    try:
        ctypes.windll.user32.MessageBoxW(0, text, title, 0x10)
    except Exception:
        pass


def port_in_use(port: int) -> bool:
    sock = socket.socket()
    sock.settimeout(0.3)
    try:
        return sock.connect_ex(("127.0.0.1", port)) == 0
    finally:
        sock.close()


def wait_ready(port: int, timeout: float = 25.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        sock = socket.socket()
        sock.settimeout(0.3)
        try:
            if sock.connect_ex(("127.0.0.1", port)) == 0:
                return True
        finally:
            sock.close()
        time.sleep(0.15)
    return False


def find_edge() -> Path | None:
    roots = [
        Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")),
        Path(os.environ.get("ProgramFiles", r"C:\Program Files")),
        Path(os.environ.get("LOCALAPPDATA", "")),
    ]
    for root in roots:
        candidate = root / "Microsoft" / "Edge" / "Application" / "msedge.exe"
        if candidate.exists():
            return candidate
    return None


def _watch_parent() -> None:
    import ctypes

    parent = os.getppid()
    if parent <= 0:
        return
    synchronize = 0x00100000
    handle = ctypes.windll.kernel32.OpenProcess(synchronize, False, parent)
    if not handle:
        return
    ctypes.windll.kernel32.WaitForSingleObject(handle, 0xFFFFFFFF)
    os._exit(0)


def main() -> int:
    multiprocessing.freeze_support()

    data = resolve_data_dir()
    data.mkdir(parents=True, exist_ok=True)
    os.environ["LOOP_DATA_DIR"] = str(data)
    os.environ["LOOP_WEB_DIR"] = str(bundle_dir() / "web")

    log_path = data / "loop.log"
    log = open(log_path, "a", encoding="utf-8", buffering=1)
    sys.stdout = log
    sys.stderr = log

    log.write(f"\n=== Loop start {time.strftime('%Y-%m-%d %H:%M:%S')} ===\n")
    log.write(f"data={data}\nweb={os.environ['LOOP_WEB_DIR']}\nfrozen={getattr(sys, 'frozen', False)}\n")

    # onefile 模式下父进程是 bootloader：父进程被杀时让子进程一起退出，避免残留占用端口
    if getattr(sys, "frozen", False):
        threading.Thread(target=_watch_parent, name="parent-watch", daemon=True).start()

    if port_in_use(PORT):
        message_box(
            f"端口 {PORT} 已被占用。\n\n可能已经开着一个 Loop，或 start.bat 的服务。\n先关掉它再双击本程序。",
            "Loop 启动失败",
        )
        return 1

    try:
        import main as server_main  # noqa: PLC0415
        import uvicorn  # noqa: PLC0415

        config = uvicorn.Config(
            server_main.app,
            host="127.0.0.1",
            port=PORT,
            log_level="info",
            log_config=None,
            loop="asyncio",
            http="h11",
            ws="none",
            lifespan="on",
            access_log=False,
        )
        server = uvicorn.Server(config)
        thread = threading.Thread(target=server.run, name="loop-server", daemon=True)
        thread.start()
    except Exception as exc:  # 启动失败给用户一个明确提示
        log.write(f"server start failed: {exc!r}\n")
        message_box(f"后端启动失败：{exc}\n\n详情见 {log_path}", "Loop 启动失败")
        return 1

    if not wait_ready(PORT):
        message_box(f"后端启动超时。\n\n详情见 {log_path}", "Loop 启动失败")
        return 1

    log.write(f"ready at {URL}\n")

    if os.environ.get("LOOP_NO_BROWSER") == "1":
        while True:
            time.sleep(3600)

    edge = find_edge()
    if edge is None:
        webbrowser.open(URL)
        while True:
            time.sleep(3600)

    profile = Path(os.environ.get("LOCALAPPDATA") or str(data)) / APP_NAME / "edge-profile"
    profile.mkdir(parents=True, exist_ok=True)
    args = [
        str(edge),
        f"--app={URL}",
        f"--user-data-dir={profile}",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-features=Translate,msEdgeWelcome",
        "--window-size=1440,900",
    ]
    log.write("launch: " + " ".join(args) + "\n")
    try:
        proc = subprocess.Popen(args)
        proc.wait()
    except Exception as exc:
        log.write(f"edge launch failed: {exc!r}\n")
        webbrowser.open(URL)
        while True:
            time.sleep(3600)

    log.write("window closed, exiting\n")
    server.should_exit = True
    thread.join(timeout=5)
    return 0


if __name__ == "__main__":
    sys.exit(main())
