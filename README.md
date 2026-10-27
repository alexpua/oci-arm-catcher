# oci-arm-catcher

**Grab Oracle Cloud's free ARM capacity the moment it appears.** A single,
dependency-free binary that retries `LaunchInstance` for the Always Free
`VM.Standard.A1.Flex` shape until Oracle finally has capacity — then launches
your instance and pings you.

Part of [DeepLab](https://deeplab.tools/products/) — small, sharp tools that run
locally.

![oci-arm-catcher in action](assets/demo.gif)

If you've ever tried to create a free Ampere A1 instance and hit this,
repeatedly, for days:

```
ServiceError:
  code: InternalError
  message: Out of host capacity.
```

…this is for you. Start it, walk away, get a notification when your instance is
up.

> Works on **macOS, Linux, and Windows**. One Rust binary that talks to the OCI
> API directly; the original bash / PowerShell scripts are still included.

---

## Why this exists

Oracle's [Always Free tier](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
gives every account **2 ARM OCPUs and 12 GB of RAM** on the Ampere A1 platform —
genuinely free, forever, no trial clock. Still one of the best free compute deals
anywhere: enough for a self-hosted app stack, a game server, or a personal VPN.

> **Note (June 2026):** Oracle quietly halved the Always Free Ampere allowance
> from 4 OCPU / 24 GB to **2 OCPU / 12 GB** (1,500 OCPU-hours + 9,000 GB-hours per
> month) on 15 June 2026, with no announcement. Pay-as-you-go accounts have
> reportedly kept the old 4 OCPU / 24 GB at no charge, but Oracle hasn't confirmed
> that publicly — check your own billing before assuming. Set `OCPUS` /
> `MEMORY_GB` in your `.env` to whatever your account actually allows.

The catch: those ARM hosts are in heavy demand, so launching an instance very
often fails with **"Out of host capacity"**. US regions can be dry for hours or
days; even busy EU/APAC regions dip in and out. Capacity frees up
unpredictably, in small windows, and whoever's polling at that second wins.

`oci-arm-catcher` is that poller. It hammers the launch API on a polite interval,
recognises the "no capacity, try again" family of errors, and grabs the slot the
instant one opens — including rotating across multiple Availability Domains if
your region has them.

It's a single binary with no runtime dependencies — it signs OCI API requests
itself with the key in your `~/.oci/config`, so there's no OCI CLI or Python to
install. It's been used in production to catch a 4 OCPU / 24 GB A1 instance on a real account (under the
pre-June-2026 limits).

## Who it's for

Anyone trying to provision an Always Free (or paid) `A1.Flex` ARM instance who
keeps hitting capacity errors — homelabbers, self-hosters, indie devs, students,
and devops folks who want a free always-on ARM box.

---

## How it works

```
loop:
  LaunchInstance  shape=VM.Standard.A1.Flex ...
  ├─ success              → print instance OCID + console link, notify, exit 0
  ├─ 4xx (request is bad) → print it, notify, stop (so you can fix config)
  │   auth failure / bad OCID / LimitExceeded
  └─ everything else      → wait RETRY_INTERVAL, rotate AD, retry
      "Out of host capacity" / 429 TooManyRequests / 5xx / timeout / network blip
```

The error handling is the important part: it stops immediately on real problems
(bad OCID, auth failure, quota exceeded) instead of looping forever against a
wall, and keeps retrying on everything else, so an unfamiliar transient error
can't silently end a multi-day hunt.

After a network error the binary resends the *same* request with the same
`opc-retry-token`, so if the launch actually went through and only the answer
was lost, OCI hands back that instance instead of creating a second one.

The classic scripts follow the same rules by matching error text, and append
every failed attempt's raw output to `oci-arm-catcher-errors.log` (override
with `ERROR_LOG`).

---

## Install

One self-contained binary for macOS, Linux and Windows. It talks to the OCI API
directly — **no OCI CLI and no Python needed**.

```bash
# macOS / Linux (Homebrew)
brew install deeplabua/tap/oci-arm-catcher

# macOS / Linux (installer script)
curl --proto '=https' --tlsv1.2 -LsSf https://github.com/deeplabua/oci-arm-catcher/releases/latest/download/oci-arm-catcher-installer.sh | sh

# Windows (PowerShell)
powershell -c "irm https://github.com/deeplabua/oci-arm-catcher/releases/latest/download/oci-arm-catcher-installer.ps1 | iex"

# From source
cargo install oci-arm-catcher
```

