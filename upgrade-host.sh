#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STATE_DIR=${STATE_DIR:-"${HOME}/.openclaw-host-maintenance"}
APPLY=false
APPLY_SET=false
DRY_RUN_SET=false
SKIP_APT=false
SKIP_BREW=false
SKIP_NPM=false
LOG_FILE=
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
  cat <<'USAGE'
Interactive host package maintenance (safe cached preview is the default)
Usage: upgrade-host.sh [--dry-run] [--apply] [--skip-apt] [--skip-brew] [--skip-npm]
Preview uses cached APT/Brew metadata and a registry-aware native npm dry-run.
Apply refreshes and upgrades selected APT, Homebrew, then eligible global npm
packages. OpenClaw, npm, Node, Corepack, and @openclaw/* are never selected.
Run as the normal owner, never as whole-script sudo. Native output, prompts,
trust decisions, and interrupts remain visible.
USAGE
}
fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}
owner_check() { [[ ${1:?missing uid} -ne 0 ]]; }
log() {
  local line=$*
  printf '%s\n' "$line" || return
  printf '%s\n' "$line" >>"$LOG_FILE" || return
}
phase() {
  local name=$1
  shift
  local started rc
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if ! log "command=$name argv=$* start=$started"; then
    printf 'ERROR: cannot write phase start log; no command started\n' >&2
    return 74
  fi
  if "$@"; then rc=0; else rc=$?; fi
  if ! log "command=$name exit=$rc"; then
    printf 'ERROR: cannot write phase exit log\n' >&2
    ((rc != 0)) && return "$rc"
    return 74
  fi
  return "$rc"
}
require_npm() {
  command -v npm >/dev/null || fail 'required command not found: npm'
  command -v node >/dev/null || fail 'required command not found: node'
}
discover_npm() {
  local npm_bin=$1 node_bin=$2 root inventory_json helper rc
  if root=$("$npm_bin" root --global); then :; else
    rc=$?
    return "$rc"
  fi
  [[ -n $root && -d $root && ! -L $root ]] || {
    printf 'ERROR: unsafe npm global root: %s\n' "$root" >&2
    return 65
  }
  helper="$SCRIPT_DIR/filter-global-npm.js"
  [[ -f $helper && ! -L $helper ]] || {
    printf 'ERROR: npm filter helper unavailable\n' >&2
    return 66
  }
  if inventory_json=$("$npm_bin" ls --global --depth=0 --json); then :; else
    rc=$?
    return "$rc"
  fi
  if npm_packages=$(printf '%s' "$inventory_json" | "$node_bin" "$helper" "$root"); then :; else
    rc=$?
    printf 'ERROR: invalid npm global inventory\n' >&2
    return "$rc"
  fi
  NPM_ARGS=()
  if [[ -n $npm_packages ]]; then mapfile -t NPM_ARGS <<<"$npm_packages"; fi
  NPM_BIN=$npm_bin
}
run_npm() { "$NPM_BIN" "$@"; }

main() {
  while (($#)); do
    case $1 in
    --help | -h)
      usage
      exit 0
      ;;
    --dry-run)
      $APPLY_SET && fail '--dry-run and --apply cannot be combined'
      DRY_RUN_SET=true
      ;;
    --apply)
      $DRY_RUN_SET && fail '--dry-run and --apply cannot be combined'
      APPLY=true
      APPLY_SET=true
      ;;
    --skip-apt) SKIP_APT=true ;; --skip-brew) SKIP_BREW=true ;; --skip-npm) SKIP_NPM=true ;;
    --ack-coordination | --runtime-upgrade | --refresh-index | --unattended | --dist-upgrade | --allow-removals | --autoremove) fail "$1 is retired; use --apply/--dry-run and skip flags only" ;;
    *) fail "unknown option: $1 (see --help)" ;; esac
    shift
  done
  owner_check "$EUID" || fail 'run as the owning non-root user; do not invoke the whole script with sudo'
  if $APPLY && ! ($SKIP_APT && $SKIP_BREW && $SKIP_NPM) && [[ ! -t 0 || ! -t 1 ]]; then fail '--apply requires an interactive terminal (or skip all sections for a no-op)'; fi
  for cmd in uname date mkdir stat flock; do command -v "$cmd" >/dev/null || fail "required command not found: $cmd"; done
  [[ $(uname -s) == Linux ]] || fail 'Linux is required'
  mkdir -p -- "$STATE_DIR"
  [[ -d $STATE_DIR && ! -L $STATE_DIR ]] || fail "state directory is not a directory: $STATE_DIR"
  state_owner=$(stat -c '%u' -- "$STATE_DIR")
  state_mode=$(stat -c '%a' -- "$STATE_DIR")
  [[ $state_owner -eq $EUID && $((8#$state_mode & 077)) -eq 0 ]] || fail "state directory must be owner-only and owned by uid $EUID: $STATE_DIR"
  LOCK_FILE=$STATE_DIR/host-maintenance.lock
  [[ ! -L $LOCK_FILE ]] || fail "unsafe lock symlink: $LOCK_FILE"
  if [[ -e $LOCK_FILE ]]; then
    [[ -f $LOCK_FILE ]] || fail "lock is not a regular file: $LOCK_FILE"
    [[ $(stat -c '%u %h %a' -- "$LOCK_FILE") == "$EUID 1 600" ]] || fail "lock must be a private single-link file owned by uid $EUID: $LOCK_FILE"
  fi
  exec 9>>"$LOCK_FILE" || fail "cannot open maintenance lock: $LOCK_FILE"
  flock -n 9 || fail "another host maintenance run owns the lock: $LOCK_FILE"
  LOG_FILE="$STATE_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
  [[ ! -e $LOG_FILE && ! -L $LOG_FILE ]] || fail "log path already exists or is a symlink: $LOG_FILE"
  (
    set -o noclobber
    : >"$LOG_FILE"
  ) || fail "cannot create private log: $LOG_FILE"
  log "mode=$([[ $APPLY == true ]] && printf apply || printf preview) log=$LOG_FILE" || fail 'cannot write initial log'
  if $SKIP_APT; then log 'APT skipped (--skip-apt)' || fail 'cannot write skip log'; fi
  if $SKIP_BREW; then log 'Homebrew skipped (--skip-brew)' || fail 'cannot write skip log'; fi
  if $SKIP_NPM; then log 'npm skipped (--skip-npm)' || fail 'cannot write skip log'; fi
  if ! $SKIP_APT; then command -v apt-get >/dev/null || fail 'required command not found: apt-get'; fi
  BREW=
  if ! $SKIP_BREW && command -v brew >/dev/null; then BREW=$(command -v brew); elif ! $SKIP_BREW; then
    log 'Homebrew unavailable; Brew section skipped' || fail 'cannot write log'
    SKIP_BREW=true
  fi
  NPM_BIN=
  NPM_NODE=
  NPM_ARGS=()
  NPM_INITIAL_PRESENT=false
  if ! $SKIP_NPM; then
    if command -v npm >/dev/null; then
      require_npm
      NPM_INITIAL_PRESENT=true
      NPM_BIN=$(command -v npm)
      NPM_NODE=$(command -v node)
      if discover_npm "$NPM_BIN" "$NPM_NODE"; then :; else
        rc=$?
        printf 'ERROR: cannot discover globally installed npm packages (status %s)\n' "$rc" >&2
        exit "$rc"
      fi
      log "npm discovery complete eligible=${#NPM_ARGS[@]}" || fail 'cannot write discovery log'
    else
      log 'npm unavailable; global npm section skipped' || fail 'cannot write log'
      SKIP_NPM=true
    fi
  fi
  apt_cmd() { sudo apt-get "$@"; }
  brew_cmd() { "$BREW" "$@"; }
  if ! $APPLY; then
    if ! $SKIP_APT; then phase apt-preview apt-get -s --no-remove upgrade || exit $?; fi
    if [[ -n $BREW ]]; then HOMEBREW_NO_AUTO_UPDATE=1 phase brew-preview brew_cmd outdated || exit $?; fi
    if ! $SKIP_NPM && ((${#NPM_ARGS[@]})); then phase npm-preview run_npm update --global --dry-run -- "${NPM_ARGS[@]}" || exit $?; elif ! $SKIP_NPM; then log 'npm skipped: no eligible global packages' || fail 'cannot write completion log'; fi
    log 'Preview complete: APT/Brew metadata was not refreshed; npm preview may use registry/cache and is not an exact upgrade count.' || fail 'cannot write completion log'
    exit 0
  fi
  if $SKIP_APT && $SKIP_BREW && $SKIP_NPM; then
    log 'Nothing selected; no mutation performed.' || fail 'cannot write completion log'
    exit 0
  fi
  ! $SKIP_APT && { command -v sudo >/dev/null || fail 'required command not found: sudo for apply APT phases'; }
  printf 'WARNING: apply refreshes and upgrades selected package managers; npm may contact its registry. Homebrew may update Node; global npm updates can change package majors. Do not run an OpenClaw native update concurrently. Proceed? [y/N] ' >&2
  read -r answer || fail 'apply confirmation could not be read from the terminal'
  [[ $answer == y || $answer == Y || $answer == yes || $answer == YES ]] || fail 'apply cancelled'
  if ! $SKIP_APT; then
    phase apt-refresh apt_cmd --error-on=any update || exit $?
    phase apt-upgrade apt_cmd --no-remove upgrade || exit $?
    phase apt-remaining apt_cmd -s --no-remove upgrade || exit $?
  fi
  if [[ -n $BREW ]]; then
    phase brew-refresh brew_cmd update || exit $?
    phase brew-upgrade brew_cmd upgrade || exit $?
    HOMEBREW_NO_AUTO_UPDATE=1 phase brew-remaining brew_cmd outdated || exit $?
  fi
  log 'remaining inventories:' || fail 'cannot write inventory heading'
  if ! $SKIP_NPM; then
    if command -v npm >/dev/null && command -v node >/dev/null; then
      NPM_BIN=$(command -v npm)
      NPM_NODE=$(command -v node)
      if discover_npm "$NPM_BIN" "$NPM_NODE"; then :; else
        rc=$?
        printf 'ERROR: cannot rediscover globally installed npm packages after Brew (status %s)\n' "$rc" >&2
        exit "$rc"
      fi
      log "npm rediscovery complete eligible=${#NPM_ARGS[@]}" || fail 'cannot write discovery log'
      if ((${#NPM_ARGS[@]})); then
        phase npm-update run_npm update --global -- "${NPM_ARGS[@]}" || exit $?
        phase npm-remaining run_npm ls --global --depth=0 -- "${NPM_ARGS[@]}" || exit $?
      else log 'npm skipped: no eligible global packages'; fi
    elif $NPM_INITIAL_PRESENT; then
      log 'npm or node disappeared after Brew; global npm maintenance failed closed' || fail 'npm or node disappeared after Brew'
      exit 127
    else log 'npm remained an explicit initial optional skip' || fail 'cannot write log'; fi
  fi
  if [[ -e /var/run/reboot-required ]]; then log 'Reboot required: yes (not performed)' || fail 'cannot write completion log'; else log 'Reboot required: no' || fail 'cannot write completion log'; fi
  log 'Apply complete; zero exit is not a claim that every package is current.' || fail 'cannot write completion log'
  log "Phase log (metadata only): $LOG_FILE" || fail 'cannot write completion log'
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
