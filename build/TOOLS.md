# build/ 下的验收工具链（本项目自有资产，已被 git 跟踪）

`build/` 整体是**构建产物目录**，已在 `.gitignore` 中被忽略。但下面三个子目录**不是产物**，
而是本项目在“最小窗口几何 / 黑盒 AX 验收”时使用的**取证工具**，来源是项目自身的开发过程。
为避免日后清理 `build/` 时把它们一起丢掉，这几个**源码文件**用 `git add -f` 强制纳入了版本库。

## 为什么它们留在 build/ 而不搬家

每个工具的驱动脚本都用 `REPO="$(cd "$(dirname "$0")/../.." && pwd)"` 反推仓库根，
并把自己的输出目录写成 `$REPO/build/<工具名>`。**移动目录会同时改掉这两个路径**，
所以按原样留在 `build/` 下；`build/` 其余内容（二进制、`*.dSYM`、`*.log`）**故意不纳入 git**。

## 三个工具

| 目录 | 工具 | 作用 |
| --- | --- | --- |
| `build/settings-probe/` | `probe.sh` + `SettingsProbe.m` | 设置页几何探针：逐个控件测**越界**与**两两重叠**。默认模拟 RD-11 路径（只 autoresize），`--real-path` 走 resize → `layoutSettingsControls` 真实路径 |
| `build/ui-probe/` | `AXProbe.m`、`DetailProbe.m`、`ui_audit.py`、`accept*.sh` | 黑盒 AX 取证：读真实 App 的辅助功能树、按下控件、缩放窗口、触发探测；`accept_all.sh [3\|4\|5\|6\|7]` 跑第 11 轮那 7 项黑盒验收 |
| `build/detail-probe/` | （无源码，是 `ui-probe/DetailProbe.m` 的编译输出） | 详情面板几何：长标题 + 画质下拉可见，多尺寸 0 越界/0 重叠 |

## 重建方式（不需要手动敲 clang）

```bash
bash build/settings-probe/probe.sh [--real-path]   # 重建并运行设置页几何探针
bash build/ui-probe/detail-probe.sh                # 重建并运行详情面板几何探针
bash build/ui-probe/accept_all.sh [3|4|5|6|7]      # 黑盒验收（需要 /Applications 里有已安装的 App）
```

两个 `*-probe.sh` 都会先跑 `scripts/generate-version.sh`（幂等：只重算代码行数，**不改变修复轮数**），
并把 `RD_LOG_PATH` 指向自己的输出目录，**不会污染** `~/Library/Logs/ResourceDetector.log`。

## 已纳入 git 的文件

- `settings-probe/SettingsProbe.m`、`settings-probe/probe.sh`
- `ui-probe/AXProbe.m`、`ui-probe/DetailProbe.m`、`ui-probe/ui_audit.py`、`ui-probe/*.sh`
- `TOOLS.md`（本文件）

**未纳入**（可随时重新编译或重新生成）：同名 Mach-O 可执行文件、`*.dSYM/`、`*.log`。

## 使用背景

这套工具是第 11 轮（v24151.11）为验证“设置页与详情区在最小窗口下 0 越界 0 重叠”而写的。
当时的教训值得记住：**既有断言只查“不越界”、不查“两两重叠”**，所以测试全绿时产品上仍存在
5 组真实压盖。工具链留存的意义就是让这类几何回归下次能被直接复测，而不是重写一遍。
详见 `outputs/ui-fix-20260916/REPORT.md`。
