# Interface operations

Target **{{APP_NAME}}**, `{{BUNDLE_ID}}`. Labels below pair English and Simplified Chinese; use the labels visible in the current UI. Do not switch language just to find a control. Inspect the resulting UI after each operation.

## Manager and menu bar

- **Manager / 管理** (⌘,) reuses a single management window. The menu bar lists scripts with current status and scrolls when necessary.
- **Add Custom Command… / 添加自定义命令…** is available in Manager and the menu bar. Menu bar creation opens the editor in Manager.
- Script rows show name, command, working directory, disabled state, at-launch indicator, last run and duration. Status is **Idle / 未运行**, **Running / 运行中**, **Success / 成功**, **Failed / 失败**, or **Stopped / 已停止**.
- Manager row buttons and the row context menu provide **Edit / 编辑**, **Output / 输出**, **Run / 运行** or **Stop / 停止**, and **Delete / 删除**. Menu bar rows provide Run/Stop.
- **Quit / 退出** (⌘Q) exits the app. It does not stop tracked running scripts. Stop requested scripts first only when that is part of the user's request.

## Add, edit, enable, and launch behavior

1. Click **Add Custom Command… / 添加自定义命令…** (⌘N), or the target row's **Edit / 编辑**.
2. Set **Name / 名称**, **Command / 命令** (supports multiple lines), and **Working Directory (optional) / 工作目录（可选）**. **Browse… / 浏览…** opens a directory chooser; select the requested directory and **Select / 选择**, or cancel. An empty directory uses the app's default. A blank name displays as **Untitled Script / 未命名脚本**.
3. **Enabled / 启用** determines whether Run and Run All can execute this script. **Run when Scriptser launches / 随 Scriptser 启动运行** opts an enabled script into automatic execution on the next app launch. Already running tracked scripts are recovered without another launch. This is separate from Launch at Login.
4. **Save / 保存** (⌘S) persists the draft. Empty commands disable Save. **Cancel / 取消** or Escape discards the draft. Verify the saved row and toggles through Edit as needed.

Commands execute via `/bin/zsh -ilc` using the login and interactive shell environment. Commands may have external effects; use the exact requested command. Tags participate in search but have no editor control in this version.

## Delete

Use the target row's **Delete / 删除**, its context menu, or deletion from the selected list row. Inspect the confirmation naming the script. **Delete / 删除** confirms; **Cancel / 取消** retains it. Deletion stops a running target and removes its saved definition, so do not delete merely to stop it. Verify the row is gone.

## Search and filters

**Search scripts… / 搜索脚本…** (⌘F) matches names, commands, directories, and tags without case sensitivity. Choose **All Scripts / 全部脚本**, **Running / 运行中**, or **At Launch / 自启动**. Search and the active filter combine; At Launch includes disabled scripts with their launch flag set. Clear the query and select All Scripts to restore the full list. Selection identifies a row; it does not execute it.

## Run and stop

- **Run / 运行** starts the chosen enabled script. Run is disabled during initial recovery and for disabled scripts; running rows show Stop. Verify Running or a final Success/Failed status, using Output for short commands.
- **Stop / 停止** requests termination of the tracked target process. Verify the resulting status; termination can be asynchronous.
- **Run All / 全部运行** (⇧⌘R in Manager) starts enabled scripts that are not already running. **Stop All / 全部停止** (⇧⌘. in Manager) stops all tracked scripts. Batch operations apply to the entire saved list, including rows hidden by search/filter. Both are available in the menu bar.
- A restored process may show **Running (restored) / 运行中（已恢复）**. Recovery restores tracking, not historical output. Inspect failures and exit information rather than assuming a click succeeded.
- Running scripts display **PID: …** and **End Process / 结束进程** in Manager, the menu bar, and Output. The PID identifies the tracked shell process, not all of its descendants. End Process asks for confirmation naming the script and PID, then sends SIGKILL to that exact tracked PID. Use it when the user requests force termination or a process does not respond to Stop. Confirming an old dialog after the process changes is rejected. This does not terminate an entire process tree. Verify the Stopped status and disappearance of the PID.

## Output

Open the target row's **Output / 输出**. The viewer refreshes every second and shows status, duration, character count, and a **Live / 实时** indicator while running.

