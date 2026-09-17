# 资源探测

这是“资源探测”项目的源码仓库。项目用于整理和开发资源探测相关功能。

## 目录结构

- `src/`：项目源码。
- `tests/`：自动化测试和测试数据。
- `resources/`：运行所需的资源，例如图片、字典、示例配置和静态文件。
- `third_party/`：第三方组件源码；应同时保留其原许可证。
- `scripts/`：构建、检查、格式化等辅助脚本。
- `build/`：编译或构建产生的文件，不提交到 Git。
- `tmp/`：临时文件、调试输出和中间文件，不提交到 Git。
- `outputs/`：本地生成的交付文件，不作为源码提交。
- `work/`：本地整理过程中的工作文件，不作为源码提交。

## 版本号与正式构建（必读）

版本号规则与正式构建流程是项目永久规则，见根目录 [AGENTS.md](AGENTS.md)：
版本号固定为 `v<src 代码总行数>.<修复轮数>`（小写 `v`）；修复轮数唯一来源是根目录
`PROJECT_VERSION.json`（项目永久记录，必须随仓库提交）。普通构建用
`bash scripts/build.sh`；只有用户确认"完成一轮修复并产出可安装版本"时才用
`bash scripts/build-release.sh --release-fix`（同一轮重复执行不会重复递增）。

## 给 Git 初学者的使用步骤

1. 安装 Git，并在本目录执行 `git init` 初始化仓库。
2. 执行 `git status` 查看哪些文件会被记录。
3. 执行 `git add README.md LICENSE .gitignore AGENTS.md PROJECT_VERSION.json src tests resources third_party scripts` 准备提交。
4. 执行 `git commit -m "整理项目结构和基础文档"` 保存一次本地版本。
5. 在 GitHub 创建一个空仓库后，再按 GitHub 页面给出的命令绑定远程仓库。
6. 在确认内容中没有密钥、个人路径、日志和构建产物后，才考虑推送。

本次整理只在本地完成，不会推送到 GitHub。

## 开源协议

本项目使用 **MIT License（MIT 开源协议）**：允许他人使用、复制、修改和分发代码，但需要保留版权声明和许可证文本。协议全文见 [LICENSE](LICENSE)。

## 安全检查提醒

不要把密码、API 密钥、访问令牌、个人绝对路径、日志文件或 `build/`、`tmp/` 中的内容提交到 Git。

## 已整理的源码

原始资料位于 `~/Documents/扫描器源码`。本项目保留原始资料不变，并复制整理为：源码进入 `src/`，测试进入 `tests/`，资源进入 `resources/`，第三方组件进入 `third_party/`，构建脚本进入 `scripts/`。原始说明文档暂存于 `work/`，便于后续核对。
