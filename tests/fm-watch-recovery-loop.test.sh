#!/usr/bin/env bash
# Pin the Pi/OpenCode recovery-loop fix: one announcement per generation, and a
# handling successor that keeps supervising instead of going blind.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-recovery-loop)
export NODE_NO_WARNINGS=1

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox" \
    "$repo/bin"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

# T1: a lost --handling-delivered handshake must not re-announce forever.
# The real Pi extension drives the real arm/watcher, with only the handshake
# RPC forced to fail. After the first recovery follow-up, wait past the old
# ~52s loop period so a regression would emit a second follow-up.
test_unacknowledged_recovery_is_announced_once_per_generation() {
  local repo home plugin fakebin out status lock_pid messages
  repo="$TMP_ROOT/t1-root"
  home="$TMP_ROOT/t1-home"
  fakebin="$TMP_ROOT/t1-fakebin"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$fakebin"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$repo/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --handling-delivered ]; then
  exit 1
fi
export FM_ROOT_OVERRIDE="$ROOT"
export PATH="$fakebin:\$PATH"
exec "$ROOT/bin/fm-watch-arm.sh" "\$@"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  : > "$home/state/seed.meta"
  printf 'pending:downtime:seed.1.aaa\n' > "$home/state/.watcher-down"
  chmod 600 "$home/state/.watcher-down"
  printf '%s\t1\tcheck\tseed\tcheck: seed recovery\n' "$(date +%s)" > "$home/state/.wake-queue"
  out=$(
    PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
      FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$PATH" \
      FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const prompts = [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompts.push(String(message));
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");
await tool.execute("tool-call-t1", {}, undefined, undefined, {});
const deadline = Date.now() + 75000;
let firstAt = 0;
while (Date.now() < deadline) {
  const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
  if (rearm.length > 1) {
    throw new Error(`unbounded recovery loop: ${rearm.length} rearm-resurface follow-ups`);
  }
  if (rearm.length === 1 && firstAt === 0) firstAt = Date.now();
  if (firstAt && Date.now() - firstAt >= 55000) break;
  await new Promise((resolve) => setTimeout(resolve, 200));
}
const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
if (rearm.length !== 1) {
  throw new Error(`expected exactly one recovery follow-up, got ${rearm.length}: ${prompts.join(" || ")}`);
}
const lockPid = existsSync(`${process.env.FM_HOME}/state/.watch.lock/pid`)
  ? readFileSync(`${process.env.FM_HOME}/state/.watch.lock/pid`, "utf8").trim()
  : "";
if (!/^[0-9]+$/.test(lockPid)) throw new Error("successor watcher lock pid missing");
try {
  process.kill(Number(lockPid), 0);
} catch {
  throw new Error(`successor watcher ${lockPid} is not alive`);
}
const marker = readFileSync(`${process.env.FM_HOME}/state/.watcher-down`, "utf8").trim();
if (!marker.startsWith("announced:") && !marker.startsWith("pending:")) {
  throw new Error(`successor did not keep a live recovery episode: ${marker}`);
}
console.log(`T1_MESSAGES=${rearm.length}`);
console.log(`T1_LOCK_PID=${lockPid}`);
console.log(`T1_MARKER=${marker}`);
process.exit(0);
EOF
  )
  status=$?
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '%s\n' "$out"
  fi
  lock_pid=$(sed -n 's/^T1_LOCK_PID=//p' <<<"$out" | tail -1)
  messages=$(sed -n 's/^T1_MESSAGES=//p' <<<"$out" | tail -1)
  if [ -n "$lock_pid" ]; then
    kill -TERM "$lock_pid" 2>/dev/null || true
  fi
  expect_code 0 "$status" "an unacknowledged recovery must be announced at most once per generation: $out"
  [ "$messages" = 1 ] || fail "T1 did not report a single recovery follow-up: $out"
  pass "unacknowledged recovery is announced at most once per generation and the successor stays alive"
}

