#!/usr/bin/env bash
# upgrade-host.sh — universal updater for Ubuntu hosts.
#
# Detects which native updaters are present on the system and runs only those,
# always through each tool's own native update command:
#   apt, snap, flatpak, fwupd, pipx, Homebrew (if installed), global npm.
#
# Safe by default: with no flags it runs a preview (dry-run) using cached
# metadata where the tool supports it. --apply performs the real updates and
# requires an interactive terminal plus an explicit confirmation.
set -Eeuo pipefail
umask 077

STATE_DIR=${STATE_DIR:-"${HOME}/.ubuntu-updater"}
APPLY=false
DRY_RUN_SET=false
LOG_FILE=
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

SECTIONS=(apt snap flatpak fwupd pipx brew npm)
SKIP_APT=false SKIP_SNAP=false SKIP_FLATPAK=false SKIP_FWUPD=false SKIP_PIPX=false SKIP_BREW=false SKIP_NPM=false
NPM_ARGS=()
CHILD_PID=
STDIN_FD=0

usage() {
  cat <<'USAGE'
Universal Ubuntu host updater — preview (dry-run) is the default.
Usage: upgrade-host.sh [--dry-run] [--apply] [--skip-<section>...]

Sections (auto-detected; skipped when not installed on this host):
  apt      APT packages       -> apt-get update + upgrade (sudo per command)
  snap     snaps               -> sudo snap refresh
  flatpak  flatpak apps        -> flatpak update
  fwupd    device firmware     -> fwupdmgr update
  pipx     pipx apps           -> pipx upgrade-all
  brew     Homebrew packages   -> brew update + brew upgrade (if brew installed)
  npm      global npm packages -> npm update -g (npm/node/corepack/OpenClaw excluded)

Options:
  --dry-run       Show what would change using cached metadata (default)
  --apply         Actually refresh and upgrade; needs a terminal and [y] confirm
  --skip-apt --skip-snap --skip-flatpak --skip-fwupd --skip-pipx --skip-brew --skip-npm
  -h, --help      This help

State and logs live in ${STATE_DIR:-$HOME/.ubuntu-updater} (override with the
STATE_DIR environment variable). Run as the normal owning user, never as root
or via whole-script sudo. Preview never mutates the system; native output,
prompts, and interrupts remain visible.
USAGE
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  local line=$*
  printf '%s\n' "$line" || return
  if [[ -n $LOG_FILE ]]; then
    printf '%s\n' "$line" >>"$LOG_FILE"
  fi
}

# Cancellation handler: forward the signal to the active command, wait for it
# to stop, then exit — so no later section starts and the lock (fd 9) is only
# released after the active updater has shut down.
on_signal() {
  local sig=$1 code=$2 pid=$CHILD_PID i
  log "received SIG$sig; forwarding to the updater process group and stopping the run" || true
  if [[ -n $pid ]]; then
    # The updater runs under setsid, so signal its whole process group (fall
    # back to the bare PID). Async children ignore SIGINT/SIGQUIT, so escalate
    # if the tree does not stop promptly; reap before exiting so the lock
    # (fd 9) is released only after the updater tree has stopped.
    kill -"$sig" -"$pid" 2>/dev/null || kill -"$sig" "$pid" 2>/dev/null || true
    for ((i = 0; i < 20; i++)); do kill -0 -"$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    for ((i = 0; i < 20; i++)); do kill -0 -"$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    for ((i = 0; i < 20; i++)); do kill -0 -"$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    wait "$pid" 2>/dev/null || true
  fi
  exit "$code"
}

