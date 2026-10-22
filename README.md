# Remote Codex Switch

Windows 上按需开启的 VS Code 远程 Codex 代理开关。

平时照常连接、使用服务器。需要 VS Code 左侧的远程 Codex 面板时，再启动这个工具。

## 怎么用

1. 点击仓库页面的 **Code → Download ZIP**，下载后完整解压；也可以克隆此仓库。
2. 打开本机梯子，确认提供的是 HTTP / Mixed 代理端口。
3. 双击“开启远程Codex.cmd”。首次选择 `.ssh/config` 中的服务器名称、代理端口和远程项目目录，后续自动记住。
4. 工具会建立 SSH 隧道，打开独立配置的 VS Code 窗口。在该窗口左侧使用 Codex。
5. 用完关闭这个专用 VS Code 窗口，启动器会停止隧道；也可双击“关闭远程Codex.cmd”立即停止。

启动器的黑色窗口请保持打开。密码登录仍需在窗口中输入 SSH 密码；免密登录后才能做到全程无需输入。工具不会保存密码。

“修改设置.cmd”可更换服务器、项目目录和端口。一个文件夹同时只运行一个会话；如有多套固定服务器配置，可复制整套工具到另一文件夹，使用不同的远程端口以免冲突。

## 首次需要的准备

- 已安装正式版 VS Code 和 Remote - SSH；对应 Host 可以正常连接 Linux 服务器。
- 本机 HTTP / Mixed 代理正在运行。默认示例端口是 7890，以软件实际设置为准，纯 SOCKS 端口不适用于此版本。
- 服务器的同号端口空闲，SSH 服务允许远程端口转发；如果出现端口占用，先关闭重复的隧道。
- Codex 扩展需要安装在远端并完成登录。已有的远端登录会继续使用；本工具不会复制、读取或上传本机的登录文件。
- 服务器具有常见 Linux 命令 `sh`、`base64`、`tr`、`grep`、`sleep`。

首次打开独立 VS Code 窗口可能需要完成工作区信任、SSH 登录、远端 Codex 安装/登录等正常初始化步骤。

## 影响范围

- 不改你原有的 SSH 配置，不改原有 VS Code 用户设置，不往服务器 `.bashrc` 写入代理。
- 代理设置保存在工具的 `runtime/vscode-data` 中；只有通过该独立配置窗口打开的相关扩展会使用它。它并非严格的“仅 Codex 进程”隔离，其他读取该窗口代理设置的扩展也可能使用代理。
- 为兼容 VS Code 本地与远端代理设置，服务器转发端口与本机 HTTP / Mixed 端口使用相同数字。
- 专用窗口的普通终端不主动注入代理变量；但终端启动文件原本存在的代理设置仍可能再次生效。
- Codex 启动的子命令可能继承其代理环境，所以让 Codex 下载大型模型、数据集或依赖仍可能消耗节点流量。
- 关闭隧道后，服务器计算任务继续运行；仍依赖该隧道的联网操作会失败。关闭代理不等于终止服务器程序。
- 电脑休眠、梯子退出、SSH 断开会使隧道失效。恢复后重新双击开启。
- “关闭远程Codex.cmd”只停止本工具记录并核验过的 SSH 进程，不关闭其他 SSH 连接或 VS Code 窗口。

## 如果已经照 PDF 设置过常驻代理

本工具会做只读检测并显示提醒，不会擅自清理旧配置。**仅使用本开关，不会撤销之前已经写入的常驻代理。** 若要保证普通终端恢复直连，需要先备份并移除教程中以下配置：

1. 远端当前用户的 `~/.bashrc` 中，教程添加的 `HTTP_PROXY`、`HTTPS_PROXY` 及小写形式等代理导出行，以及对应的 `NO_PROXY` / `no_proxy` 行。教程的 `/root/.bashrc` 只适用于 root 账号。
2. VS Code 的远程设置中，教程添加的 `http.proxy` 以及 `terminal.integrated.env.linux` 内的代理变量。保留这些对象中与你其他用途有关的设置。
3. 本机 `.ssh/config` 中，教程添加的常驻 `RemoteForward` 行。工具会在临时副本中跳过直接写在主配置里的转发，但不会修改原文件。如果 Include 文件里还有转发，工具会提示先处理。

移除后，关闭原来的远程终端并重新连接/加载 VS Code。已启动进程继承的代理变量不会因为编辑配置文件自动消失；新开终端后再检查。

若远程设置显式设置了 `http.useLocalProxyConfiguration: false`，请先撤销该旧设置或改为 true，否则远端可能不会采用这个独立窗口的代理设置。

## 文件和排错

- `config.json`：首次设置后产生，保存服务器别名、端口、目录，不保存密码。
- `runtime/`（已被 `.gitignore` 排除）：临时 SSH 配置副本、独立 VS Code 设置、连接状态和日志。SSH 副本可能包含原 SSH 配置中的连接信息，请像原配置一样保管。
- `runtime/connection.log`：只保存隧道状态和检测标记；SSH 报错直接显示在启动器窗口。
- 没反应：确认先完整解压，且系统没有阻止本地脚本。启动脚本只为此次进程指定执行策略，不修改系统执行策略。
- 隧道成功但 Codex 不联网：先确认远端扩展已安装、登录有效，并检查代理节点是否可以访问 OpenAI。端口检测成功只表示端口可连接，不保证节点或账号可用。
- 不要在日常窗口手动打开 `runtime/Remote-Codex.code-workspace`，请使用开启脚本，否则不会自动启动隧道，也不会加载独立配置。

本工具已在本机进行离线检查和模拟连接生命周期验证；真实服务器连接、节点可达性、远端扩展兼容性需首次运行时验证。

## 依据

- [VS Code 命令行和独立用户数据目录](https://code.visualstudio.com/docs/configure/command-line)
- [VS Code 网络代理设置](https://code.visualstudio.com/docs/setup/network)
- [SSH RemoteForward](https://man.openbsd.org/ssh_config#RemoteForward)

开发时检查的 Codex 扩展版本为 26.1007.21434：它会把 VS Code 的 `http.proxy` 传给启动的 Codex 进程。其他版本需要以实际行为为准。


## 配置示例

首次运行会交互生成 `config.json`。也可以复制 `config.example.json` 为 `config.json` 后修改：

```json
{
  "SshHost": "my-server",
  "ProxyPort": 7890,
  "RemoteFolder": "/home/user/project"
}
```

`SshHost` 是本机 SSH 配置里的别名；项目目录留空时打开远程主目录。示例中的服务器和目录均需替换为自己的配置。`config.json`、`runtime/` 和本地测试产物都不会被 Git 跟踪。

## 开发与验证

在 Windows PowerShell 5.1 中，从仓库目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-RemoteCodex.ps1
```

测试使用本机模拟 SSH 和 VS Code 进程，覆盖正常关闭窗口、SSH 断开、VS Code 启动失败、原配置保持不变、无关进程保护和非法配置拒绝。测试不会连接真实服务器、读取真实 SSH 配置或读取登录凭据。测试产物保存在 `.test-artifacts/`。
