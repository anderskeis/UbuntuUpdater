# UbuntuUpdater

`upgrade-host.sh` — universal updater for Ubuntu hosts. It detects which native
updaters are installed and runs only those, always via each tool's own update
command. Requires Linux; run as your normal user (never root, no whole-script
sudo — `sudo` is used per command where needed).

| Section | Native update command | Runs when |
| --- | --- | --- |
| apt | `apt-get update` + `apt-get --no-remove upgrade` | always on Ubuntu |
| snap | `sudo snap refresh` | `snap` installed |
| flatpak | `flatpak update -y` (user install, plus system install via sudo) | `flatpak` installed |
| fwupd | `fwupdmgr refresh` + `fwupdmgr update --no-reboot-check` | `fwupdmgr` installed |
| pipx | `pipx upgrade-all` | `pipx` installed |
| brew | `brew update` + `brew upgrade` | `brew` installed |
| npm | `npm update -g` over eligible global packages | `npm` + `node` installed |

## Install

Download the script and the npm helper from GitHub into a directory on your
`PATH` (e.g. `~/.local/bin`). Both files must sit in the same directory — the
script loads `filter-global-npm.js` from its own location:

```bash
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/anderskeis/UbuntuUpdater/main/upgrade-host.sh -o ~/.local/bin/upgrade-host.sh
curl -fsSL https://raw.githubusercontent.com/anderskeis/UbuntuUpdater/main/filter-global-npm.js -o ~/.local/bin/filter-global-npm.js
chmod +x ~/.local/bin/upgrade-host.sh
```

Then run it from anywhere:

```bash
upgrade-host.sh            # preview (dry-run) — default, never mutates
upgrade-host.sh --apply    # actually update; needs a terminal, asks [y/N]
```

Alternatively, clone the repo and run the script from the checkout:

```bash
git clone https://github.com/anderskeis/UbuntuUpdater.git
cd UbuntuUpdater
./upgrade-host.sh --help
```

Any download method works (curl, wget, browser) as long as `upgrade-host.sh` and
`filter-global-npm.js` end up side by side. Requires Linux and bash; the other
required commands (`ps`, `awk`, `flock`, ...) are checked at startup.

## Usage

```bash
./upgrade-host.sh                              # preview (dry-run) — default, never mutates
./upgrade-host.sh --apply                      # actually update; needs a terminal, asks [y/N]
./upgrade-host.sh --skip-snap --skip-npm       # skip individual sections
./upgrade-host.sh --help                       # all options
```

## Behavior

- Preview uses cached metadata where the tool supports it: `apt-get -s`,
  `snap refresh --list`, `fwupdmgr get-updates`, `brew outdated`,
  `npm update -g --dry-run`. `--apply` refreshes metadata first.
- The npm section never touches `npm`, `node`, `corepack`, or OpenClaw
  packages (see `filter-global-npm.js`, which must sit next to the script).
- A failing section does not stop the others; the exit code is 0 only if all
  active sections succeeded.
- Ctrl-C / SIGTERM / SIGHUP is forwarded to the active updater's whole process
  tree; the run stops once that tree has exited and no later section is
  started. The maintenance lock is held until then. Native prompts (apt's
  `[Y/n]`, sudo's password via `/dev/tty`) keep working — the caller's stdin
  and controlling terminal are preserved.
- `/var/run/reboot-required` is reported at the end but a reboot is never
  performed. Note fwupd can stage firmware that needs a reboot without that
  marker existing.
- State, lock, and per-run logs live in `~/.ubuntu-updater`
  (override with the `STATE_DIR` environment variable).