# T2: a handling successor must enter its poll loop immediately and surface a
# real crew event instead of sitting in a pre-loop wait that refreshes the
# liveness beacon and then exits with a synthetic rearm-resurface.
test_handling_successor_does_not_go_blind() {
  local dir home state fakebin child event_start now out
  dir=$(make_case recovery-gap-successor)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  : > "$state/crew.meta"
  printf 'pending:downtime:gap.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  now=0
  while [ "$now" -lt 40 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] && break
    sleep 0.1
    now=$((now + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not take the watcher lock"; }
  sleep 0.4
  printf 'done: crew finished its task\n' >> "$state/crew.status"
  event_start=$(date +%s)
  now=0
  while [ "$now" -lt 5 ]; do
    if grep -q '^signal:' "$out" 2>/dev/null; then
      break
    fi
    sleep 0.5
    now=$((now + 1))
  done
  if ! grep -q '^signal:' "$out" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "handling successor did not surface the crew event within a poll interval or two (waited $(( $(date +%s) - event_start ))s): $(cat "$out")"
  fi
  grep -F 'crew.status' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not name the crew status file: $(cat "$out")"; }
  grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not enqueue a durable row for the crew event"; }
  ! grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor emitted synthetic recovery instead of supervising: $(cat "$out")"; }
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'T2_WATCH_OUTPUT=%s\n' "$(tr '\n' ' ' < "$out")"
    printf 'T2_QUEUE_ROW=%s\n' "$(grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" | tail -1)"
  fi
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  pass "a resurfacing handling successor stays alive and supervises instead of going blind"
}

# Drive the real recovery-marker transitions in a subprocess that sources the
# actual bin/fm-wake-lib.sh - the mechanism from the scout report's repro2.sh.
# The library functions are the recovery-marker contract's public interface and
# are the exact code watcher_cleanup (release-lock), fm-wake-drain.sh (ack), and
# the arm startup (arm-check) call. Driving them isolates the marker contract
# from the orthogonal stale-lock recovery path (FM_LOCK_RECOVERED_PID ->
# WATCHER_RECOVERY_PENDING), which a real watcher killed mid-poll would leak into
# and which is not the empty-resurface loop under diagnosis. Echoes the driver's
# stdout.
recovery_marker_driver() {  # <state-dir> <body>
  local st=$1 body=$2
  : > "$st/.wake-queue"
  FM_STATE_OVERRIDE="$st" STATE="$st" FM_WAKE_QUEUE="$st/.wake-queue" \
    ROOT="$ROOT" MARK_BODY="$body" bash <<'DRIVER'
set -u
. "$ROOT/bin/fm-wake-lib.sh"
MARK="$STATE/.watcher-down"
LOCK="$STATE/.watch.lock"
eval "$MARK_BODY"
DRIVER
}

# T3: the empty-resurface loop. After firstmate acknowledges an episode, the very
# next clean watcher close (release-lock) must NOT re-mint a fresh downtime
# episode over the acked marker while the durable queue is empty, so the next
# fresh non-successor arm's arm-check does not recover. This is the Claude
# Stop-hook shape (no FM_WATCH_HANDLING_SUCCESSOR), which the T1/T2 successor
# guard cannot cover.
test_acked_release_lock_does_not_resurface_empty() {
  local st out
  st=$(mktemp -d "$TMP_ROOT/acked-noresurface.XXXXXX")
  # shellcheck disable=SC2016 # body is expanded inside the driver subprocess, not here
  out=$(recovery_marker_driver "$st" '
    printf "announced:handling:GENx\n" > "$MARK"; chmod 600 "$MARK"
    fm_recovery_marker_ack "$MARK" GENx || { echo "ERR ack"; exit 1; }
    fm_recovery_transition "$MARK" release-lock "$LOCK" downtime 2>/dev/null || true
    printf "SETTLED=%s\n" "$(cat "$MARK")"
    fm_recovery_marker_arm_check "$MARK" || { echo "ERR arm-check"; exit 1; }
    printf "ACTION=%s\n" "$FM_RECOVERY_MARKER_ACTION"
  ') || fail "T3 marker driver failed: $out"
  case "$out" in
    *SETTLED=acked:*) ;;
    *) fail "T3 release-lock reopened a settled episode over an empty queue: $out" ;;
  esac
  case "$out" in
    *ACTION=recover*) fail "T3 fresh non-successor arm resurfaced an empty settled episode: $out" ;;
    *ACTION=none*) ;;
    *) fail "T3 unexpected arm-check outcome: $out" ;;
  esac
  [ "${FM_TEST_EVIDENCE:-0}" != 1 ] || printf '%s\n' "$out"
  pass "a settled acked episode survives a clean close and a fresh non-successor arm does not resurface an empty queue"
}

