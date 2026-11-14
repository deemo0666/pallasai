<p align="center">
  <img src="assets/pallas-front.webp" width="900" alt="The Pallas cat facing forward against snowy mountains">
</p>

<h1 align="center">Pallas Agent</h1>

<p align="center">
  <b>A whole AI agent, inside your iPhone.</b><br>
  <a href="https://testflight.apple.com/join/73Pbt1su">Get it on TestFlight</a> · <a href="README.md">中文</a>
</p>

**A real Linux machine runs inside an iPhone app.** bash, Node.js, Python and npm, with no jailbreak and no JIT, installed straight from TestFlight. It can also operate other apps on your phone, and hand tasks to your computer and bring the results back.

Pallas Agent is a native Swift/SwiftUI app built on [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness). Model inference requires an internet connection and uses a DeepSeek account or any OpenAI-compatible endpoint.

**0.3.4** · 2026-11-14 · Simplified Chinese / English

<p align="center">
  <a href="assets/pallas-demo.mp4"><img src="assets/pallas-demo-preview.gif" width="270" alt="Pallas Agent demo: one message creates a calendar event, cleans a signup list and builds a brief on a Mac"></a><br>
  <a href="assets/pallas-demo.mp4">▶ Watch the full video (42 s, with sound)</a>
</p>

## One message, three jobs

In the video, a single message is sent and Pallas Agent finishes three jobs on its own:

1. **Reads a poster, creates the event**: it reads the date and place from an event poster, creates the event in the system Calendar with a one-hour alert, then goes back to check it.
2. **Runs Python on the phone**: it cleans a 29-row signup list, removes duplicates, flags a missing email, and produces a clean CSV and a signup report.
3. **Continues on the Mac**: it finds the latest installer package on the computer, builds an event brief web page, and sends it back to the phone.

All over 5G, with no cable attached. About 6.5 minutes and 41 steps, and all three files end up on the phone.

## Just say it

> "Create a note in Notes titled Friday list, with 'pick up the parcel at 3 pm' as the body."

The phone opens Notes, taps and types, then checks the screen again to confirm.

> "Use ffmpeg on my Mac to convert this video to MP4."

The video goes from the phone to the computer, gets converted there, and comes back.

## Installation and beta access

