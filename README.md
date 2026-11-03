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
  group; the run stops once that tree has exited and no later section is
  started. The maintenance lock is held until then. Native prompts (apt's
  `[Y/n]`, sudo's password) keep working — the caller's stdin is preserved.
- `/var/run/reboot-required` is reported at the end but a reboot is never
  performed. Note fwupd can stage firmware that needs a reboot without that
  marker existing.
- State, lock, and per-run logs live in `~/.ubuntu-updater`
  (override with the `STATE_DIR` environment variable).
