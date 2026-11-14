<p align="center">
  <img src="assets/logo.png" width="128" alt="Pallas Agent">
</p>

<h1 align="center">Pallas Agent</h1>

<p align="center">
  <b>A whole AI agent, inside your iPhone.</b><br>
  <a href="README.md">中文</a>
</p>

Pallas Agent is a native Swift / SwiftUI client for iOS 17+ with an adapted [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) engine built in. Your phone can run bash, install npm packages, work on spreadsheets and even operate other apps on the phone, with no jailbreak. When you need more power, connect to a computer: the task runs there and the results come back to your phone.

> Model inference uses online services (a DeepSeek account or any OpenAI-compatible endpoint). No large model weights run on the phone.

Current version: **0.3.4** (2026-11-14) · Interface in Simplified Chinese and English

## Download

**TestFlight public beta: coming soon.** The link will be posted here.

## Three core capabilities

### 1. A Linux sandbox on the phone

Switch to **This iPhone** and the engine runs on the iPhone itself. The first time the model calls bash, the app boots a Linux virtual machine inside its own process and mounts the workspace into it.

- **A real shell**: bash, Node.js, npm, Python 3.12, curl and git out of the box. Run scripts and read or write Excel, Word and PowerPoint files.
- **Files stay on the phone**: the workspace, attachments and generated files live inside the app. Folders you authorize, including all of iCloud Drive, can be read, written and searched by the model.
- **Plugins and skills**: install DSH plugins from npm; install skills from a GitHub link or a ZIP, tgz or `.skill` package, ready to use immediately.
- **Local network devices**: the model can find and reach printers, NAS boxes, smart-home hubs, web admin pages and SSH servers on the same network, and can publish services started in Linux to the LAN.
- **Any model you like**: sign in with a DeepSeek account or add any OpenAI-compatible endpoint, then switch from the composer at any time. API keys are stored in the system Keychain.

### 2. The phone operates itself

Just say: "Create a note in Notes titled Friday list, with 'pick up the parcel at 3 pm' as the body." The model opens the app, looks at the screen, taps, swipes and types, then checks the screen again to confirm.

- **It sees the screen**: models that accept images get real screenshots; text-only models get on-device OCR text with positions.
- **Checks before acting**: a fresh screenshot is compared before every touch; if the screen changed, the model has to look again.
- **Multi-step navigation**: the model can submit a whole plan at once, and the runner executes and verifies each step.
- **Key steps ask first**: opening an app, sending, deleting and paying wait for your consent, or you can switch to fully automatic.
- **Take over any time**: switching back to Pallas Agent or locking the phone revokes control for the round.

Phone control is off by default and needs the companion runner plus Developer Mode; see **Installation** below.

### 3. Connect to a computer, and control it

The phone can switch to a computer running DeepSeek Harness at any time.

- **Automatic discovery**: computers with the pairing plugin announce themselves on the LAN and show up under **Remote Hosts**; tap one to pair by QR code. A paired computer is found again even after its IP address changes.
- **QR code or SSH**: the pairing code carries all of the computer's addresses (LAN, Tailscale and so on) and the phone picks one that works. SSH is supported too, including a built-in terminal.
- **Hand work to the computer from a phone chat**: say "Use ffmpeg on my Mac to convert this video to mp4". The model sends the task and files to the computer and runs it once you allow it; a live panel shows each step and the computer's screen, and the output comes back to the phone.
- **Operate desktop apps**: once the computer has a desktop control tool such as [open-computer-use](https://github.com/iFurySt/open-computer-use), one sentence from the phone is enough for it to read windows, click buttons and type.

## More features

- **Memory**: remembers things about you plus its own notes; view and edit them, let it tidy them up daily, and restore the previous version if needed.
- **Search past conversations**: the model can full-text search your history to answer "that thing we talked about last time…".
- **Keeps replying in the background**: leave mid-reply and a system banner shows progress; you get a notification when it's done.
- **Chat**: streaming output, expandable reasoning, context usage, `/compact`, `/model`, sub-agent transcripts and a built-in browser.
- **Sessions**: search, pin, folders, archive and status filters; on Apple Intelligence devices, conversation titles come from the on-device Apple model.
- **Sharing and replay**: export as text, image, Markdown or offline HTML, or create an encrypted share link; replays can be scrubbed and sped up, and "Continue chat" carries a conversation into a new session.
- **Personalization**: color themes, home screen icons, chat wallpapers, launch screens and text size; split layouts on iPad and foldables.

## Installation

| Option | Includes | Requires |
| --- | --- | --- |
| TestFlight (coming soon) | Chat, on-device Linux sandbox, plugins and skills, computer connection | An iPhone or iPad on iOS 17+ |
| Sideload package (in testing) | All of the above + the phone-control runner | A Mac, a free Apple Account, Developer Mode |

**Connect to a Harness on your computer**: configure a model on the computer and run `dsh web --no-open`. In the app, under **Remote Hosts**, enter the computer's LAN or public address and the token from the launch link (on a real device, `127.0.0.1` points to the phone itself).

## Feedback

Questions and suggestions are welcome in [Issues](../../issues).

## Notes

This repository hosts release information and the beta entry point; it does not contain source code. Pallas Agent is an independent project and is not affiliated with DeepSeek. Third-party components bundled in the app, including Harness, NodeMobile, QEMU, the Linux kernel, Citadel and SwiftTerm, retain their respective licenses.
