#!/bin/bash
# Starts Dark Souls II with the Lighting Engine from its CrossOver bottle. Installed by install.sh
# next to config.sh and ds2mac; the "DS2 Lighting Engine" app just runs this script.
#   ds2le-launch.sh          full screen, the way STRETCH in config.sh says (see below)
#   ds2le-launch.sh --plain  without changing the display (with the mod's flip model the game still
#                            fills the screen, at the display's full resolution)
#   ds2le-launch.sh --run    internal: start the game, return once the bottle's Wine has exited
DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/config.sh" || exit 1
export LC_ALL=en_US.UTF-8
CX="$CX_APP/Contents/SharedSupport/CrossOver"
LOG="$DIR/launch.log"
SELF="$DIR/ds2le-launch.sh"

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }
notify() {
  osascript -e "display notification \"$1\" with title \"DS2 Lighting Engine\"" >/dev/null 2>&1
}
wine() { "$CX/bin/wine" --bottle "$BOTTLE" "$@"; }
# Is a wineserver running for $BOTTLE? Its environment (ps -E) holds CX_BOTTLE=<name>, followed by
# the next variable or the end of the line, so "Steam" doesn't match a bottle called "Steam 2".
bottle_running() {
  ps -E -x -o command= | B="$BOTTLE" awk '
    index($0, "/bin/wineserver") {
      k = " CX_BOTTLE=" ENVIRON["B"]; i = index($0, k)
      if (i) { r = substr($0, i + length(k)); if (r == "" || r ~ /^ [A-Za-z_][A-Za-z0-9_]*=/) { f = 1; exit } }
    }
    END { exit !f }'
}
# Wine shows a Windows process in ps by its Windows path.
game_running() { pgrep -f '^"?[A-Za-z]:\\.*\\DarkSoulsII\.exe' >/dev/null; }
steam_running() { pgrep -if '^"?[A-Za-z]:\\.*\\steam\.exe' >/dev/null; }
# wait_until SECONDS command...: true as soon as the command succeeds
wait_until() {
  local n=$1
  shift
  while ! "$@"; do
    [ "$n" -le 0 ] && return 1
    sleep 1
    n=$((n - 1))
  done
}
not() { ! "$@"; }
# game_config SIZE [--fullscreen]: the game's resolution and window mode.
game_config() { [ -n "${GFX:-}" ] && "$DIR/ds2mac" graphics-config "$GFX" "$@" >>"$LOG" 2>&1; }

if [ "${1:-}" = "--run" ]; then
  cd "$GAME_DIR" || exit 1
  if [ "$STEAM" = 1 ]; then
    log "starting the game through Steam"
    wine --cx-app "$STEAM_EXE_WIN" -applaunch 335300 >/dev/null 2>&1 &
    # Steam may update itself or ask to log in first. Give up when neither Steam nor the game has
    # been running for 30 seconds.
    idle=0
    while ! game_running && [ $idle -lt 30 ]; do
      if steam_running; then idle=0; else idle=$((idle + 1)); fi
      sleep 1
    done
  else
    log "starting the game"
    wine --cx-app "$GAME_EXE_WIN" >/dev/null 2>&1 &
    wpid=$!
    # Until the game shows up, or Wine gives up on starting it.
    while ! game_running && kill -0 $wpid 2>/dev/null; do sleep 1; done
  fi
  if game_running; then
    while game_running; do sleep 2; done
    log "game exited"
  else
    log "the game did not start"
    notify "The game did not start. See ~/Library/Application Support/ds2le-mac/launch.log"
  fi
  if [ "$STEAM" = 1 ] && steam_running; then
    log "closing Steam"
    wine --cx-app "$STEAM_EXE_WIN" -shutdown >/dev/null 2>&1 &
  fi
  # Wine's services linger for a while after the game. The virtual display has to outlive them, but
  # a wineserver must not outlive the virtual display either: it would keep the wrong display mode.
  if wait_until 120 not bottle_running; then
    log "wineserver gone"
  else
    log "wineserver still running after 2 minutes, stopping it"
    WINEPREFIX="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE" "$CX/bin/wineserver" -k >/dev/null 2>&1
    wait_until 10 not bottle_running
  fi
  # Leave the game set to a plain window, so starting it some other way (Steam, CrossOver) doesn't
  # open its fullscreen in the wrong display mode.
  game_config "$RESOLUTION"
  exit 0
fi

# One launch at a time. The lock lives as long as this process (and the display helper it waits for).
LOCK="$DIR/launch.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  if kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null; then
    notify "Dark Souls II is already starting or running."
    exit 0
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK" || exit 1
fi
echo $$ >"$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

[ -f "$LOG" ] && [ "$(wc -l <"$LOG")" -gt 500 ] && tail -200 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
game_running && { log "game already running"; exit 0; }