- **Auto-scroll / 自动滚动** toggles following new output. Turn it off to inspect earlier lines, or scroll the viewer manually.
- **Refresh output / 刷新输出** fetches the current buffer immediately.
- **Clear output / 清空输出** clears the app's in-memory buffer; it does not stop the script or clear external log files. New output may appear immediately if the script is still running.
- Select output text to copy a portion, or **Copy All / 复制全部** to copy the buffer. Copy All is disabled when empty. Clipboard contents can contain private output; transfer only what the user requested.
- **Close / 关闭** or Escape dismisses the viewer. It does not stop the script.

## Import, export, and configuration folder

In Manager, open **Import/Export / 导入／导出**.

- **Import Scripts… / 导入脚本…** (⇧⌘I) opens a JSON file chooser. Select the requested file, confirm, and verify the resulting scripts. The current UI appends imported scripts to the saved list; it does not offer a replace/merge chooser. Re-importing can create duplicates, so inspect existing scripts first. Imported automatic-execution flags apply on the next app launch. Malformed JSON presents an error; inspect it before retrying.
- **Export Scripts… / 导出脚本…** (⇧⌘E) opens a save panel for the full saved list, including rows hidden by search/filter. Choose the requested path and verify the JSON file was saved. It includes script definitions and launch flags, not live output or preferences. Canceling the panel makes no change.
- **Open Config Folder / 打开配置文件夹** opens the active config directory in Finder. Production uses `~/Library/Application Support/Scriptser/config.json`; DEV uses `~/Library/Application Support/Scriptser-DEV/config.json`. Use UI import/export for modifications rather than editing a running app's file behind its back.

## Settings

- **Launch at Login / 登录时启动** toggles registration with macOS Login Items. Verify the toggle and any error. When macOS requires approval, direct the user to System Settings → General → Login Items; the signed bundled app is required. DEV does not register a login item.
- **Language / 语言** chooses **Follow System / 跟随系统**, **简体中文**, or **English**. Changes apply immediately to interface strings and are saved. Script names, commands, and raw output are unchanged.

## AI Skill directory and adding guide

Open **AI Skill** (⇧⌘K) in Manager's settings row.

1. **Choose Directory… / 选择目录…** opens a folder chooser. Choose the assistant's parent skills folder; the app creates the `scriptser-control` child folder. The default is `~/.codex/skills`, or `$CODEX_HOME/skills` when that environment variable is available to the app. Another assistant can use its own discovery directory or import the generated folder. The selected path is remembered.
2. **Generate Skill / 生成 Skill** (⌘S) writes `SKILL.md` and `references/ui.md`. Verify **Generated at… / 已生成至…**. Repeat generation updates these bundled instructions, preserving additional files. An unrelated Skill at that path or a symlink is rejected; choose another parent directory. User edits to the two generated files are replaced on regeneration.
3. **Open Skill Folder / 打开 Skill 文件夹** reveals the generated package in Finder. **Copy Adding Prompt / 复制添加指引** copies a prompt with the absolute SKILL.md path; **Prompt Copied / 指引已复制** confirms the clipboard action.
4. Start a new assistant chat for discovery, invoke `$scriptser-control`, or paste the path prompt to load it directly. The assistant still needs an available macOS automation tool and Accessibility permission; this package supplies guidance only.
5. Expand **Preview Skill / 预览 Skill** to inspect the bundled entrypoint before generating; it is selectable text. **Close / 关闭** or Escape dismisses the dialog. DEV's package and invocation are `scriptser-dev-control`, targeting DEV only.

## App updates

Manager and the menu bar expose version information, **Check for Updates… / 检查更新…**, and **Visit Releases / 查看发布页面**. A check contacts the official GitHub stable release and may use its release webpage when the API is rate limited. Checks are manual; concurrent/recent requests may share a cached result.

- Read **You’re up to date. / 已是最新版本。**, **No releases published yet. / 尚未发布版本。**, an error, or the available version. Use **View Update / 查看更新** to reopen newer-release details.
- Inspect the installed version and release notes. **Download Update… / 下载更新…** chooses a destination and downloads a compatible macOS package, verifying its size and digest when provided. Wait for completion; Close is disabled during download. If no compatible package exists or webpage fallback lacks package metadata, use Visit Releases for available installation options.
- **Open Download / 打开更新包** opens the verified package. **Show in Finder / 在访达中显示** reveals it. Installation requires quitting and replacing the app in Applications or completing the installer; the app does not replace itself. Only install when the user's request includes it. Preserve scripts and preferences.
- **Close / 关闭** or Escape dismisses release details when no download is active. Inspect check/download errors at the initiating control; do not repeatedly retry unchanged failures.
