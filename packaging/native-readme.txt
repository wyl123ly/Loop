回路 Loop v0.3 · Windows 原生版（纯 Flutter）
============================================

怎么用
------
1. 双击 Loop.exe（整个文件夹一起保留，别只拷 exe）
2. 原生 Flutter 窗口直接打开，没有浏览器、没有 Python、没有后台子进程
3. 关闭窗口 = 退出

第一次在「设置」里填 DeepSeek API Key。

文件夹里都是什么
----------------
Loop.exe                       原生 Flutter 界面
flutter_windows.dll            Flutter 运行时
sqlite3.dll / pdfium.dll       本地数据库与 PDF 解析（进程内加载）
pdfrx_pdfium_gate.dll          PDF 访问保护
data\                          界面资源（字体、app.so 等）
使用说明.txt

数据在哪
--------
按顺序找第一个存在的 data 文件夹：
1. 环境变量 LOOP_DATA_DIR
2. Loop.exe 同级 data\loop.db
3. 上一级 data\
4. 上两级 data\        ← 现在放在 release\Loop-Desktop\ 里，用的是项目根目录的 data\
5. %LOCALAPPDATA%\Loop\data

日志：<数据目录>\loop.log（只有异常时才写）

后端在哪
--------
后端已经用 Dart 重写，跑在同一个进程里（HTTP 127.0.0.1:8765），
SQLite 数据库、全文检索、PDF/DOCX/PPTX 解析、DeepSeek 调用都在进程内完成。
启动不需要拉起 Python 或任何子进程，所以是秒开。

出问题
------
- 提示端口 8765 被占用：关掉另一个 Loop 实例（或旧的 start.bat 服务）
- 首次运行可能被 SmartScreen 拦截：更多信息 → 仍要运行（未签名）
- 上传 PDF 解析失败：扫描件没有文字层，请改用截图提问
