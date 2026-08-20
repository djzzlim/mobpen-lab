# mobpen-lab

> One-command mobile security & reverse-engineering lab for Kali Linux / Debian.

`mobpen-lab` turns a stock Kali box into a full mobile pentesting workstation:
iOS jailbreak & instrumentation, Android reverse engineering, Flutter app
testing, web-proxy pentesting, plus a Dockerized **MobSF** instance running as
a systemd service — all organized under a single documented folder layout.

## Features

- **iOS** — checkra1n, palera1n, Frida, Grapefruit (web UI over Frida),
  frida-ios-dump, bfinject, SSL-Kill-Switch-2, needle, class-dump, Radare2
- **Android** — Android Studio (latest stable), jadx / jadx-gui, dex-tools,
  objection, pidcat, scrcpy, Frida Gadget, APKLeaks, Androguard, QARK, Drozer
- **Flutter** — reFlutter, kill_flutter (SSL-pinning bypass that works on any
  Flutter version)
- **Web / Network** — Burp Suite Community, Runtime Mobile Security (RMS),
  OWASP ZAP
- **Utilities** — Ghidra, Termius, DB Browser for SQLite, Apktool
- **Docker + MobSF** — Docker installed and MobSF run as an autostart
  `mobsf.service` on `http://127.0.0.1:8000`
- **Organized & documented** — every tool lands in a categorized folder under
  `/opt/mobpen-lab` with generated READMEs and a command reference
- **Idempotent** — safe to re-run; skips what's already installed
- **Auto-updates** — GitHub-hosted tools are fetched from their latest release
  (palera1n, jadx, dex2jar, Frida Gadget, Android Studio)

## Requirements

- **OS:** Kali Linux or any Debian-based distro (Debian/Ubuntu should work)
- **Arch:** x86_64 or arm64 (Android Studio is x86_64 only)
- **Peripherals:** a jailbroken/rooted device for device-side testing
- **Disk:** ~5-10 GB free (Android Studio, MobSF image, Ghidra are large)
- **GUI:** desktop environment for the GUI apps (Burp, jadx-gui, Studio, ...)

## Quick start

```bash
git clone https://github.com/djzzlim/mobpen-lab.git
cd mobpen-lab
sudo ./install.sh            # install everything
```

Install from the repo without cloning:

```bash
curl -fsSL https://raw.githubusercontent.com/djzzlim/mobpen-lab/main/install.sh | sudo bash
```

### Options

| Flag | What it does |
|------|--------------|
| `--all` | Install everything (default) |
| `--ios` | iOS jailbreak & instrumentation tools only |
| `--android` | Android RE & analysis tools only |
| `--web` | Web / network pentesting tools only |
| `--utils` | General utilities only |
| `--docker-only` | Only install Docker + MobSF service |
| `--no-docker` | Skip Docker + MobSF setup |
| `--no-venv` | Skip the shared Python venv (installs pip tools system-wide) |
| `--docs-only` | Only regenerate the lab documentation |
| `-h, --help` | Show help |

Examples:

```bash
sudo ./install.sh --ios --no-docker          # iOS tools, no MobSF
sudo ./install.sh --docker-only              # just Docker + MobSF
```

## Managing the lab with `mobpen`

The installer also installs a `mobpen` CLI (`/usr/local/bin/mobpen`) that points
at your repo checkout. Use it for day-to-day management:

```bash
mobpen update     # git pull the repo, re-run the installer (updates tools,
                  # latest releases, MobSF image), refreshes docs
mobpen status     # repo info, installed tools, docker/mobsf service status
mobpen docs       # regenerate the lab documentation only
mobpen uninstall  # remove everything the installer placed on the system
mobpen version    # show version
```

> `mobpen` auto-locates the repo from its own symlink, so you can keep the
> checkout anywhere on disk. If you cloned the repo after installing, just run
> `sudo ./install.sh` once from the new checkout to re-point it.

## What lands where

```
/opt/mobpen-lab                  # lab root (everything the installer creates)
├── README.md                    # lab index (generated)
├── ios/                         # frida-ios-dump, bfinject, ssl-kill-switch2, needle, class-dump
├── android/                     # pidcat, frida-gadget
├── web/                         # rms
├── flutter/                     # kill_flutter
├── bin/                         # convenience launchers
└── docs/TOOLS.md                # full command reference (generated)

/opt/mobile-sec-venv             # shared Python venv (frida, objection, androguard, ...)
/opt/android-studio              # Android Studio
/opt/jadx                        # jadx / jadx-gui
/opt/dex-tools                   # dex2jar suite
/opt/burpsuite                   # Burp Suite Community jar

/usr/local/bin                   # symlinks: frida, objection, pidcat, reflutter, kill_flutter, studio, ...
/etc/systemd/system/mobsf.service# MobSF autostart service
```

Each category folder gets its own README with a tool table and typical
workflow. The docs regenerate on every install run.

## Usage cheat-sheet

```bash
# iOS
checkra1n -c                                  # jailbreak (CLI)
palera1n --help                               # jailbreak iOS 15-18 (checkm8)
frida-ps -U                                   # list apps on device
igf                                           # Grapefruit web UI -> http://127.0.0.1:31337
frida-ios-dump/dump.py <bundle-id>            # dump decrypted IPA

# Android
studio                                        # Android Studio
jadx app.apk                                  # APK -> Java
d2j-dex2jar.sh app.apk                        # DEX -> JAR
apkleaks -f app.apk                           # find secrets / endpoints
objection -g <app> explore                    # runtime exploration, pinning bypass
scrcpy                                        # mirror device screen

# Flutter
reflutter app.apk                             # patch engine / bypass SSL pinning
kill_flutter app.apk -i <burp-ip> -p 8080     # dynamic bypass (any Flutter version)

# Web
burpsuite                                     # intercepting proxy
zaproxy                                       # web scanner

# MobSF
systemctl status mobsf                        # service status
# -> http://127.0.0.1:8000  (login: mobsf / mobsf)
```

## Uninstall

```bash
sudo ./uninstall.sh          # interactive - asks before system-wide changes
sudo ./uninstall.sh --purge  # remove everything, no prompts
```

## Disclaimer

This project installs security, jailbreak, and reverse-engineering tooling.
Jailbreaking and intercepting app traffic may void warranties and violate
licenses or laws. **Use only on devices you own and have authorization to
test.** The author is not responsible for misuse.

## License

[MIT](LICENSE)