<p align="center">
  <img src="assets/pallas-front.webp" width="900" alt="正面端坐在雪山前的兔狲">
</p>

<h1 align="center">Pallas Agent</h1>

<p align="center">
  <b>把 AI Agent 整个装进 iPhone。</b><br>
  <a href="https://testflight.apple.com/join/73Pbt1su">TestFlight 下载</a> · <a href="README.md">English</a>
</p>

**iPhone 上的 App 里跑着一台真正的 Linux。** bash、Node.js、Python、npm 全都有，不越狱、不靠 JIT，从 TestFlight 装上就能用。它还能自己操作手机上的其他 App，也能把任务交给你的电脑，再把结果带回手机。

Pallas Agent 是基于 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的原生 Swift/SwiftUI 客户端。模型推理需要联网，可以用 ChatGPT 登录、使用 DeepSeek 账号，或添加任意 OpenAI 兼容接口。

**0.5.1** · 2026-11-18 · iOS 18+

<p align="center">
  <a href="assets/pallas-demo.mp4"><img src="assets/pallas-demo-preview.gif" width="270" alt="Pallas Agent 演示：一条消息完成建日历、清洗报名表、在 Mac 上生成简报"></a><br>
  <a href="assets/pallas-demo.mp4">▶ 看完整视频（42 秒，有声）</a>
</p>

## 一条消息，三件事

视频里只发了一条消息，Pallas Agent 自己做完了三件事：

1. **看懂海报，建好日历**：从活动海报里读出时间和地点，打开系统日历建好活动，设好提前一小时提醒，再回去核对一遍。
2. **在手机里跑 Python**：清洗 29 行报名表，去掉重复、标出缺邮箱的人，生成干净的 CSV 和报名统计。
3. **连上 Mac 接着干**：在电脑上找到最新的安装包，生成一份活动简报网页，再传回手机。

全程用 5G，没接一根线。约 6 分半、41 步，三份文件都回到手机上。

## 说一句话就能做

> 「在备忘录新建一条，标题是周五清单，正文写下午三点取快递。」

手机自己打开备忘录、点按、输入，最后再看一遍屏幕确认。

> 「用我 Mac 上的 ffmpeg 把这段视频转成 MP4。」

视频从手机传到电脑，在电脑上转好，再传回手机。

## 安装与测试

