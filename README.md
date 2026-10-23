# Remote Codex Switch

Windows 可视化应用：选择服务器、自动检测本机代理端口，按需开启 VS Code 左侧的远程 Codex 面板。

**[下载 Windows 预览版 v0.3.0](https://github.com/galaaaaaa/remote-codex-switch/releases/tag/v0.3.0)** · [查看源码](src/RemoteCodexApp.cs)

![应用界面，使用示例服务器和目录](docs/app-preview.png)

## 开始使用

1. 从 Releases 下载 `RemoteCodex.exe`，双击打开。免安装，不需要管理员权限。
2. 打开本机代理软件，使用无需认证的 HTTP / Mixed 代理端口。
3. 在下拉框选择 `.ssh/config` 里的服务器别名；也可以手动填写别名。远程项目目录可以留空。
4. 保持“开启时自动检测端口”勾选，点击“开启远程 Codex”。也可以先点“自动检测”查看结果。
5. 在打开的 VS Code 专用窗口中使用 Codex。用完点“关闭连接”，或关闭该专用 VS Code 窗口。退出本应用也会停止它建立的隧道。

**从 v0.2.0 升级：** 先关闭旧应用及其专用 VS Code 窗口，再运行新版本并重新开启。v0.2.0 只设置 VS Code 的 `http.proxy`，在远端扩展进程中可能不生效；新版本使用会话专用的 Codex 启动器直接传入代理，并在打开编辑器之前检查 OpenAI 登录服务。

使用密钥免密登录时，连接在后台完成。需要 SSH 密码、密钥口令或首次主机确认时，会弹出 SSH 登录窗口，请在该窗口完成登录。应用不保存 SSH 密码。

### 使用前需要

- Windows 10 / 11，.NET Framework 4.8，系统自带 Windows PowerShell 和 OpenSSH 客户端。
- 已安装正式版 VS Code、Remote - SSH，对应服务器可以通过 SSH 正常连接。
- 远端已安装 Codex 扩展。远端需要已有登录，或通过下面的可选操作同步本机登录。
- Linux x86_64 / aarch64 服务器，标准 `~/.vscode-server/extensions` 扩展目录；支持 SSH 远程端口转发，具备 `sh`、`base64`、`tr`、`grep`、`sleep`、`sort -V`、`tail`、`uname`、`chmod` 等常见命令。建议安装 `curl` 用于代理检查。
- 服务器上的同号代理转发端口空闲。端口占用时，先关闭重复隧道。

首次使用独立的 VS Code 配置窗口，可能需要完成工作区信任、SSH 登录、远端扩展安装和 Codex 登录。

### 远端提示登录、本机浏览器报 IP 问题

浏览器登录和远端 Codex 请求是两段连接。本应用不会修改本机浏览器代理。浏览器里的错误需要结合完整报错判断；不能仅凭“IP 问题”认定服务器隧道失败。

如果本机 Codex 已登录，可以使用 **同步本机登录**：

1. 选择你信任的服务器，点击“同步本机登录”，确认目标服务器和用户。
2. 应用仅在这次操作中读取本机 `CODEX_HOME/auth.json`（默认 `~/.codex/auth.json`），通过 SSH 标准输入传给远端；不会把凭据写入命令参数、运行记录或 GitHub。
3. 远端已有 `auth.json` 时，先备份为同目录的 `auth.json.remote-codex-switch-backup-*`，再原子替换，文件权限设为 600。
4. 开启远程连接，或重新加载已有远端 Codex 面板。

同步目前支持文件方式保存的登录；不会从操作系统凭据库提取登录。远端显式配置 `keyring`、`auto` 或 `ephemeral` 存储时会拒绝文件同步。SSH 需要密码时会弹出登录窗口。

**同一服务器用户下的 Codex 窗口共享登录文件。** 同步会更换该用户的 Codex 登录；不会给其他窗口自动开启代理，也不会每次启动都覆盖登录。登录文件和备份都应像密码一样保管。

同步登录不能修复网络。令牌刷新和正常使用仍需远端能访问服务；`unsupported_country_region_territory` 表示服务返回了地区限制。代理检查失败会阻止启动，避免把 SSH 成功误报为 Codex 可用。登录服务检查成功也不保证账号、地区、模型请求和浏览器授权都成功。

## 服务器和端口怎么选

### 可以选择哪台服务器？

应用读取本机 `~/.ssh/config` 主文件中的具体 `Host` 别名，在下拉框列出；支持刷新列表。通配符和注释不作为服务器显示。通过 `Include` 配置的别名可以直接手动填写，SSH 连接本身仍按原配置解析。

“SSH 配置”按钮可以打开原配置文件供你编辑。切换服务器时，应用会清空旧服务器的项目目录，避免误用。保存设置后记住当前服务器和目录。

### 自动检测代理端口

每次开启时按以下优先级查找，遇到一组可用结果即停止：

1. 当前启用的 Windows 系统 HTTP / HTTPS 代理地址。
2. 本机 HTTP / HTTPS 代理环境变量。
3. 上次保存的端口。
4. 常见代理程序的本机 TCP 监听端口，如 Mihomo、Clash、v2ray、xray、sing-box 等。
5. 少量常见端口：7890、7897、10809、10808、1080、1087、2080。

自动检测只接受本机 IPv4 回环地址上的 HTTP / Mixed 代理，会发送到 `example.com:443` 的 HTTP CONNECT 握手进行检查，不发送账号数据和应用内容。不会扫描远程服务器端口。

发现多个候选时，需要在端口下拉框中选择。识别不到时，可取消自动检测，手动填写 HTTP / Mixed 端口。手动模式只检查 TCP 连接，不保证端口协议和节点可达性。纯 SOCKS 端口、需要认证的代理、仅 IPv6 监听的端口不在自动支持范围内。

### 梯子端口改了怎么办？

先关闭当前连接，再重新开启。自动模式会重新检测，并同时更新 SSH 隧道和专用 VS Code 的代理设置。例如从 7890 改成 7897，不必手动修改多份配置。

连接过程中不自动切换端口。如果选择手动模式，直接在界面修改端口即可。

这里的端口是**本机梯子的代理端口**。服务器的 SSH 登录端口仍由 `.ssh/config` 的 `Port` 决定；服务器登录端口变化时，应先更新 SSH 配置。

## 本机设置和影响范围

可视化应用的设置和临时文件保存在 `%LOCALAPPDATA%\RemoteCodexSwitch\`：

- `config.json`：服务器别名、上次端口、自动检测开关和项目目录。
- `runtime/`：本应用的 SSH 配置副本、独立 VS Code 数据、连接状态和日志。
- 内置连接脚本会在本应用目录中更新；应用不修改原来的 SSH 配置和日常 VS Code 设置。

个人设置只保存在本机，不上传到 GitHub。运行日志可能包含你的服务器信息，应像原 SSH 配置一样保管。

代理作用于本应用打开的独立 VS Code 配置窗口，读取其代理设置的其他扩展也可能使用它。应用在远端 `~/.cache/remote-codex-switch/<会话>/codex` 写入临时启动器，通过专用窗口的 `chatgpt.cliExecutable` 启动原扩展内的 Codex 二进制，直接设置大小写代理变量。不会修改扩展二进制、远端共享 VS Code 设置或终端启动文件。SSH 会话正常结束时删除该会话启动器。

Codex 启动的子命令可能继承代理环境，大文件下载仍可能消耗节点流量。它不是严格的“仅 Codex 进程”隔离。本机的其他 VS Code 窗口可以照常使用；已打开的普通远程窗口不会自动获得本应用的代理，应使用应用打开的专用窗口。

普通终端不会被本应用主动注入代理；但原来的终端启动文件如果已设置代理，仍可能生效。关闭隧道后，服务器计算任务继续运行，依赖此隧道的联网操作会失败。电脑休眠、梯子退出或 SSH 断开后，需要重新开启。

## 如果以前设置过常驻代理

本应用只读检测并提醒，不会自动移除旧配置。要让普通终端恢复直连，需要先备份并移除先前设置的：

- 远端当前用户 `~/.bashrc` 等启动文件中的代理导出行。
- VS Code 远程设置中的常驻 `http.proxy` 和终端代理环境变量。
- 本机 `.ssh/config` 中先前添加的常驻 `RemoteForward`。

应用会在临时副本中跳过直接写在主 SSH 配置里的端口转发；如果 Include 文件中仍有转发，会提示处理。原配置不会被自动修改。

移除旧配置后，重新连接并新开终端。已启动进程继承的代理变量不会随配置文件编辑自动消失。若远程设置显式使用了 `http.useLocalProxyConfiguration: false`，需要先撤销该设置或改为 true，才能采用独立窗口的代理设置。

## 脚本版本仍可使用

下载完整源码后，可使用 `开启远程Codex.cmd`、`关闭远程Codex.cmd`、`选择服务器.cmd`、`检测代理端口.cmd` 和 `修改设置.cmd`。脚本版把设置保存在源码目录，和可视化应用的设置分开。

`config.example.json` 示例：

```json
{
  "SshHost": "my-server",
  "ProxyPort": 7890,
  "AutoDetectProxyPort": true,
  "RemoteFolder": "/home/user/project"
}
```

老版本配置没有 `AutoDetectProxyPort` 时，脚本自动启用端口检测。

## 开发和验证

从仓库目录使用 Windows PowerShell 5.1：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-App.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-RemoteCodex.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ProxyDetection.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-LoginSync.ps1
.\dist\RemoteCodex.exe --self-test .\.test-artifacts\gui
```

构建使用 Windows .NET Framework 自带编译器，不下载第三方依赖。可执行文件内置连接脚本，分发时只需 `RemoteCodex.exe`。

在 Linux 上可另运行 `python3 tests/test_login_sync_remote.py`，用临时目录和虚构凭据验证远端备份、权限、原子替换及拒绝符号链接等行为。

测试覆盖连接正常关闭、GUI 后台模式、关闭请求、SSH 断开、VS Code 启动失败、代理检查失败、无关进程保护、旧配置迁移、端口变化、HTTP 与 SOCKS 区分、多个候选选择，以及使用虚构凭据的 SSH 标准输入同步。仓库测试使用本机模拟服务，不连接真实服务器或读取真实登录凭据。界面预览使用示例服务器名称。

真实服务器、代理节点和远端 Codex 版本的兼容性仍需实际使用时验证。界面的“SSH 已连接”仅表示 SSH 就绪；运行记录会单独报告登录服务检查，账号状态应在 Codex 面板确认。

## 参考

- [VS Code 命令行与独立配置目录](https://code.visualstudio.com/docs/configure/command-line)
- [VS Code 代理设置](https://code.visualstudio.com/docs/setup/network)
- [SSH RemoteForward](https://man.openbsd.org/ssh_config#RemoteForward)
- [OpenAI：远程设备登录和复制登录缓存](https://learn.chatgpt.com/docs/auth#fallback-authenticate-locally-and-copy-your-auth-cache)

开发时检查的 Codex 扩展版本为 26.1007.21434。它会读取扩展宿主可见的 `http.proxy`，但远端宿主可能读不到本机该设置。新版本使用其应用级 `chatgpt.cliExecutable` 设置指定临时启动器，仍执行原扩展内的二进制。该设置由扩展标为开发用途，其他版本和自定义服务器安装目录需实际验证。
