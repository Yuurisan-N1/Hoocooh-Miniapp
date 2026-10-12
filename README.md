<div align="center">

<img width="100%" alt="header" src="https://capsule-render.vercel.app/api?type=waving&height=210&text=Hoocooh%20Mine%20Bot&fontAlign=50&fontAlignY=36&fontSize=56&desc=Mining%20Cycle%20%7C%20Reward%20Ads%20%7C%20Lucky%20Wheel%20%7C%20Tasks&descAlign=50&descAlignY=58"/>

<img alt="typing" src="https://readme-typing-svg.demolab.com?font=Inter&size=18&duration=3000&pause=650&center=true&vCenter=true&width=900&lines=Mining+Cycle+Claim;Reward+Ads+%7C+Spin+Tickets+%7C+Lucky+Wheel;Daily+Check+In+%7C+Account+Tasks;Referral+Milestones+%7C+Invite+Rewards;Multi-Account+%7C+Sequential+Processing;Proxy+Support+%7C+One+Proxy+Per+Account"/>

<p>
  <img alt="elixir" src="https://img.shields.io/badge/Elixir-1.14%2B-4B275F?logo=elixir&logoColor=white"/>
  <img alt="platform" src="https://img.shields.io/badge/Platform-Hoocooh%20Mine-111111"/>
  <img alt="multi-account" src="https://img.shields.io/badge/Multi--Account-Supported-111111"/>
  <img alt="proxy" src="https://img.shields.io/badge/Proxy-Supported-111111"/>
  <img alt="author" src="https://img.shields.io/badge/by-Yuurisandesu-111111"/>
</p>

<p>
  <b>Hoocooh Mine Bot</b> is a full automation bot for the Hoocooh Mine Telegram Miniapp.<br/>
  It runs the complete daily cycle: the eight hour mining claim behind its drag puzzle, the daily reward ads, the spin ticket ads with the lucky wheel they unlock, the daily check in, every account task the server publishes and the referral milestones, all running automatically across multiple accounts with proxy support and a live countdown between cycles.<br/>
  Built and distributed by <b>Yuurisandesu</b>.
</p>

</div>