| 方式 | 包含 | 需要 |
| --- | --- | --- |
| [TestFlight 公开测试](https://testflight.apple.com/join/73Pbt1su) | 聊天、本机 Linux 沙箱、插件与技能、连接电脑 | 一台 iOS 18+ 的 iPhone 或 iPad |
| 侧载安装包（测试中） | 以上全部 + 手机操控执行器 | Mac、免费 Apple 账号、开发者模式 |

## 主要功能

### 在手机上运行 Linux

切到「本机」，引擎就在 iPhone 上运行。模型第一次调用 bash 时，App 在自己的进程里启动一台 arm64 Linux 虚拟机，并把工作区挂进去。之后再启动，从保存好的机器状态恢复，**约 1.6 秒**就能执行命令。

<img src="assets/local-terminal.webp" width="360" alt="兔狲敲着键盘，在手机终端运行命令">

- **真 shell**：bash、Node.js、npm、Python 3.12、curl、git、ripgrep 开箱即用，能跑脚本、读写 Excel / Word / PPT。
- **文件留在手机上**：工作区、附件和生成的文件都存在 App 里；授权的文件夹（包括整个 iCloud Drive）也能直接给模型读写和搜索。
- **插件与技能，和电脑互通**：安装 npm 上的 DSH 插件，或导入桌面 DSH 的插件目录；手机上装好的插件也能打包分享回电脑。贴 GitHub 链接或导入 ZIP、tgz、`.skill` 包安装技能，装好立即可用。
- **局域网设备**：模型能找到并访问同一网络里的打印机、NAS、智能家居网关、网页管理页、SSH 服务器，也能把 Linux 里启动的服务发布到局域网。
- **模型随意换**：用 ChatGPT 或 DeepSeek 账号登录，或添加任何 OpenAI 兼容接口，在输入框里随时切换。

### 让兔狲操作手机 App

手机自己看屏幕、点按、滑动、输入，**不需要电脑在旁边**：拔掉数据线、关掉 Wi-Fi、只用蜂窝网络也能操作（已在 iPhone 17 Pro、iOS 27 上验证）。

<img src="assets/phone-control.webp" width="360" alt="兔狲伸爪点按手机上的备忘录">

- **看得见屏幕**：支持读图的模型收到真实截屏，文字模型收到设备上 OCR 出的文字和位置。
- **执行前核对**：每次触控前重新截屏比对，画面变了就让模型重新看。
- **多步导航**：模型可以一次提交整段计划，由执行器逐步执行、逐步核对。
- **关键步骤先问你**：打开 App、发送、删除、付款前先征得同意；别的 App 在前台时，用系统通知上的「允许 / 不允许」回答。也可以改成全程自动。
- **随时接管**：切回 Pallas Agent 或锁屏，本轮操控立即撤销。

手机操控默认关闭，需要单独安装配套的执行器并开启开发者模式，无需越狱。

### 把任务交给电脑

手机可以随时切到一台运行 DeepSeek Harness 的电脑，也可以在手机对话里直接把一件事交给电脑做。

<img src="assets/computer-link.webp" width="360" alt="兔狲在笔记本电脑和手机之间传送文件">

- **自动发现**：装了配对插件的电脑会在局域网里广播自己，打开「远程主机」就能看到，点一下扫码配对；电脑换了 IP 也能自动重新找到。
- **扫码或 SSH**：配对码包含电脑的所有地址（局域网、Tailscale 等），手机自动挑能连上的；也可以用 SSH 连接，并直接打开电脑终端。
- **在手机对话里把活交给电脑**：模型把任务和文件一起交给电脑，征得你同意后执行；实时面板显示每一步和电脑截图，结果文件传回手机。
- **操作电脑上的应用**：电脑装上 [open-computer-use](https://github.com/iFurySt/open-computer-use) 这类桌面操控工具后，一句话就能让它在电脑上读窗口、点按钮、输入文字。

**连接电脑上的 Harness**：在电脑上配好模型，运行 `dsh web --no-open`，在 App 的「远程主机」里填电脑的局域网或公网地址和启动链接里的 token（真机上 `127.0.0.1` 指向手机自己）。

## 安全

- **命令关在虚拟机里**：bash 在 Linux 虚拟机里执行，只能碰到挂进去的工作区；虚拟机里的 root 也被收掉了大部分权限，改不了系统盘。
- **手机操控是单独的工具**：不在 Linux 沙箱里，默认关闭，关闭时模型根本看不到它。
- **关键操作要你点头**：手机上的发送、删除、付款，电脑上的任务和操作，都先问你。
- **密钥不出手机**：API Key 存在系统钥匙串里，只用于对应服务的认证。

## 其他功能

- **AI 打电话**：「帮我打给餐厅订周五晚上两个人的位子」，Pallas 用你的 Twilio 云号码打过去，由语音 AI 替你沟通，有实时字幕，随时可以旁听、接管或挂断。拨号前先跟你确认打给谁，对方需要你做决定时会停下来问你。
- **多端互联**：iPhone、iPad 和电脑互相配对，文件和任务来回传。
- **记忆**：记住关于你的事和它自己的笔记，可以查看、编辑，每天自动整理一遍，也能恢复上一版。
- **搜索以前的对话**：模型能全文搜索过去的对话，回答「上次我们说过的那个……」。
- **后台继续回复**：回复中切走，系统横幅显示进度，回复完发通知。
- **聊天**：流式输出、可展开的思考过程、上下文用量、`/compact`、`/model`、子代理对话、内置浏览器。
- **会话管理**：搜索、置顶、文件夹、归档、按状态筛选；支持 Apple 智能的设备用手机自带模型生成对话标题。
- **分享与回放**：导出文字、图片、Markdown、离线 HTML，或生成加密分享链接；回放可拖动、倍速，「接着聊」带进新会话。
- **个性化**：主题配色、桌面图标、聊天壁纸、启动画面、对话字号；适配 iPad 和折叠屏分栏。

<details>
<summary><b>技术细节：iPhone 里的 Linux 是怎么跑起来的</b></summary>

- **不靠 JIT**：虚拟机用 QEMU 的解释执行后端，跑在 App 自己的进程里，所以能通过 TestFlight 分发。
- **快照恢复**：第一次启动后把机器存成快照，之后约 1.6 秒就能执行命令。

</details>

## Pallas Core：自己编译

本仓库包含 **Pallas Core** 的源代码，即 Pallas Agent 开源的部分，采用 Apache License 2.0。Core 本身是一个完整的 App：流式对话和思考过程、手机上的引擎（不含 Linux 虚拟机，所以没有 bash）、通过 `dsh web` 和 SSH 连接远程主机、自己的 API Key 和任意 OpenAI 兼容接口、ChatGPT 和 DeepSeek 登录、插件与技能、记忆、定时任务、日历/提醒事项/通讯录/邮件连接器、把任务交给已配对的电脑、分享与回放、小组件和快捷指令。

TestFlight 版在 Core 之外还有：Linux 虚拟机（bash、Python、npm）、手机操控、AI 打电话、操作复盘、多端互联、内嵌 Tailscale 和 Claude 订阅登录。

| | Pallas Core（本仓库源码） | Pallas Agent（TestFlight） |
| --- | --- | --- |
| 对话、模型、插件、技能、记忆 | ✓ | ✓ |
| 手机上的引擎 | ✓ | ✓ |
| 远程主机、把任务交给电脑 | ✓ | ✓ |
| Linux 虚拟机（bash、Python、npm） | | ✓ |
| 手机操控、AI 打电话、操作复盘 | | ✓ |
| 多端互联、内嵌 Tailscale | | ✓ |

**需要：** 装有 Xcode 27 的 Mac、[XcodeGen](https://github.com/yonaskolb/XcodeGen)；编译手机上的引擎还需要 Node.js、npm 和 Rust（`rustup target add aarch64-apple-ios`）。

```sh
xcodegen generate
# 手机上的引擎（可选：没有它，App 只能连接远程主机）
python3 Embedded/build.py
open PallasCore.xcodeproj
```

在真机上运行前，把 `project.yml` 里的 `PALLAS_CORE_BUNDLE_ID` 和 `DEVELOPMENT_TEAM` 改成你自己的。iOS 模拟器里没有手机上的引擎。

这里的源码在每次发版时从 App 的同一份代码导出，欢迎在这里提 Issue 和 Pull Request。

## 反馈

欢迎在 [Issues](../../issues) 里提问题和建议。

## 版权与许可

Copyright © 2026 deemo0666。

本仓库的源代码采用 [Apache License 2.0](LICENSE)。「Pallas」「Pallas Agent」「Pallas Core」名称、App 图标和 logo、兔狲插画以及 `assets/` 里的视频和图片不在此许可范围内，详见 [NOTICE](NOTICE)，只能用来指称或链接本项目。你分发的版本需要换成自己的名称和图标。

第三方组件各自沿用其许可证：见 `App/ThirdPartyLicenses.txt` 和 App 内「设置 › 关于」。TestFlight 版里 QEMU 和 Linux 客体系统的源代码发布在 [Pallas VM](https://github.com/deemo0666/pallas-vm)。

Pallas Agent 是独立项目，与 DeepSeek 无隶属关系。
