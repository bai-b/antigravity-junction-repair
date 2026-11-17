# Antigravity Junction Repair

把 Antigravity 的数据目录搬到另一个磁盘，用 **NTFS 目录联接（junction）** 保持原路径继续可用；应用更新把该目录重新建成普通文件夹之后，双击一下就能恢复成本来的样子。

> 适用对象：Windows 10 / 11，PowerShell 5.1 及以上，不需要管理员权限。

---

## 它解决什么问题

Antigravity 把所有工作数据写在：

```
%USERPROFILE%\.gemini\antigravity
```

里面是 `conversations`（会话记录）、`brain`、`worktrees`、`scratch`、`sidecar_data` 等，实测一套用下来 900 MB 起步，长期使用会更大，C 盘很快紧张。

常规做法是把目录搬到 D 盘，再建目录联接：

```cmd
robocopy "C:\Users\<你>\.gemini\antigravity" "D:\antigravity_data" /E /MOVE
mklink /J "C:\Users\<你>\.gemini\antigravity" "D:\antigravity_data"
```

问题是**这一步不是一劳永逸的**：Antigravity 更新或重装时，如果它发现原路径不存在（或者干脆忽略联接），会重新建一个普通目录，新数据又写回 C 盘，联接失效——而且此时 C 盘里是一份新数据、D 盘里是一份旧数据，手动合并不小心就会丢会话记录。

本项目就是把"恢复联接"做成一键动作：**更新后双击一次，自动合并两边数据、校验、重建联接**。

---

## 工作方式

```
                                     ┌─────────────────────────────┐
C:\Users\<你>\.gemini\antigravity  ──┼─►  Junction  ──────────────► │ D:\antigravity_data        │
   (应用仍按原路径读写，无感知)        │                             │ (真实字节都在这里)          │
                                     └─────────────────────────────┘
```

修复流程（全部幂等，可反复运行）：

1. 检测并关闭正在运行的 Antigravity（先正常关窗，2 秒后强制结束）。
2. 判定当前状态：正确的联接 / 指向别处的联接 / 普通文件夹 / 路径不存在。
3. 需要合并时用 `robocopy /E`（**只增不删**，D 盘历史数据绝不被删除）。
4. 逐文件校验：源目录的每个相对路径都必须在目标目录里存在，缺一个就中止。
5. 源目录改名为 `antigravity.__bak`，建立 junction，做写入穿透测试。
6. 测试通过才删除备份；任何一步失败都保留源目录原样。

---

## 快速开始

### 方式 A：双击（推荐）

打开本文件夹，双击 **`Fix-Antigravity-Junction.cmd`**。

启动器用 `%~dp0` 定位同目录的 `repair.ps1`，因此**整个文件夹可以随意移动、改名、放进任何盘**。不需要安装，不往桌面、开始菜单、注册表写任何东西。跑完窗口会停住显示结果，按任意键关闭。