---

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Running the Bot](#running-the-bot)
- [Features](#features)
- [File Structure](#file-structure)
- [Disclaimer](#disclaimer)

---

## Requirements

- Elixir `1.14+` with Erlang/OTP `25+`
- Git
- An account on the Hoocooh Mine miniapp: https://t.me/Hoocoohmine_bot

---

## Installation

### Install Elixir

Elixir runs on the Erlang virtual machine, so **Erlang/OTP is required** Elixir cannot run without
it. Every package manager below installs Erlang/OTP for you as a dependency. The only path that needs
a separate Erlang step is the Windows manual installer (see below).

**Windows:**

*Option A package manager (recommended, installs Erlang automatically):*

```cmd
winget install Elixir.Elixir
```

*Option B manual installer (two installers, in this order):*

1. Download and run the **Erlang/OTP installer** from https://www.erlang.org/downloads
2. Run `erl -s halt` to check which OTP version you got
3. Download the **Elixir installer built for that exact OTP** from https://elixir-lang.org/install.html (`elixir-otp-<N>.exe`) and run it

Then open Command Prompt and verify:

```cmd
elixir --version
```

The output prints both versions, for example `Elixir 1.14.0 (compiled with Erlang/OTP 25)`.

**Linux (Ubuntu / Debian):**

```bash
sudo apt-get update
sudo apt-get install -y elixir
elixir --version
```

**macOS:**

```bash
brew install elixir
elixir --version
```

> If you do not have Homebrew, install it first from https://brew.sh

**Termux (Android):**

```bash
pkg update && pkg upgrade -y
pkg install elixir -y
elixir --version
```

> If the `elixir` package is not available in your Termux repository, install an Ubuntu environment first with `pkg install proot-distro`, then `proot-distro install ubuntu`, then `proot-distro login ubuntu` and run the Linux command above inside it.

---

### Clone and Install

**Clone the repository:**

```bash
git clone https://github.com/Yuurisan-N1/Hoocooh-Miniapp.git
cd Hoocooh-Miniapp
```

**Install dependencies:**

This bot uses only the Elixir standard library, so there is nothing to install. Erlang/OTP was already installed by the step above.

---

## Configuration

### 1. Accounts (data.txt)

Fill `data.txt` with Telegram WebApp `initData` for each account, one per line:

```
user=%7B%22id%22...&hash=abc123
user=%7B%22id%22...&hash=def456
```

> `initData` can be obtained from the browser DevTools when opening the Hoocooh Mine Miniapp on Telegram Web. The account is identified by the `initData` itself, so no separate id column is needed.
>
> The Hoocooh Mine server accepts an `initData` for a **short window only**, so copy it and start the bot right away. On the first run the bot generates the client device id this account will keep and stores it in `device.json`, keyed by the account user id, and reuses it on every later cycle and every later start. The device id is random per account and is never derived from the Telegram id, so each account keeps its own device identity even when the lines are reordered, swapped or removed.
>
> `device.json` is written by the bot itself, so it is not part of the download and it must never be edited by hand.

### 2. Proxy (proxy.txt)

Fill `proxy.txt` with proxies, one per line (optional, leave empty to run without proxy):

```
host:port
host:port:user:pass
http://user:pass@host:port
```

Proxies are assigned to accounts by index in round-robin order.

### 3. Bot Settings (config.json)

`sleep_seconds` controls how many seconds the bot waits between cycles. If `config.json` is missing, it is created automatically with a default of `3600` seconds.

```json
{
  "settings": {
    "sleep_seconds": 3600
  }
}
```

---

## Running the Bot

**Linux / macOS:**

```bash
elixir --erl "+Bd" bot.exs
```

**Windows:**

```cmd
elixir --erl "+Bc" bot.exs
```

Or just double click `run_pc.bat`, which runs the Windows command above.

---

## Features

### Account State
At the start of every account the bot signs in with the account `initData` and the device id cached for that account, then logs the account name together with the current Hoocooh balance. An account whose `initData` is refused is reported and skipped before any other request is sent.

### Mining Cycle
The mining pool accrues for the interval the server publishes and the server also publishes the exact moment it becomes claimable. While the pool is still accruing the bot prints how much time is left and moves straight on to the next phase it never parks the cycle on a multi-hour countdown, so every account is processed on every pass. When the pool is ready the drag puzzle is solved, the claim is sent with the puzzle token and the amount the server credits is logged.

### Reward Ads
Every reward ad the server still allows for the day is watched one by one. When the server asks for a puzzle before the view the puzzle is solved first, the view duration is reported to the server and the reward it credits is logged together with the position inside the daily quota. When the server parks the next slot on a short cooldown the bot waits it out with a live countdown and carries on; a cooldown longer than 90 seconds is left for the next cycle.

### Spin Tickets
The spin ticket rail is separate from the reward ads: each ticket is earned by watching its own ad, and the ad is claimed with the action token the server issues for that action. A ticket the server credits is logged with the total number of tickets now ready, and a quota that is already used up is reported as such instead of being retried.

### Lucky Wheel
Every ticket the server reports as ready is spent on the lucky wheel and the amount each spin credits is logged together with the number of tickets left. A spin that the server accepts without a reward is reported honestly.

### Daily Check In
The daily check in is claimed with a freshly solved puzzle. A check in the server accepts without a reward, and a puzzle that could not be solved, are both reported as their own line.

### Account Tasks
Every task the server reports as open is processed in order and claimed with the action token the server issues for the task action. A task that is already completed, a task that still needs a manual channel join and a task that still needs verified completion are each reported with the server's own reason, and the account keeps walking the rest of the list.

### Referral Milestones
The referral milestones the server marks as claimable are claimed one by one and each amount is logged. An account with no milestone ready is reported as such.

### Map Progress
The miner level and the number of recruits the account has are read from the account state and logged at the end of the account block.

### Multi Account
All accounts in `data.txt` are processed sequentially within every cycle. Each account block starts with its own proxy line, and blocks are separated by one blank line so the mapping between an account and its egress is auditable in the log.

### Proxy Support
Proxies are loaded from `proxy.txt` and assigned to accounts by position in round-robin order. Proxy credentials are masked in log output. Running without proxies is fully supported.

### Auto Countdown
Every wait inside the cycle displays a live `HH:MM:SS` countdown in place, and after all accounts complete a cycle the bot shows a countdown until the next cycle starts. A mining cycle that is still accruing is reported as a single line instead, so it never stalls the rest of the cycle.

---

## File Structure

```text
Hoocooh-Miniapp/
├── bot.exs         # Main bot, full daily cycle automation
├── config.json     # Sleep duration between cycles
├── data.txt        # Account initData, one per line
├── proxy.txt       # Proxy list, one per line (optional)
├── device.json     # Per account device id, written and reused by the bot
├── run_pc.bat      # Launcher for Windows
├── LICENSE         # License file
└── utils/
    ├── banner.ex   # Banner display on startup
    └── json.ex     # JSON encoder and decoder
```

---

## Disclaimer

This tool is built for educational and technical exploration purposes. Use it wisely and at your own responsibility.

---

<div align="center">
<img width="100%" alt="footer" src="https://capsule-render.vercel.app/api?type=waving&height=120&section=footer"/>
</div>