# T3b: the drain's real-work path must keep working. When durable work IS queued,
# a downtime publish over an acked marker must still re-mint a fresh episode so
# fm-wake-drain.sh can begin handling it - a blanket "preserve acked" would strand
# the queued wake in a marker state begin-handling rejects.
test_acked_with_queued_work_still_remints() {
  local st out
  st=$(mktemp -d "$TMP_ROOT/acked-queued-remint.XXXXXX")
  # shellcheck disable=SC2016 # body is expanded inside the driver subprocess, not here
  out=$(recovery_marker_driver "$st" '
    printf "acked:handling:GEN0\n" > "$MARK"; chmod 600 "$MARK"
    printf "111\t1\tsignal\tfoo\tbar\n" > "$FM_WAKE_QUEUE"
    fm_recovery_marker_publish "$MARK" downtime || { echo "ERR publish"; exit 1; }
    printf "REMINTED=%s\n" "$(cat "$MARK")"
    fm_recovery_marker_begin_handling "$MARK" || { echo "ERR begin"; exit 1; }
    printf "HANDLING=%s\n" "$(cat "$MARK")"
  ') || fail "T3b marker driver failed (drain real-work path broken): $out"
  case "$out" in
    *REMINTED=pending:downtime:*|*REMINTED=announced:downtime:*) ;;
    *) fail "T3b a queued wake over an acked marker was not given a fresh episode: $out" ;;
  esac
  case "$out" in
    *HANDLING=*:handling:*) ;;
    *) fail "T3b begin-handling could not adopt the re-minted episode: $out" ;;
  esac
  [ "${FM_TEST_EVIDENCE:-0}" != 1 ] || printf '%s\n' "$out"
  pass "an acked marker with durable queued work still re-mints a fresh episode the drain can handle"
}

# T4: the safety counterpart, required alongside T3. A mid-handshake death leaves
# an UNacknowledged episode (pending/announced, never acked). A clean close must
# preserve that live episode's generation, and a fresh non-successor arm must
# still recover (resurface) a pending one - the settled-episode fix must not
# silence a genuine supervision gap.
test_unacked_downtime_close_preserves_and_resurfaces() {
  local st out
  st=$(mktemp -d "$TMP_ROOT/unacked-resurfaces.XXXXXX")
  # shellcheck disable=SC2016 # body is expanded inside the driver subprocess, not here
  out=$(recovery_marker_driver "$st" '
    # pending death: close preserves generation, fresh arm recovers.
    printf "pending:downtime:GENp\n" > "$MARK"; chmod 600 "$MARK"
    fm_recovery_transition "$MARK" release-lock "$LOCK" downtime 2>/dev/null || true
    printf "PENDING_AFTER_CLOSE=%s\n" "$(cat "$MARK")"
    fm_recovery_marker_arm_check "$MARK" || { echo "ERR arm-check"; exit 1; }
    printf "PENDING_ACTION=%s\n" "$FM_RECOVERY_MARKER_ACTION"
    # announced death: close preserves the announced generation (the episode
    # stays live for the drain), never downgraded to acked.
    printf "announced:downtime:GENa\n" > "$MARK"; chmod 600 "$MARK"
    fm_recovery_transition "$MARK" release-lock "$LOCK" downtime 2>/dev/null || true
    printf "ANNOUNCED_AFTER_CLOSE=%s\n" "$(cat "$MARK")"
  ') || fail "T4 marker driver failed: $out"
  case "$out" in
    *PENDING_AFTER_CLOSE=pending:downtime:GENp*) ;;
    *) fail "T4 a pending mid-handshake death was not preserved across a clean close: $out" ;;
  esac
  case "$out" in
    *PENDING_ACTION=recover*) ;;
    *) fail "T4 a genuine unacknowledged gap did not resurface for a fresh arm: $out" ;;
  esac
  case "$out" in
    *ANNOUNCED_AFTER_CLOSE=announced:downtime:GENa*) ;;
    *) fail "T4 an announced mid-handshake death was not preserved across a clean close: $out" ;;
  esac
  [ "${FM_TEST_EVIDENCE:-0}" != 1 ] || printf '%s\n' "$out"
  pass "a mid-handshake death still leaves a live episode across a clean close and a pending gap still resurfaces"
}

test_handling_successor_does_not_go_blind
test_unacknowledged_recovery_is_announced_once_per_generation
test_acked_release_lock_does_not_resurface_empty
test_acked_with_queued_work_still_remints
test_unacked_downtime_close_preserves_and_resurfaces