| Option | Includes | Requires |
| --- | --- | --- |
| [TestFlight public beta](https://testflight.apple.com/join/73Pbt1su) | Chat, on-device Linux sandbox, plugins and skills, computer connection | An iPhone or iPad on iOS 17+ |
| Sideload package (in testing) | All of the above + the phone-control runner | A Mac, a free Apple Account, Developer Mode |

## What you can do

### Run Linux on your phone

Switch to **This iPhone** and the engine runs on the iPhone itself. The first time the model calls bash, the app boots an arm64 Linux virtual machine inside its own process and mounts the workspace into it. After that, it resumes from a saved machine state and is ready to run commands in **about 1.6 seconds**.

<img src="assets/local-terminal.webp" width="360" alt="The Pallas cat typing at a phone terminal">

- **A real shell**: bash, Node.js, npm, Python 3.12, curl, git and ripgrep out of the box. Run scripts and read or write Excel, Word and PowerPoint files.
- **Files stay on the phone**: the workspace, attachments and generated files live inside the app. Folders you authorize, including all of iCloud Drive, can be read, written and searched by the model.
- **Plugins and skills that travel with your computer**: install DSH plugins from npm or import a plugin folder from desktop DSH; plugins installed on the phone can be packed and shared back to a computer. Install skills from a GitHub link or a ZIP, tgz or `.skill` package, ready to use immediately.
- **Local network devices**: the model can find and reach printers, NAS boxes, smart-home hubs, web admin pages and SSH servers on the same network, and can publish services started in Linux to the LAN.
- **Any model you like**: sign in with a DeepSeek account or add any OpenAI-compatible endpoint, then switch from the composer at any time.

### Control apps on your phone

The phone looks at its own screen, taps, swipes and types, **with no computer nearby**: unplugged, Wi-Fi off, cellular only (verified on an iPhone 17 Pro running iOS 27).

<img src="assets/phone-control.webp" width="360" alt="The Pallas cat tapping a note on a phone">

- **It sees the screen**: models that accept images get real screenshots; text-only models get on-device OCR text with positions.
- **Checks before acting**: a fresh screenshot is compared before every touch; if the screen changed, the model has to look again.
- **Multi-step navigation**: the model can submit a whole plan at once, and the runner executes and verifies each step.
- **Key steps ask first**: opening an app, sending, deleting and paying wait for your consent; while another app is in front, you answer with Allow / Don't Allow on a notification. Or switch to fully automatic.
- **Take over any time**: switching back to Pallas Agent or locking the phone revokes control for the round.

Phone control is off by default and needs the companion runner plus Developer Mode. No jailbreak is required.

### Run tasks on your computer

The phone can switch to a computer running DeepSeek Harness at any time, or hand a single task to it straight from a phone chat.

<img src="assets/computer-link.webp" width="360" alt="The Pallas cat transferring a file between laptop and phone">

- **Automatic discovery**: computers with the pairing plugin announce themselves on the LAN and show up under **Remote Hosts**; tap one to pair by QR code. A paired computer is found again even after its IP address changes.
- **QR code or SSH**: the pairing code carries all of the computer's addresses (LAN, Tailscale and so on) and the phone picks one that works. SSH is supported too, including a built-in terminal.
- **Hand work to the computer from a phone chat**: the model sends the task and files to the computer and runs it once you allow it; a live panel shows each step and the computer's screen, and the output comes back to the phone.
- **Operate desktop apps**: once the computer has a desktop control tool such as [open-computer-use](https://github.com/iFurySt/open-computer-use), one sentence from the phone is enough for it to read windows, click buttons and type.

**Connect to a Harness on your computer**: configure a model on the computer and run `dsh web --no-open`. In the app, under **Remote Hosts**, enter the computer's LAN or public address and the token from the launch link (on a real device, `127.0.0.1` points to the phone itself).

## Security

- **Commands stay in the VM**: bash runs inside the Linux virtual machine and can only reach the mounted workspace; root inside the VM has most of its capabilities removed and cannot modify the system disk.
- **Phone control is a separate tool**: it lives outside the Linux sandbox, is off by default, and while off the model cannot see it at all.
- **Key actions need your OK**: sending, deleting and paying on the phone, and tasks and actions on the computer, all ask first.
- **Keys stay on the phone**: API keys are stored in the system Keychain and used only to authenticate with their own service.

## More features

- **Memory**: remembers things about you plus its own notes; view and edit them, let it tidy them up daily, and restore the previous version if needed.
- **Search past conversations**: the model can full-text search your history to answer "that thing we talked about last time…".
- **Keeps replying in the background**: leave mid-reply and a system banner shows progress; you get a notification when it's done.
- **Chat**: streaming output, expandable reasoning, context usage, `/compact`, `/model`, sub-agent transcripts and a built-in browser.
- **Sessions**: search, pin, folders, archive and status filters; on Apple Intelligence devices, conversation titles come from the on-device Apple model.
- **Sharing and replay**: export as text, image, Markdown or offline HTML, or create an encrypted share link; replays can be scrubbed and sped up, and "Continue chat" carries a conversation into a new session.
- **Personalization**: color themes, home screen icons, chat wallpapers, launch screens and text size; split layouts on iPad and foldables.

<details>
<summary><b>Under the hood: how Linux runs inside an iPhone app</b></summary>

- **No JIT**: iOS does not let ordinary apps generate executable code, so the VM uses QEMU's interpreting backend (TCG + TCTI) to execute arm64 instructions one by one. That is also why it can ship through TestFlight.
- **Inside the app process**: the VM runs in Pallas Agent's own process with 2 vCPUs; the workspace is mounted over 9p, and the system disk is kept apart from the workspace so app updates keep your data.
- **From 28 seconds to 1.6**: a trimmed initramfs, the engine service bundled into a single file, precompiled Python bytecode and a primed Node compile cache brought cold start from about 28 s to about 11 s; the booted machine is then saved as a snapshot, and every later start resumes from it in about 1.6 s.
- **Sandbox**: commands run under bubblewrap with most root capabilities dropped, the system disk is mounted read-only, and the engine's launch key never appears on the command line or in the file system.

</details>

## Feedback

Questions and suggestions are welcome in [Issues](../../issues).

## Notes

This repository hosts release information and the beta entry point; it does not contain source code. Pallas Agent is an independent project and is not affiliated with DeepSeek. Third-party components bundled in the app, including Harness, NodeMobile, QEMU, the Linux kernel, Citadel and SwiftTerm, retain their respective licenses.