# Run the command as a supervised background job. setsid puts the updater in
# its own process group so cancellation can be signaled to the whole tree;
# <&"$STDIN_FD" re-attaches the caller's saved stdin, which bash would
# otherwise point at /dev/null for background jobs, so native prompts
# (apt's [Y/n], sudo's password) still work.
phase() {
  local name=$1
  shift
  local started rc
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  log "command=$name argv=$* start=$started" || return 74
  setsid "$@" <&"$STDIN_FD" &
  CHILD_PID=$!
  if wait "$CHILD_PID"; then rc=0; else rc=$?; fi
  CHILD_PID=
  if ! log "command=$name exit=$rc"; then
    ((rc != 0)) && return "$rc"
    return 74
  fi
  return "$rc"
}

section_skipped() {
  case $1 in
    apt) [[ $SKIP_APT == true ]] ;;
    snap) [[ $SKIP_SNAP == true ]] ;;
    flatpak) [[ $SKIP_FLATPAK == true ]] ;;
    fwupd) [[ $SKIP_FWUPD == true ]] ;;
    pipx) [[ $SKIP_PIPX == true ]] ;;
    brew) [[ $SKIP_BREW == true ]] ;;
    npm) [[ $SKIP_NPM == true ]] ;;
  esac
}

section_available() {
  case $1 in
    apt) command -v apt-get >/dev/null 2>&1 ;;
    snap) command -v snap >/dev/null 2>&1 ;;
    flatpak) command -v flatpak >/dev/null 2>&1 ;;
    fwupd) command -v fwupdmgr >/dev/null 2>&1 ;;
    pipx) command -v pipx >/dev/null 2>&1 ;;
    brew) command -v brew >/dev/null 2>&1 ;;
    npm) command -v npm >/dev/null 2>&1 && command -v node >/dev/null 2>&1 ;;
  esac
}

flatpak_system() { [[ -d /var/lib/flatpak ]]; }

preview_apt() { phase apt-preview apt-get -s --no-remove upgrade; }
apply_apt() {
  phase apt-refresh sudo apt-get --error-on=any update || return $?
  phase apt-upgrade sudo apt-get --no-remove upgrade || return $?
  phase apt-remaining apt-get -s --no-remove upgrade || return $?
}

preview_snap() {
  if snap refresh --help 2>&1 | grep -q -- '--list'; then
    phase snap-preview snap refresh --list || return $?
  else
    log 'snap refresh --list not supported here; falling back to snap list' || return 74
    phase snap-list snap list || return $?
  fi
}
apply_snap() { phase snap-refresh sudo snap refresh; }

preview_flatpak() {
  if flatpak remote-ls --help 2>&1 | grep -q -- '--updates'; then
    phase flatpak-preview flatpak remote-ls --updates || return $?
  else
    log 'flatpak remote-ls --updates not supported here; listing installed flatpaks' || return 74
    phase flatpak-list flatpak list --columns=application,version || return $?
  fi
}
apply_flatpak() {
  local rc=0
  phase flatpak-update-user flatpak update --user -y || rc=$?
  if flatpak_system; then
    phase flatpak-update-system sudo flatpak update --system -y || rc=$?
  fi
  return "$rc"
}

# fwupdmgr uses exit status 2 for "nothing to do"; treat it as success.
fwupd_run() {
  local name=$1 rc=0
  shift
  phase "$name" "$@" || rc=$?
  if ((rc == 2)); then
    log "command=$name exit=2 (nothing to do); treated as success" || true
    return 0
  fi
  return "$rc"
}
preview_fwupd() { fwupd_run fwupd-preview fwupdmgr get-updates; }
apply_fwupd() {
  fwupd_run fwupd-refresh fwupdmgr refresh || return $?
  fwupd_run fwupd-update fwupdmgr update --no-reboot-check || return $?
}

preview_pipx() {
  if ! phase pipx-preview pipx list --short; then
    phase pipx-list pipx list || return $?
  fi
}
apply_pipx() { phase pipx-upgrade pipx upgrade-all; }

preview_brew() { phase brew-preview env HOMEBREW_NO_AUTO_UPDATE=1 brew outdated; }
apply_brew() {
  phase brew-update brew update || return $?
  phase brew-upgrade brew upgrade || return $?
}