Or grab an archive from [Releases](https://github.com/deeplabua/oci-arm-catcher/releases).

## Prerequisites

1. **An Oracle Cloud account** (Always Free is fine) and a region picked.
2. **A VCN with a public subnet** in that region. The OCI console's "Create
   VCN with Internet Connectivity" wizard sets this up in one click.
3. **An API key in `~/.oci/config`.** In the console: profile menu → *My
   profile* → *API keys* → *Add API key* → *Generate API key pair*. Download
   the private key, then paste the "Configuration file preview" it shows into
   `~/.oci/config` and point `key_file` at the downloaded key. (If you already
   ran `oci setup config`, you're done.)

Check it works — this is read-only:

```bash
oci-arm-catcher check
```

---

## Quick start

```bash
oci-arm-catcher discover > .env   # read-only: prints your OCIDs as .env lines
# review .env (pick a subnet if you have several), then:
oci-arm-catcher
```

That's it. It retries until capacity appears, launches the instance, prints its
console link and sends a desktop notification. `oci-arm-catcher --help` lists
every flag; each one can also be set in `.env` or as an environment variable.

<details>
<summary><b>Classic shell scripts</b> (bash / PowerShell + OCI CLI)</summary>

The original scripts still work and read the same `.env`. They need the
[OCI CLI](https://docs.oracle.com/iaas/Content/API/SDKDocs/cliinstall.htm)
(`oci setup config`) and, for bash, Python 3.

```bash
git clone https://github.com/deeplabua/oci-arm-catcher.git
cd oci-arm-catcher
cp .env.example .env       # then edit .env
./scripts/get-config.sh    # read-only OCID discovery
./oci-arm-catcher.sh
```

On Windows: `Copy-Item .env.example .env`, then `.\scripts\get-config.ps1`
and `.\oci-arm-catcher.ps1`.

</details>

---

## Configuration

All settings live in `.env` (see [`.env.example`](.env.example)), or can be
passed as flags. Precedence: flag > environment variable > `.env`.

### Auto-discover your OCIDs

```bash
oci-arm-catcher discover
```

It's **read-only** — it launches nothing, just prints your compartment,
availability domain(s), public subnets and the latest ARM image, formatted as
`.env` lines. Use `--os "Oracle Linux"` for a different image.

### Finding values manually

| Variable | What it is | Command |
|---|---|---|
| `COMPARTMENT_ID` | Where the instance is created (tenancy root works) | `oci iam compartment list --all` |
| `AVAILABILITY_DOMAIN` | The AD to launch in | `oci iam availability-domain list` |
| `SUBNET_ID` | A public subnet in your VCN | `oci network subnet list --compartment-id <id> --all` |
| `IMAGE_ID` | An **aarch64/ARM** OS image | `oci compute image list --compartment-id <id> --operating-system "Canonical Ubuntu" --shape VM.Standard.A1.Flex --all` |
| `SSH_KEY_FILE` | Path to your SSH **public** key (`.pub`) | `ls ~/.ssh/*.pub` |

### All settings

| Variable | Required | Default | Notes |
|---|---|---|---|
| `COMPARTMENT_ID` | yes | — | Compartment / tenancy OCID |
| `DISPLAY_NAME` | yes | — | Instance name in the console |
| `SSH_KEY_FILE` | yes | — | Path to your `.pub` key |
| `AVAILABILITY_DOMAIN` | yes\* | — | Single AD |
| `AVAILABILITY_DOMAINS` | yes\* | — | Comma-separated ADs to **rotate** across; overrides the single one |
| `SUBNET_ID` | yes | — | Public subnet OCID |
| `IMAGE_ID` | yes | — | ARM image OCID |
| `OCPUS` | yes | `2` | Always Free max is 2 total (was 4 before 15 Jun 2026) |
| `MEMORY_GB` | yes | `12` | Always Free max is 12 total (was 24 before 15 Jun 2026) |
| `RETRY_INTERVAL` | no | `300` | Seconds between attempts |
| `BOOT_VOLUME_GB` | no | image default (~47) | Boot volume size; Always Free includes 200 GB block storage in total |
| `ERROR_LOG` | no | `oci-arm-catcher-errors.log` | Where raw error output from each failed attempt is appended |

\* Set **either** `AVAILABILITY_DOMAIN` (one AD) **or** `AVAILABILITY_DOMAINS`
(rotation). If both are set, the rotating list wins.

### Multi-AD rotation

Regions like Ashburn, Phoenix, and Frankfurt have three Availability Domains,
and capacity can appear in any one of them. Set them all and the catcher cycles
through on each retry, multiplying your chances:

```bash
AVAILABILITY_DOMAINS="Abcd:US-ASHBURN-1-AD-1,Abcd:US-ASHBURN-1-AD-2,Abcd:US-ASHBURN-1-AD-3"
```

(Most single-AD regions just use `AVAILABILITY_DOMAIN`.)

---

## Running it in the background

You'll likely want this running for hours. Pick one:

**nohup** — fire and forget, logs to a file:

```bash
nohup ./oci-arm-catcher.sh > catcher.log 2>&1 &
tail -f catcher.log          # watch progress
```

**tmux / screen** — detachable session you can reattach to:

```bash
tmux new -s catcher
./oci-arm-catcher.sh
# detach: Ctrl-b then d   ·   reattach: tmux attach -t catcher
```

**Windows** — run in a PowerShell window, or as a background job:

```powershell
Start-Job -ScriptBlock { & "C:\path\to\oci-arm-catcher.ps1" }
```

The script prints a once-a-minute heartbeat when it detects it's writing to a
log file (non-interactive), and a live countdown when run in a terminal.

---

## Running on Windows

Use the binary (see [Install](#install)) — it runs natively on Windows and
shows a toast notification on success. The classic scripts work too:

1. **Native PowerShell** — use `oci-arm-catcher.ps1` as shown
   above. It shows Windows toast notifications (via
   [BurntToast](https://github.com/Windos/BurntToast) if installed, otherwise a
   tray balloon).
2. **WSL2 or Git Bash** — if you'd rather use the bash version, run it inside
   [WSL2](https://learn.microsoft.com/windows/wsl/install) or Git Bash exactly
   as on Linux. You'll need `python3` available in that environment.

---

## Troubleshooting

**`'oci' is not installed or not on PATH`**
The OCI CLI isn't installed or your shell can't find it. Re-run the install
step, then `oci iam region list` to confirm. On macOS with Homebrew you may need
to restart your terminal.

**It keeps printing `InternalError: Out of host capacity.`**
That's expected — it's working. Capacity genuinely isn't available yet. Leave it
running. Consider adding more Availability Domains, or try a different region's
account if you have one.

**`NotAuthorizedOrNotFound` and it stops immediately**
This is *not* a capacity error, so the catcher stops on purpose. Usually a wrong
or mismatched OCID — double-check that `COMPARTMENT_ID`, `SUBNET_ID`, and
`IMAGE_ID` all belong to the **same region** as your AD.

**`LimitExceeded`**
You've hit your Always Free allowance — **2 OCPU / 12 GB total** since 15 June
2026 (it was 4 OCPU / 24 GB before). Delete or shrink existing A1 instances, or
lower `OCPUS`/`MEMORY_GB`. This is not a capacity error, so the catcher stops
instead of retrying.

**It looks frozen — the spinner just keeps spinning**
Older versions could appear to hang here. The OCI CLI's Python SDK has its own
internal retry/backoff, independent of `--connection-timeout` / `--read-timeout`:
after a `500` it can silently loop on `429 Too Many Requests` for minutes inside a
single attempt, so `RETRY_INTERVAL` no longer reflects the real interval. The
catcher now passes `--no-retry` and does its own retrying, which fixes this
(thanks [@zearp](https://github.com/zearp), [#1](https://github.com/deeplabua/oci-arm-catcher/issues/1)).
If you're on an older copy, `git pull`.

**The image won't boot / wrong architecture**
Make sure `IMAGE_ID` is an **aarch64 / ARM** image. x86 images won't launch on
`A1.Flex`. The `get-config` helper filters to ARM images for you.

**Notifications don't show up**
They're best-effort. On Linux install `libnotify` (`notify-send`); on Windows
`Install-Module BurntToast` for nicer toasts. The script always prints to the
console regardless.

---

## Development & tests

The Rust workspace has two crates: `crates/core` (`oci-arm-catcher-core` — config,
request signing, API client and the retry loop) and `crates/cli` (the
`oci-arm-catcher` binary).

```bash
cargo test
cargo clippy --workspace --all-targets -- -D warnings
cargo fmt --all
cargo run -- check          # read-only call against your own account
```

The bash script is covered by [bats](https://github.com/bats-core/bats-core)
tests that mock the `oci` CLI, and the PowerShell port by
[Pester](https://pester.dev/). Both run in CI (plus
[ShellCheck](https://www.shellcheck.net/)).

Install the dev tools:

```bash
# macOS (Homebrew)
brew install bats-core shellcheck

# Debian / Ubuntu
sudo apt-get install -y bats shellcheck

# Pester (PowerShell, any OS) — usually preinstalled on Windows
pwsh -c "Install-Module Pester -Scope CurrentUser -Force"
```

Run them:

```bash
# bash
bats tests/

# powershell
Invoke-Pester -Path tests/oci-arm-catcher.Tests.ps1

# lint
shellcheck oci-arm-catcher.sh scripts/get-config.sh
```

For testability the bash script can be sourced in "library mode"
(`OCI_ARM_CATCHER_LIB=1 source ./oci-arm-catcher.sh`), which defines its helper
functions without running the main loop.

---

## Disclaimer

This tool only calls the official OCI CLI on your behalf, on a polite retry
interval — it doesn't bypass any limits or do anything Oracle's own console
doesn't. You're responsible for staying within your account's terms and free-tier
limits. Provided as-is under the MIT License.

## Contributing

Issues and PRs welcome — especially: more OS/notification backends, smarter
backoff, and region/AD presets.

## Support

If `oci-arm-catcher` caught you a free server, two things help a lot:

- ⭐ **[Star the repo](https://github.com/deeplabua/oci-arm-catcher)** — it's how other people fighting "Out of host capacity" find it.
- ☕ **[Buy me a coffee](https://send.monobank.ua/jar/4Hq7auheaa)** — if it saved you some time and you feel like it.

Both are completely optional. The tool is free and always will be.

## License

[MIT](LICENSE)
