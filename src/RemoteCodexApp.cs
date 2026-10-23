using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("Remote Codex Switch")]
[assembly: AssemblyVersion("0.4.1.0")]
[assembly: AssemblyFileVersion("0.4.1.0")]

namespace RemoteCodexSwitch {
    public sealed class AppConfig {
        public string SshHost { get; set; }
        public int ProxyPort { get; set; }
        public bool AutoDetectProxyPort { get; set; }
        public string RemoteFolder { get; set; }
        public AppConfig() { SshHost = ""; ProxyPort = 7890; AutoDetectProxyPort = true; RemoteFolder = ""; }
        public void Validate() {
            if (!Regex.IsMatch(SshHost ?? "", "^[A-Za-z0-9][A-Za-z0-9._-]*$")) throw new Exception("请选择服务器，或填写 SSH 配置中的 Host 别名。");
            if (ProxyPort < 1024 || ProxyPort > 65535) throw new Exception("代理端口需要在 1024–65535 之间。");
            if (!String.IsNullOrEmpty(RemoteFolder) && !RemoteFolder.StartsWith("/")) throw new Exception("项目目录请填写服务器绝对路径，或留空打开远程主目录。");
        }
    }
    public sealed class PortItem {
        public int Port; public string Source;
        public override string ToString() { return Port + "  ·  " + Source; }
    }
    public sealed class RunResult { public int ExitCode; public string Output; public string Error; }