npm_discover() {
  local npm_bin node_bin root inventory_json helper pkgs rc
  npm_bin=$(command -v npm) || return $?
  node_bin=$(command -v node) || return $?
  root=$("$npm_bin" root --global) || return $?
  [[ -n $root && -d $root && ! -L $root ]] || {
    printf 'ERROR: unsafe npm global root: %s\n' "$root" >&2
    return 65
  }
  helper="$SCRIPT_DIR/filter-global-npm.js"
  [[ -f $helper && ! -L $helper ]] || {
    printf 'ERROR: npm filter helper unavailable: %s\n' "$helper" >&2
    return 66
  }
  inventory_json=$("$npm_bin" ls --global --depth=0 --json) || return $?
  rc=0
  pkgs=$(printf '%s' "$inventory_json" | "$node_bin" "$helper" "$root") || rc=$?
  if ((rc != 0)); then
    printf 'ERROR: invalid npm global inventory (status %s)\n' "$rc" >&2
    return "$rc"
  fi
  NPM_ARGS=()
  if [[ -n $pkgs ]]; then mapfile -t NPM_ARGS <<<"$pkgs"; fi
}

preview_npm() {
  npm_discover || return $?
  log "npm discovery complete eligible=${#NPM_ARGS[@]}" || return 74
  if ((${#NPM_ARGS[@]} > 0)); then
    phase npm-preview npm update --global --dry-run -- "${NPM_ARGS[@]}" || return $?
  else
    log 'npm preview skipped: no eligible global packages' || return 74
  fi
}

apply_npm() {
  npm_discover || return $?
  log "npm rediscovery complete eligible=${#NPM_ARGS[@]}" || return 74
  if ((${#NPM_ARGS[@]} > 0)); then
    phase npm-update npm update --global -- "${NPM_ARGS[@]}" || return $?
    phase npm-remaining npm ls --global --depth=0 -- "${NPM_ARGS[@]}" || return $?
  else
    log 'npm skipped: no eligible global packages' || return 74
  fi
}

run_section() {
  local mode=$1 id=$2 rc=0
  local fn="${mode}_${id}"
  "$fn" || rc=$?
  return "$rc"
}

main() {
  local answer state_owner state_mode lock_file id mode rc
  local active=() failed=''
  while (($#)); do
    case $1 in
      --help | -h)
        usage
        exit 0
        ;;
      --dry-run)
        if $APPLY; then fail '--dry-run and --apply cannot be combined'; fi
        DRY_RUN_SET=true
        ;;
      --apply)
        if $DRY_RUN_SET; then fail '--dry-run and --apply cannot be combined'; fi
        APPLY=true
        ;;
      --skip-apt) SKIP_APT=true ;;
      --skip-snap) SKIP_SNAP=true ;;
      --skip-flatpak) SKIP_FLATPAK=true ;;
      --skip-fwupd) SKIP_FWUPD=true ;;
      --skip-pipx) SKIP_PIPX=true ;;
      --skip-brew) SKIP_BREW=true ;;
      --skip-npm) SKIP_NPM=true ;;
      *) fail "unknown option: $1 (see --help)" ;;
    esac
    shift
  done

  [[ $EUID -ne 0 ]] || fail 'run as the owning non-root user; do not invoke the whole script with sudo'
  for cmd in uname date mkdir stat flock setsid; do command -v "$cmd" >/dev/null || fail "required command not found: $cmd"; done
  [[ $(uname -s) == Linux ]] || fail 'Linux is required'

  # Save the caller's stdin; phase() re-attaches this fd for supervised
  # commands because bash points background jobs' stdin at /dev/null.
  if (exec 3<&0) 2>/dev/null; then
    exec 3<&0
    STDIN_FD=3
  fi

  mkdir -p -- "$STATE_DIR" || fail "cannot create state directory: $STATE_DIR"
  [[ -d $STATE_DIR && ! -L $STATE_DIR ]] || fail "state directory is not a directory: $STATE_DIR"
  state_owner=$(stat -c '%u' -- "$STATE_DIR")
  state_mode=$(stat -c '%a' -- "$STATE_DIR")
  [[ $state_owner -eq $EUID && $((8#$state_mode & 077)) -eq 0 ]] || fail "state directory must be owner-only and owned by uid $EUID: $STATE_DIR"

  lock_file="$STATE_DIR/host-updater.lock"
  [[ ! -L $lock_file ]] || fail "unsafe lock symlink: $lock_file"
  if [[ -e $lock_file ]]; then
    [[ -f $lock_file ]] || fail "lock is not a regular file: $lock_file"
    [[ $(stat -c '%u %h %a' -- "$lock_file") == "$EUID 1 600" ]] || fail "lock must be a private single-link file owned by uid $EUID: $lock_file"
  fi
  exec 9>>"$lock_file" || fail "cannot open updater lock: $lock_file"
  flock -n 9 || fail "another updater run owns the lock: $lock_file"

  LOG_FILE="$STATE_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
  [[ ! -e $LOG_FILE && ! -L $LOG_FILE ]] || fail "log path already exists or is a symlink: $LOG_FILE"
  (
    set -o noclobber
    : >"$LOG_FILE"
  ) || fail "cannot create private log: $LOG_FILE"

  mode=preview
  if $APPLY; then mode=apply; fi
  log "mode=$mode log=$LOG_FILE" || fail 'cannot write initial log'

  # Cancellation must stop the whole run, not be recorded as one section's
  # failure while later updaters keep mutating packages. Signals are
  # forwarded to the active command and awaited before the lock is released.
  trap 'on_signal INT 130' INT
  trap 'on_signal TERM 143' TERM
  trap 'on_signal HUP 129' HUP

  for id in "${SECTIONS[@]}"; do
    if section_skipped "$id"; then
      log "section $id skipped (--skip-$id)" || fail 'cannot write skip log'
    elif section_available "$id"; then
      active+=("$id")
    else
      log "section $id unavailable on this host; skipped" || fail 'cannot write skip log'
    fi
  done
  log "active sections: ${active[*]:-none}" || fail 'cannot write log'

  if ((${#active[@]} == 0)); then
    log 'no sections active; nothing to do' || fail 'cannot write log'
    exit 0
  fi

  if $APPLY; then
    if [[ ! -t 0 || ! -t 1 ]]; then
      fail '--apply requires an interactive terminal'
    fi
    local need_sudo=false
    for id in "${active[@]}"; do
      case $id in
        apt) need_sudo=true ;;
        snap) need_sudo=true ;;
        flatpak) if flatpak_system; then need_sudo=true; fi ;;
      esac
    done
    if $need_sudo; then
      command -v sudo >/dev/null || fail 'required command not found: sudo (needed by active sections)'
    fi
    printf "WARNING: --apply refreshes and upgrades via each selected tool's native updater; output and prompts stay visible. Proceed? [y/N] " >&2
    read -r answer || fail 'apply confirmation could not be read from the terminal'
    [[ $answer == y || $answer == Y || $answer == yes || $answer == YES ]] || fail 'apply cancelled'
  fi

  for id in "${active[@]}"; do
    if run_section "$mode" "$id"; then
      log "section $id ok" || true
    else
      rc=$?
      log "section $id FAILED (exit $rc)" || true
      failed="$failed $id"
    fi
  done

  if [[ -e /var/run/reboot-required ]]; then
    log 'Reboot required: yes (/var/run/reboot-required present; not performed)' || true
  else
    log 'Reboot required: not indicated by /var/run/reboot-required (fwupd may still have staged firmware that needs a reboot; never performed)' || true
  fi

  if [[ -n $failed ]]; then
    log "Completed with failures:$failed" || true
    exit 1
  fi
  log 'All selected sections completed' || true
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