# How to fill the screen, STRETCH in config.sh:
#   1 (auto)  "ds2mac plan" decides. A 16:9 screen gets the game's own fullscreen in a display mode of
#             exactly the game's size: fills the screen, lowest input lag (with the Lighting Engine's
#             flip model the game stays windowed in that mode and the mod fills the screen). Other screens, like
#             MacBooks, switch to a lower "looks like" mode and get a 16:9 window as wide as that mode
#             (MacBook Pro 14": 1280x800 with a 2552x1436 window, 99.8% of the width). That window
#             size is added to the game's list of sizes in DarkSoulsII.exe first (ds2mac res-table).
#   mirror    a virtual display mirrored to the screen: full width on any screen, no change to the
#             game, but more input lag and a soft picture on external monitors
#   0         no display change: the game window as it is, or with the flip model the whole screen
#             at the display's full resolution (slow on large Retina screens)
method=${STRETCH:-1}
case "$method" in 1 | auto | mirror | 0) ;; *) log "unknown STRETCH=$method, using 1"; method=1 ;; esac
[ "${1:-}" = "--plain" ] && method=0
EXE="$GAME_DIR/DarkSoulsII.exe"
# A previous helper may still be undoing its display change.
wait_until 10 not pgrep -xq ds2mac

# The game's 60 FPS limiter oversleeps under Wine (54-55 FPS); see "ds2mac frame-limiter". Done on
# every start because a Steam update or file check puts the original exe back.
limiter=on
[ "${FRAME_LIMITER:-1}" = 0 ] && limiter=off
"$DIR/ds2mac" frame-limiter "$EXE" "$limiter" >>"$LOG" 2>&1 || log "could not set the frame limiter $limiter"
# The Lighting Engine's flip model (its upscaling needs it; on unless its settings turn it off) makes
# the game window borderless and as large as the screen by itself. Combined with the game's own
# fullscreen it hangs on a black screen under DXMT, so with it the game always starts windowed.
flip=1
grep -q '^enable_flip_model_swapchain=0' "$GAME_DIR/ds2le_user_settings.ini" 2>/dev/null && flip=0

kind="" dmode="" render=$RESOLUTION
if [ "$method" = 1 ] || [ "$method" = auto ]; then
  if read -r kind dmode render < <("$DIR/ds2mac" plan "$RESOLUTION" 2>>"$LOG") && [ -n "$render" ]; then
    # A window size the game doesn't offer goes into its list; if that fails, use its own size.
    if [ "$kind" = window ] && ! "$DIR/ds2mac" res-table "$EXE" "$render" >>"$LOG" 2>&1; then
      read -r kind dmode render < <("$DIR/ds2mac" plan "$RESOLUTION" --standard 2>>"$LOG")
    fi
  fi
  if [ -z "$kind" ] || [ -z "$render" ]; then
    # No display mode fits (for example a monitor without HiDPI modes): a virtual display does.
    log "no display mode fits a $RESOLUTION game, using a virtual display"
    notify "No display mode of this screen fits the game, so it runs on a virtual display (a little more input lag)."
    method=mirror kind="" render=$RESOLUTION
  fi
fi
log "launch: method $method ${kind:+$kind $dmode} game $render, flip model $flip"
if [ "$kind" = fullscreen ] && [ "$flip" = 0 ]; then game_config "$render" --fullscreen; else game_config "$render"; fi
if [ "$method" = 0 ]; then
  "$SELF" --run
  exit 0
fi

# Wine fixes its Retina scaling to the display mode it starts under, so the display change has to
# happen before the bottle's wineserver starts, never while it runs. After quitting the game the
# server can take a while to go away, and a running Steam client keeps it alive.
if bottle_running; then
  notify "Waiting for CrossOver to finish so the game can start full screen..."
  if [ "$STEAM" = 1 ] && steam_running; then
    log "closing Steam first"
    wine --cx-app "$STEAM_EXE_WIN" -shutdown >/dev/null 2>&1 &
  fi
  wait_until 60 not bottle_running
  log "waited for the previous wineserver"
fi
# fallback REASON: start in the game's own size in a plain window.
fallback() {
  log "$1, starting in a normal window"
  notify "Could not change the display mode, so the game starts at the screen's current resolution."
  game_config "$RESOLUTION"
  "$SELF" --run
  exit 0
}
bottle_running && fallback "bottle still running"

case "$method" in
  1 | auto) helper=(mode "$dmode") ;;
  mirror)
    size=$("$DIR/ds2mac" display-size "$WINDOW" 2>>"$LOG")
    [ -n "$size" ] || fallback "display-size failed"
    helper=(stretch "$size")
    ;;
  *) fallback "unknown STRETCH=$method" ;;
esac
if ! "$DIR/ds2mac" "${helper[@]}" -- "$SELF" --run >>"$LOG" 2>&1 && ! game_running; then
  # Let macOS finish undoing the display change before Wine starts.
  sleep 3
  fallback "display change failed"
fi