    public static class Program {
        public static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
        public static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);
        public static EventWaitHandle ShowRequest;
        public static EventWaitHandle ExitRequest;
        public static string DataRoot { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RemoteCodexSwitch"); } }
        public static string SshConfig { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh", "config"); } }
        public static string PowerShell { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"); } }
        public static string Quote(string value) {
            string escaped = Regex.Replace(value, "(\\\\*)\"", "$1$1\\\"");
            escaped = Regex.Replace(escaped, "(\\\\+)$", "$1$1");
            return "\"" + escaped + "\"";
        }
        public static List<string> ReadServers(string path) {
            var result = new List<string>();
            if (!File.Exists(path)) return result;
            foreach (string raw in File.ReadAllLines(path, Encoding.UTF8)) {
                string line = raw.Split('#')[0];
                Match match = Regex.Match(line, @"^\s*Host\s+(.+)$", RegexOptions.IgnoreCase);
                if (!match.Success) continue;
                foreach (string host in Regex.Split(match.Groups[1].Value.Trim(), @"\s+"))
                    if (Regex.IsMatch(host, "^[A-Za-z0-9][A-Za-z0-9._-]*$") && !result.Contains(host)) result.Add(host);
            }
            return result;
        }
        public static void InstallBackend() {
            Directory.CreateDirectory(DataRoot);
            foreach (string name in new [] { "RemoteCodex.ps1", "GuiBridge.ps1", "RemoteSession.py" }) {
                using (Stream input = Assembly.GetExecutingAssembly().GetManifestResourceStream(name)) {
                    if (input == null) throw new Exception("应用缺少内置组件，请重新下载完整版本。");
                    using (FileStream output = File.Create(Path.Combine(DataRoot, name))) input.CopyTo(output);
                }
            }
        }
        public static ProcessStartInfo BackendInfo(string file, string args) {
            var info = new ProcessStartInfo(PowerShell);
            info.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(Path.Combine(DataRoot, file)) + " " + args;
            info.WorkingDirectory = DataRoot;
            info.UseShellExecute = false; info.CreateNoWindow = true;
            info.RedirectStandardOutput = true; info.RedirectStandardError = true;
            info.StandardOutputEncoding = Encoding.UTF8; info.StandardErrorEncoding = Encoding.UTF8;
            return info;
        }
        public static Task<RunResult> RunBackend(string file, string args) {
            return Task.Run(delegate {
                using (Process process = Process.Start(BackendInfo(file, args))) {
                    Task<string> stdout = process.StandardOutput.ReadToEndAsync();
                    Task<string> stderr = process.StandardError.ReadToEndAsync();
                    process.WaitForExit();
                    return new RunResult { ExitCode=process.ExitCode, Output=stdout.Result, Error=stderr.Result };
                }
            });
        }
        [STAThread]
        public static int Main(string[] args) {
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            try {
                if (args.Length == 2 && args[0] == "--render-preview") {
                    using (var form = new MainForm(true)) {
                        form.ShowInTaskbar=false; form.StartPosition=FormStartPosition.Manual; form.Location=new Point(-24000,-24000);
                        form.Show(); Application.DoEvents(); form.PerformLayout();
                        using (var bitmap = new Bitmap(form.Width, form.Height)) {
                            form.DrawToBitmap(bitmap, new Rectangle(0, 0, form.Width, form.Height));
                            bitmap.Save(args[1], ImageFormat.Png);
                        }
                        form.Hide();
                    }
                    return 0;
                }
                if (args.Length == 2 && args[0] == "--self-test") {
                    string folder = args[1]; Directory.CreateDirectory(folder);
                    string fixture = Path.Combine(folder, "ssh-config");
                    File.WriteAllText(fixture, "Host sample # ignored-alias\n HostName example.invalid\nHost sample training-server *.invalid !blocked\n", Utf8);
                    if (String.Join(",", ReadServers(fixture)) != "sample,training-server") throw new Exception("Server list parsing failed.");
                    var config = new AppConfig { SshHost="sample", ProxyPort=7897, RemoteFolder="/home/user/a b", AutoDetectProxyPort=false };
                    config.Validate();
                    AppConfig loaded = Json.Deserialize<AppConfig>(Json.Serialize(config));
                    if (loaded.ProxyPort != 7897 || loaded.AutoDetectProxyPort) throw new Exception("Settings round-trip failed.");
                    bool rejected = false; try { new AppConfig { SshHost="-bad" }.Validate(); } catch { rejected=true; }
                    if (!rejected) throw new Exception("Invalid server name was accepted.");
                    using (var form = new MainForm(true)) { form.VerifyUiState(); }
                    Console.WriteLine("PASS GUI settings, server parsing, validation, and control state");
                    return 0;
                }
                bool created;
                using (var mutex = new Mutex(true, @"Local\RemoteCodexSwitch.Desktop", out created)) {
                    using(ShowRequest=new EventWaitHandle(false,EventResetMode.AutoReset,@"Local\RemoteCodexSwitch.Show")) {
                    using(ExitRequest=new EventWaitHandle(false,EventResetMode.AutoReset,@"Local\RemoteCodexSwitch.Exit")) {
                        if (!created) { if(args.Contains("--exit")) ExitRequest.Set(); else ShowRequest.Set(); return 0; }
                        if(args.Contains("--exit")) return 0;
                        InstallBackend();
                        Application.Run(new MainForm(false));
                    }
                    }
                }
                return 0;
            } catch (Exception error) {
                if (args.Length > 0) { Console.Error.WriteLine(error.ToString()); return 1; }
                MessageBox.Show(error.Message, "Remote Codex", MessageBoxButtons.OK, MessageBoxIcon.Error); return 1;
            }
        }
    }

    public sealed class MainForm : Form {
        readonly Color ink = Color.FromArgb(25, 35, 54), muted = Color.FromArgb(105, 116, 135), blue = Color.FromArgb(38, 99, 235);
        readonly bool preview;
        ComboBox servers, ports; TextBox folder; CheckBox auto;
        Button refresh, detect, start, stop, save, editSsh, syncLogin, openProject;
        Label badge, hint, footer; TextBox log;
        ProgressBar progress; System.Windows.Forms.Timer timer;
        Process controller; bool busy, closing, fillingPorts, needsPortChoice;
        DateTime detectedAt = DateTime.MinValue;
        int confirmedPort;
        string loadedHost = "";
        NotifyIcon tray; bool allowExit, trayNoticeShown;
        string ConfigPath { get { return Path.Combine(Program.DataRoot, "config.json"); } }
        string Runtime { get { return Path.Combine(Program.DataRoot, "runtime"); } }
        public MainForm(bool preview) {
            this.preview = preview;
            Text = "Remote Codex · 共享连接 · v0.4.1";
            ClientSize = new Size(920, 744); MinimumSize = Size; MaximumSize = Size;
            MaximizeBox = false; StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(245, 247, 251); ForeColor = ink;
            Font = new Font("Microsoft YaHei UI", 10F); AutoScaleMode = AutoScaleMode.None;
            AddLabel(this, "Remote Codex", 32, 24, 500, 42, 23F, ink, true);
            AddLabel(this, "开启一次，同一服务器的 VS Code 窗口共享使用。", 34, 72, 680, 25, 10F, muted, false);
            badge = AddLabel(this, "尚未开启", 750, 36, 138, 30, 10F, muted, true);
            badge.BackColor = Color.FromArgb(232, 237, 245); badge.TextAlign = ContentAlignment.MiddleCenter;
            Panel card = new Panel { Location=new Point(32, 120), Size=new Size(856, 284), BackColor=Color.White };
            Controls.Add(card);
            AddLabel(card, "服务器", 24, 18, 500, 24, 10F, ink, true);
            servers = new ComboBox { Location=new Point(24, 48), Size=new Size(626, 32), DropDownStyle=ComboBoxStyle.DropDown, Font=Font, IntegralHeight=false, DropDownHeight=200 };
            card.Controls.Add(servers);
            refresh = MakeButton(card, "刷新列表", 672, 46, 160, 34, false);
            AddLabel(card, "远程项目目录", 24, 96, 500, 24, 10F, ink, true);
            folder = new TextBox { Location=new Point(24, 124), Size=new Size(626, 31), BorderStyle=BorderStyle.FixedSingle, Font=Font };
            card.Controls.Add(folder);
            openProject = MakeButton(card,"打开 VS Code",672,122,160,34,false);
            AddLabel(card, "可选。也可以直接使用自己已经打开的远程窗口。", 24, 158, 800, 22, 9F, muted, false);
            auto = new CheckBox { Location=new Point(24, 207), Size=new Size(204, 28), Text="开启时自动检测端口", Checked=true, Font=Font, UseVisualStyleBackColor=true };
            card.Controls.Add(auto);
            AddLabel(card, "HTTP / Mixed 代理端口", 240, 180, 330, 24, 9F, muted, false);
            ports = new ComboBox { Location=new Point(240, 208), Size=new Size(322, 32), DropDownStyle=ComboBoxStyle.DropDown, Font=Font };
            card.Controls.Add(ports);
            detect = MakeButton(card, "自动检测", 584, 206, 248, 35, false);
            AddLabel(card, "支持自动识别，也可以直接输入端口号。", 24, 249, 800, 22, 9F, muted, false);
            start = MakeButton(this, "开启共享连接", 32, 424, 224, 46, true);
            stop = MakeButton(this, "关闭连接", 272, 424, 140, 46, false);
            syncLogin = MakeButton(this, "同步本机登录", 428, 424, 164, 46, false);
            save = MakeButton(this, "保存设置", 608, 424, 132, 46, false);
            editSsh = MakeButton(this, "SSH 配置", 756, 424, 132, 46, false);
            hint = AddLabel(this, "选择服务器，打开本机代理，再点击开启。", 34, 488, 850, 28, 10F, muted, false);
            progress = new ProgressBar { Location=new Point(34, 523), Size=new Size(850, 3), Style=ProgressBarStyle.Marquee, MarqueeAnimationSpeed=25, Visible=false };
            Controls.Add(progress);
            AddLabel(this, "运行记录", 34, 542, 800, 24, 9F, muted, true);
            log = new TextBox { Location=new Point(32, 571), Size=new Size(856, 124), Multiline=true, ScrollBars=ScrollBars.Vertical, ReadOnly=true, BorderStyle=BorderStyle.None, BackColor=Color.White, Font=new Font("Microsoft YaHei UI", 9F), ForeColor=muted };
            Controls.Add(log);
            footer = AddLabel(this, "关闭本窗口会收进托盘；关闭 VS Code 不断开。需停止时点击“关闭连接”或从托盘退出。", 34, 709, 850, 22, 8.5F, muted, false);
            refresh.Click += delegate { LoadServers(); };
            detect.Click += async delegate { await DetectAsync(true); };
            start.Click += async delegate { await StartAsync(); };
            stop.Click += async delegate { await StopAsync(); };
            syncLogin.Click += async delegate { await SyncLoginAsync(); };
            openProject.Click += async delegate {
                try {
                    SaveConfig(ReadControls());
                    RunResult result=await Program.RunBackend("RemoteCodex.ps1","-Action Open");
                    AppendLog(result.Output); if(result.ExitCode!=0) throw new Exception("未能打开 VS Code，请查看运行记录。");
                } catch(Exception ex) { ShowError(ex.Message); }
            };
            save.Click += delegate { try { SaveConfig(ReadControls()); AppendLog("设置已保存。"); } catch (Exception ex) { ShowError(ex.Message); } };
            editSsh.Click += delegate {
                try { Directory.CreateDirectory(Path.GetDirectoryName(Program.SshConfig)); if (!File.Exists(Program.SshConfig)) File.WriteAllText(Program.SshConfig, "", Program.Utf8); Process.Start("notepad.exe", Program.Quote(Program.SshConfig)); }
                catch (Exception ex) { ShowError(ex.Message); }
            };
            servers.SelectionChangeCommitted += delegate { if (servers.Text != loadedHost) folder.Text=""; detectedAt=DateTime.MinValue; };
            ports.SelectionChangeCommitted += delegate { if (!fillingPorts) { needsPortChoice=false; try { confirmedPort=ReadPort(); } catch { confirmedPort=0; } } };
            ports.TextChanged += delegate { if (!fillingPorts) needsPortChoice=false; };
            auto.CheckedChanged += delegate { detectedAt=DateTime.MinValue; };
            FormClosing += OnClosing;
            if (preview) {
                servers.Items.AddRange(new object[] { "my-server", "training-server" }); servers.SelectedIndex=0;
                folder.Text="/home/user/project"; ports.Text="7890";
                AppendLog("已加载 2 台服务器，可在上方切换。");
                AppendLog("开启后重新加载已有远程窗口；不需要保留某个 VS Code 窗口。");
            } else {
                LoadServers(); LoadConfig();
                AppendLog("应用已就绪。个人设置保存在本机，不会上传。");
                var menu=new ContextMenuStrip();
                menu.Items.Add("打开面板",null,delegate { ShowFromTray(); });
                menu.Items.Add("关闭连接",null,async delegate { await StopAsync(); });
                menu.Items.Add("退出并关闭连接",null,delegate { allowExit=true; Close(); });
                tray=new NotifyIcon { Icon=SystemIcons.Application, Text="Remote Codex · 尚未连接", Visible=true, ContextMenuStrip=menu };
                tray.DoubleClick += delegate { ShowFromTray(); };
                Resize += delegate { if(WindowState==FormWindowState.Minimized) HideToTray(); };
            }
            UpdateControls();
            timer = new System.Windows.Forms.Timer { Interval=600 };
            timer.Tick += delegate {
                if(Program.ExitRequest!=null && Program.ExitRequest.WaitOne(0)) { allowExit=true; Close(); return; }
                if(Program.ShowRequest!=null && Program.ShowRequest.WaitOne(0)) ShowFromTray();
                PollSession();
            };
            if (!preview) timer.Start();
        }
        Label AddLabel(Control parent, string text, int x, int y, int w, int h, float size, Color color, bool bold) {
            var label = new Label { Text=text, Location=new Point(x,y), Size=new Size(w,h), ForeColor=color, Font=new Font("Microsoft YaHei UI",size,bold?FontStyle.Bold:FontStyle.Regular), TextAlign=ContentAlignment.MiddleLeft };
            parent.Controls.Add(label); return label;
        }
        Button MakeButton(Control parent, string text, int x, int y, int w, int h, bool primary) {
            var button = new Button { Text=text, Location=new Point(x,y), Size=new Size(w,h), FlatStyle=FlatStyle.Flat, BackColor=primary?blue:Color.White, ForeColor=primary?Color.White:ink, Font=new Font("Microsoft YaHei UI",10F,primary?FontStyle.Bold:FontStyle.Regular), Cursor=Cursors.Hand };
            button.FlatAppearance.BorderSize=primary?0:1; button.FlatAppearance.BorderColor=Color.FromArgb(214,222,233);
            parent.Controls.Add(button); return button;
        }
        void Ui(Action action) { if (closing || IsDisposed) return; if (InvokeRequired) { try { BeginInvoke(action); } catch (InvalidOperationException) { } } else action(); }
        void AppendLog(string text) {
            if (String.IsNullOrWhiteSpace(text)) return;
            Ui(delegate { log.AppendText(DateTime.Now.ToString("HH:mm:ss") + "  " + text.Trim() + Environment.NewLine); log.SelectionStart=log.TextLength; log.ScrollToCaret(); });
        }
        void SetBadge(string text, Color background, Color color) { badge.Text=text; badge.BackColor=background; badge.ForeColor=color; }
        void ShowError(string message) { hint.Text=message; SetBadge("需要处理", Color.FromArgb(255,237,223),Color.FromArgb(166,78,20)); AppendLog(message); }
        bool Running { get { try { return controller != null && !controller.HasExited; } catch { return false; } } }
        void UpdateControls() {
            if(closing) return;
            bool idle = !busy && !Running;
            foreach (Control c in new Control[] { servers,ports,folder,auto,refresh,detect,save,start,editSsh }) c.Enabled=idle;
            syncLogin.Enabled=!busy;
            openProject.Enabled=!busy; folder.Enabled=!busy;
            stop.Enabled=Running && !busy; progress.Visible=busy;
        }
        void LoadServers() {
            string selected=servers.Text; servers.Items.Clear();
            foreach (string host in Program.ReadServers(Program.SshConfig)) servers.Items.Add(host);
            servers.Text=selected;
            AppendLog("已读取 SSH 配置，共 " + servers.Items.Count + " 个服务器别名。也可手动填写 Include 中的别名。");
        }
        void LoadConfig() {
            try {
                if (!File.Exists(ConfigPath)) { ports.Text="7890"; return; }
                AppConfig config=Program.Json.Deserialize<AppConfig>(File.ReadAllText(ConfigPath,Encoding.UTF8));
                servers.Text=config.SshHost; loadedHost=config.SshHost;
                ports.Text=config.ProxyPort.ToString(); folder.Text=config.RemoteFolder; auto.Checked=config.AutoDetectProxyPort;
            } catch (Exception ex) { ports.Text="7890"; AppendLog("原设置无法加载，请重新填写："+ex.Message); }
        }
        int ReadPort() {
            PortItem selected=ports.SelectedItem as PortItem;
            if (selected != null && ports.Text==selected.ToString()) return selected.Port;
            int value; if (!Int32.TryParse(ports.Text.Trim(),out value) || value<1024 || value>65535) throw new Exception("请选择或输入一个有效代理端口。");
            return value;
        }
        AppConfig ReadControls() {
            var config=new AppConfig { SshHost=servers.Text.Trim(), ProxyPort=ReadPort(), RemoteFolder=folder.Text.Trim(), AutoDetectProxyPort=auto.Checked };
            config.Validate(); return config;
        }
        void SaveConfig(AppConfig config) { Directory.CreateDirectory(Program.DataRoot); File.WriteAllText(ConfigPath,Program.Json.Serialize(config),Program.Utf8); loadedHost=config.SshHost; }
        async Task<bool> DetectAsync(bool explicitRequest) {
            if (busy || Running) return false;
            busy=true; UpdateControls(); hint.Text="正在检查系统代理和本机代理程序，请稍候……";
            SetBadge("检测中",Color.FromArgb(226,236,255),blue);
            int previous=7890; try { previous=ReadPort(); } catch { }
            string resultPath=Path.Combine(Runtime,"detect-"+Guid.NewGuid().ToString("N")+".json");
            try {
                Directory.CreateDirectory(Runtime);
                RunResult result=await Program.RunBackend("GuiBridge.ps1","-SavedPort "+previous+" -ResultPath "+Program.Quote(resultPath));
                if (closing) return false;
                if (!File.Exists(resultPath)) throw new Exception("端口检测未完成。请确认代理软件已打开，或手动填写端口。");
                var data=Program.Json.DeserializeObject(File.ReadAllText(resultPath,Encoding.UTF8)) as Dictionary<string,object>;
                if (data.ContainsKey("Error") && data["Error"] != null) throw new Exception(Convert.ToString(data["Error"]));
                var candidates=new List<PortItem>();
                foreach (object item in (IEnumerable)data["Candidates"]) {
                    var value=(Dictionary<string,object>)item;
                    candidates.Add(new PortItem { Port=Convert.ToInt32(value["Port"]), Source=Convert.ToString(value["Source"]) });
                }
                if (candidates.Count==0) throw new Exception("未检测到可用 HTTP 代理。请打开梯子；也可取消自动检测后，手动填写 HTTP / Mixed 端口。");
                fillingPorts=true; ports.Items.Clear(); foreach (PortItem item in candidates) ports.Items.Add(item);
                PortItem confirmed=candidates.Find(delegate(PortItem item) { return item.Port==confirmedPort; });
                needsPortChoice=candidates.Count>1 && confirmed==null;
                if (needsPortChoice) { ports.SelectedIndex=-1; ports.Text=""; hint.Text="发现多个可用端口，请从端口列表中选择，再点击开启。"; }
                else { ports.SelectedIndex=confirmed==null?0:candidates.IndexOf(confirmed); hint.Text="已检测到代理端口 "+ReadPort()+"。"; }
                fillingPorts=false; detectedAt=DateTime.UtcNow;
                SetBadge(needsPortChoice?"请选择端口":"检测完成",Color.FromArgb(224,244,234),Color.FromArgb(24,119,77));
                AppendLog(hint.Text);
                return !needsPortChoice;
            } catch (Exception ex) { if (!closing) ShowError(ex.Message); return false; }
            finally { busy=false; fillingPorts=false; if (!closing) UpdateControls(); try { if(File.Exists(resultPath)) File.Delete(resultPath); } catch { } }
        }
        async Task StartAsync() {
            if (busy || Running) return;
            try {
                if (auto.Checked && DateTime.UtcNow.Subtract(detectedAt).TotalSeconds>15) { if (!await DetectAsync(false)) return; }
                if (needsPortChoice) throw new Exception("请先在列表中选择要使用的代理端口。");
                AppConfig config=ReadControls(); SaveConfig(config);
                string stopFile=Path.Combine(Runtime,"stop.request"); if(File.Exists(stopFile)) File.Delete(stopFile);
                ProcessStartInfo info=Program.BackendInfo("RemoteCodex.ps1","-Action Start -GuiMode");
                controller=new Process { StartInfo=info, EnableRaisingEvents=true };
                controller.OutputDataReceived += delegate(object sender,DataReceivedEventArgs e) { AppendLog(e.Data); };
                controller.ErrorDataReceived += delegate(object sender,DataReceivedEventArgs e) { AppendLog(e.Data); };
                if (!controller.Start()) throw new Exception("未能启动连接，请重试。");
                controller.BeginOutputReadLine(); controller.BeginErrorReadLine();
                hint.Text="正在连接 "+config.SshHost+"；需要密码或首次确认时，会弹出 SSH 登录窗口。";
                SetBadge("连接中",Color.FromArgb(226,236,255),blue); UpdateControls();
            } catch (Exception ex) { ShowError(ex.Message); UpdateControls(); }
        }
        async Task StopAsync() {
            if (busy) return;
            busy=true; UpdateControls(); hint.Text="正在关闭本应用的代理隧道……";
            try {
                RunResult result=await Program.RunBackend("RemoteCodex.ps1","-Action Stop");
                AppendLog(result.Output); if(result.ExitCode!=0) throw new Exception(result.Error);
                if (controller != null) await Task.Run(delegate { controller.WaitForExit(5000); });
                if(Running) { controller.Kill(); await Program.RunBackend("RemoteCodex.ps1","-Action Stop"); }
                hint.Text="共享连接已关闭，远端代理设置已请求恢复。服务器计算任务继续运行。";
                if(tray!=null) tray.Text="Remote Codex · 尚未连接";
                SetBadge("尚未开启",Color.FromArgb(232,237,245),muted);
            } catch (Exception ex) { ShowError(ex.Message); }
            finally { if(controller!=null && !Running) { controller.Dispose(); controller=null; } busy=false; UpdateControls(); }
        }
        async Task SyncLoginAsync() {
            if (busy) return;
            try {
                AppConfig config=ReadControls();
                if (MessageBox.Show(this,
                    "将把本机 Codex 登录文件通过 SSH 发送给服务器「"+config.SshHost+"」的登录用户。\n\n该服务器用户下的其他 Codex 窗口也会共用此登录。已有登录文件会先备份；请只同步到你信任的服务器。\n\n同步后仍需保持代理连接。是否继续？",
                    "同步本机 Codex 登录",MessageBoxButtons.OKCancel,MessageBoxIcon.Information)!=DialogResult.OK) return;
                SaveConfig(config); busy=true; UpdateControls();
                hint.Text="正在通过 SSH 同步登录；此过程不会将登录文件上传到 GitHub。";
                RunResult result=await Program.RunBackend("RemoteCodex.ps1","-Action SyncLogin -GuiMode");
                AppendLog(result.Output);
                if(result.ExitCode!=0) throw new Exception("同步未完成。请确认本机 Codex 已登录，并检查运行记录。");
                hint.Text="登录已同步。请重新加载远端 Codex；使用时仍需保持代理连接。";
                AppendLog(hint.Text);
            } catch(Exception ex) { ShowError(ex.Message); }
            finally { busy=false; UpdateControls(); }
        }
        void PollSession() {
            if (busy || controller==null) return;
            if (!Running) {
                int exitCode=controller.ExitCode; controller.Dispose(); controller=null; detectedAt=DateTime.MinValue;
                if(exitCode==0) { hint.Text="连接已结束。可以更换服务器或重新开启。"; SetBadge("尚未开启",Color.FromArgb(232,237,245),muted); }
                else ShowError("连接未完成，请查看下方运行记录。");
                UpdateControls(); return;
            }
            try {
                string stateFile=Path.Combine(Runtime,"session.json"), connectionLog=Path.Combine(Runtime,"connection.log");
                if (!File.Exists(stateFile) || !File.Exists(connectionLog)) return;
                var state=Program.Json.DeserializeObject(File.ReadAllText(stateFile,Encoding.UTF8)) as Dictionary<string,object>;
                using(var ssh=Process.GetProcessById(Convert.ToInt32(state["SshPid"]))) {
                    if(ssh.StartTime.ToUniversalTime().Ticks.ToString()!=Convert.ToString(state["SshStartedUtcTicks"])) return;
                    using(var stream=new FileStream(connectionLog,FileMode.Open,FileAccess.Read,FileShare.ReadWrite))
                    using(var reader=new StreamReader(stream,Encoding.UTF8)) {
                        if(!reader.ReadToEnd().Contains("CODEX_SWITCH_READY")) return;
                    }
                }
                SetBadge("共享已开启",Color.FromArgb(224,244,234),Color.FromArgb(24,119,77));
                hint.Text="该服务器的远程窗口重新加载后可用；关闭编辑窗口不会断开。账号登录请在面板确认。";
                if(tray!=null) tray.Text="Remote Codex · 共享连接已开启";
            } catch { }
        }
        void OnClosing(object sender,FormClosingEventArgs e) {
            if(!preview && !allowExit && e.CloseReason!=CloseReason.WindowsShutDown && e.CloseReason!=CloseReason.ApplicationExitCall) { e.Cancel=true; HideToTray(); return; }
            closing=true; timer.Stop();
            if(tray!=null) { tray.Visible=false; tray.Dispose(); }
            if (preview || !Running) return;
            try {
                Program.RunBackend("RemoteCodex.ps1","-Action Stop").Wait(5000);
                if(!controller.WaitForExit(3000)) { controller.Kill(); Program.RunBackend("RemoteCodex.ps1","-Action Stop").Wait(5000); }
            } catch { }
        }
        void ShowFromTray() { Show(); WindowState=FormWindowState.Normal; Activate(); }
        void HideToTray() {
            Hide();
            if(tray!=null && !trayNoticeShown) {
                trayNoticeShown=true;
                tray.ShowBalloonTip(3000,"Remote Codex 在后台运行","连接会继续保持。双击托盘图标或桌面程序可打开面板；从托盘菜单退出可停止连接。",ToolTipIcon.Info);
            }
        }
        public void VerifyUiState() {
            if(!start.Enabled || stop.Enabled) throw new Exception("Initial button state is incorrect.");
            busy=true; UpdateControls(); if(start.Enabled || detect.Enabled || servers.Enabled) throw new Exception("Busy controls were not disabled.");
            busy=false; UpdateControls(); if(!start.Enabled) throw new Exception("Idle controls were not restored.");
        }
    }
}