### 方式 B：命令行

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\repair.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\repair.ps1 -Dest E:\antigravity_data
powershell -NoProfile -ExecutionPolicy Bypass -File .\repair.ps1 -Source "D:\other\antigravity" -Dest "E:\data"
```

---

## 四种状态与对应动作

| 运行前状态 | 脚本动作 |
| --- | --- |
| 联接已正确指向目标 | 只报告文件数与占用，**不做任何改动**，退出码 0 |
| 联接指向别的位置 | 先把旧目标数据合并进新目标，再删联接重建 |
| 更新后重建出的普通文件夹 | `robocopy /E` 合并 → 逐文件校验 → 改名备份 → 建联接 → 删备份 |
| 路径不存在 | 直接建立联接 |

---

## 参数

| 参数 | 含义 | 默认值 |
| --- | --- | --- |
| `-Dest <路径>` | 数据落地目录 | `D:\antigravity_data` |
| `-Source <路径>` | 应用数据目录 | `%USERPROFILE%\.gemini\antigravity` |
| `/auto` | 由 `run.cmd` 传入，运行结束不暂停 | 关闭 |

`Dest/Source` 也支持 `-Dest=E:\data` 写法，`/dest`、`--dest` 等价。

---

## 输出对照

| 日志行 | 含义 |
| --- | --- |
| `state: JUNCTION -> ...` | 当前是目录联接，后面是它指向的目标 |
| `state: PLAIN FOLDER ...` | 普通文件夹，通常是更新重建出来的 |
| `state: PATH MISSING` | 路径不存在 |
| `robocopy exit = N` | `0` 无变化，`1~3` 有文件被复制，`≥8` 失败（脚本会中止） |
| `missing files = 0` | 校验通过，源文件全部落到目标 |
| `write-through check: OK` | 通过 C 盘路径写入，实际落到目标盘 |
| `result: junction already correct, nothing changed` | 已正确，无需操作 |

每次运行都会新写一份日志：`%TEMP%\antigravity_junction_yyyyMMdd_HHmmss.log`。

---

## 安全设计

- **从不用 `/MIR`**：合并只增不删，D 盘的历史会话不会被"同步"掉。
- **先校验后删除**：逐文件相对路径比对，缺失即中止并保留源目录。
- **改名而非直删**：源目录先变成 `antigravity.__bak`，联接建立并验证通过后才真正删除。
- **失败即停**：任何异常都会打印 `FAILED: ...`，退出码 1，状态停在一个可手工收拾的位置。
- **先关应用**：动文件之前确认进程已退出，避免句柄占用导致半途失败。

---

## 常见问题

**Q：需要管理员权限吗？**
不需要。NTFS 目录联接（junction）普通用户即可创建；只有目录符号链接（symlink）才要管理员。

**Q：中文用户名路径能用吗？**
能。测试环境就是 `C:\Users\晗`，脚本全程 `.NET` 与 `robocopy` 的 Unicode 路径接口。

**Q：文件夹能挪位置吗？**
能。启动器用 `%~dp0` 解析自身所在目录，整个文件夹换盘、改名、克隆到另一台机器都不影响运行。

**Q：目标盘不存在 / 盘符改了？**
目标盘不可用时脚本直接报错退出，不会留下半成品；想换盘用 `-Dest`。

**Q：会被杀软拦吗？**
脚本只做文件复制、校名、建联接，不下载、不注入。若企业策略禁止脚本执行，可改用手动命令（见下方"手动等价操作"）。

**Q：脚本会不会把我的会话记录搞丢？**
不会主动删除任何业务文件；唯一的删除动作是"校验通过后删除自己刚改的名的备份目录"。

---

## 手动等价操作（不想跑脚本时）

```cmd
:: 1. 完全退出 Antigravity
taskkill /im Antigravity.exe /f /t

:: 2. 合并到 D 盘（只增不删）
robocopy "%USERPROFILE%\.gemini\antigravity" "D:\antigravity_data" /E /COPY:DAT /DCOPY:T

:: 3. 确认文件数与体积一致后，把原目录改名
move "%USERPROFILE%\.gemini\antigravity" "%USERPROFILE%\.gemini\antigravity.__bak"

:: 4. 建立联接
mklink /J "%USERPROFILE%\.gemini\antigravity" "D:\antigravity_data"

:: 5. 确认能正常打开后删除备份
rd /s /q "%USERPROFILE%\.gemini\antigravity.__bak"
```

---

## 卸载 / 还原

不想再用这个工具：直接删掉本文件夹即可。它不在系统里留任何痕迹——不写注册表、不建开机项、不往别处复制文件。

把数据搬回 C 盘并恢复普通目录：

```cmd
rd "%USERPROFILE%\.gemini\antigravity"
robocopy "D:\antigravity_data" "%USERPROFILE%\.gemini\antigravity" /E /COPY:DAT
```

---

## 目录结构

```
antigravity-junction-repair/
├─ Fix-Antigravity-Junction.cmd  ← 双击这个
├─ repair.ps1                    全部逻辑（纯 ASCII 输出，避免代码页问题）
├─ README.md                     本文档
├─ LICENSE                       MIT
├─ .gitattributes                强制 .cmd/.ps1 使用 CRLF
└─ .gitignore
```

---

## License

MIT，见 [LICENSE](LICENSE)。
