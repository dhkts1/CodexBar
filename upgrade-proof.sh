#!/usr/bin/env bash
# Upgrade proof for steipete/CodexBar#4517 (Claude account source: tcr).
#
# Shows, in one isolated run with invented accounts only:
#   1. upstream main's CLI reads claude-swap accounts and persists its retained usage;
#   2. this branch's CLI reads the SAME config and the SAME persisted file unchanged:
#      same IDs, same labels, retained usage still binds by fingerprint;
#   3. switching the config to claudeSwapSource "tcr" gives tcr:<slot> identities and
#      does not relabel or reuse the claude-swap records.
#
# Isolation: macOS Foundation ignores HOME for Application Support, Caches and the home
# directory, but honours CFFIXED_USER_HOME. Every CLI call runs under `env -i` with
# CFFIXED_USER_HOME and HOME pointed at a scratch home, PATH=/usr/bin:/bin, the config at
# CODEXBAR_CONFIG and CODEXBAR_DISABLE_KEYCHAIN_ACCESS=1. A compiled probe checks the
# redirect before the first CLI call and the run stops if it does not hold. The real
# ~/Library/Application Support/CodexBar is listed before and after and must not change.
#
# The `cswap` and `tcr` on the executable path are small fakes that print claude-swap
# list schema v1 from a file; neither real tool runs. Claude's ambient source is pinned
# to "oauth" in the config so nothing can start a `claude` process; with no keychain
# and an empty scratch home that path has no credentials and makes no request. Codex,
# enabled by default, is switched off so the dashboard only collects Claude.
#
# Usage: upgrade-proof.sh <base-CodexBarCLI> <head-CodexBarCLI> <transcript-out>
set -uo pipefail

BASE_CLI="$1"
HEAD_CLI="$2"
OUT="$3"

REAL_SUPPORT="$HOME/Library/Application Support/CodexBar"
SCRATCH="$(mktemp -d /tmp/codexbar-upgrade-proof.XXXXXX)"
FAKE_HOME="$SCRATCH/home"
BIN="$SCRATCH/bin"
DATA="$SCRATCH/fake-data"
CONFIG="$SCRATCH/config/config.json"
RETAINED="$FAKE_HOME/Library/Application Support/CodexBar/claude-swap-retained-usage.json"
mkdir -p "$FAKE_HOME" "$BIN" "$DATA" "$SCRATCH/config"

RAW="$SCRATCH/raw-transcript.txt"

say() { printf '\n==== %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }

# Every CLI call goes through here: a clean environment pointed only at scratch.
cli() {
    local bin="$1"; shift
    local name=head
    [ "$bin" = "$BASE_CLI" ] && name=base
    printf '$ [%s] CodexBarCLI %s\n' "$name" "$*"
    env -i \
        HOME="$FAKE_HOME" \
        CFFIXED_USER_HOME="$FAKE_HOME" \
        PATH=/usr/bin:/bin \
        TMPDIR="$SCRATCH/tmp/" \
        TERM=dumb \
        NO_COLOR=1 \
        CODEXBAR_CONFIG="$CONFIG" \
        CODEXBAR_DISABLE_KEYCHAIN_ACCESS=1 \
        "$bin" "$@"
    printf '[exit %s]\n' "$?"
}

real_support_listing() {
    find "$REAL_SUPPORT" -maxdepth 2 | sort
}

real_support_hashes() {
    find "$REAL_SUPPORT" -maxdepth 2 -type f -exec shasum -a 256 {} + | sort -k2
}

pin_for() { # <namespace> <slot> <email>
    local fp
    fp="$(printf '%s\0%s' "$2" "$3" | shasum -a 256 | cut -d' ' -f1)"
    printf 'claude/%s:%s:%s\n' "$1" "$2" "$fp"
}

show_retained() {
    printf '$ jq <retained file>  (source, opaqueID, accountFingerprint, primary.usedPercent, secondary.usedPercent)\n'
    if [ -f "$RETAINED" ]; then
        jq -c '.[] | {source: (.source // "(absent: claude-swap)"), opaqueID, accountFingerprint,
                      primary: .primary.usedPercent, secondary: .secondary.usedPercent}' "$RETAINED"
        printf 'sha256 %s\n' "$(shasum -a 256 "$RETAINED" | cut -d' ' -f1)"
    else
        printf '(no retained file)\n'
    fi
}

show_dashboard_accounts() { # <cli>
    cli "$1" dashboard --pretty --timeout 20 --output "$SCRATCH/dashboard.json"
    printf '$ jq <dashboard.json>  (Claude accounts: id, label, active, windows, error)\n'
    jq -c '.providers[] | select(.id == "claude") | .accounts[]
           | {id, label, active, windows: [.windows[] | "\(.kind) \(.usedPercent)%"], error}' "$SCRATCH/dashboard.json"
}

main() {
    say "Builds"
    printf 'base (upstream main, PR merge base): %s\n' "$BASE_REV"
    printf 'head (PR branch):                    %s\n' "$HEAD_REV"

    say "Real ~/Library/Application Support/CodexBar BEFORE (find -maxdepth 2)"
    real_support_listing | tee "$SCRATCH/real-before.txt"
    real_support_hashes > "$SCRATCH/real-before-hashes.txt"

    say "Isolation preflight: where Foundation resolves paths under this environment"
    mkdir -p "$SCRATCH/tmp" "$SCRATCH/probe"
    printf 'import Foundation\nlet fm = FileManager.default\nprint(fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path)\nprint(fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].path)\nprint(fm.homeDirectoryForCurrentUser.path)\n' > "$SCRATCH/probe/p.swift"
    xcrun swiftc "$SCRATCH/probe/p.swift" -o "$SCRATCH/probe/p" 2>/dev/null
    local probe
    probe="$(env -i HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" PATH=/usr/bin:/bin "$SCRATCH/probe/p")"
    printf '%s\n' "$probe"
    if [ "$(printf '%s\n' "$probe" | sed -n 1p)" != "$FAKE_HOME/Library/Application Support" ]; then
        printf 'STOP: Application Support is not redirected; refusing to run the CLI.\n'
        return 3
    fi
    printf 'control (no CFFIXED_USER_HOME, HOME only): %s\n' \
        "$(env -i HOME="$FAKE_HOME" PATH=/usr/bin:/bin "$SCRATCH/probe/p" | sed -n 1p)"

    # Fixed times for the whole run, so every step sees the same windows.
    local now reset5h reset7d
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    reset5h="$(date -u -v+2H +%Y-%m-%dT%H:%M:%SZ)"
    reset7d="$(date -u -v+5d +%Y-%m-%dT%H:%M:%SZ)"

    # claude-swap list v1, step 1: alice is at the 5-hour limit, bob is at 20%.
    cat > "$DATA/cswap-step1.json" <<JSON
{"schemaVersion": 1, "activeAccountNumber": 1, "accounts": [
 {"number": 1, "email": "alice@example.com", "organizationName": "", "active": true, "usageStatus": "ok",
  "usageFetchedAt": "$now", "disabled": false,
  "usage": {"fiveHour": {"pct": 100.0, "resetsAt": "$reset5h"}, "sevenDay": {"pct": 40.0, "resetsAt": "$reset7d"}}},
 {"number": 2, "email": "bob@example.com", "organizationName": "", "active": false, "usageStatus": "ok",
  "usageFetchedAt": "$now", "disabled": false,
  "usage": {"fiveHour": {"pct": 20.0, "resetsAt": "$reset5h"}, "sevenDay": {"pct": 60.0, "resetsAt": "$reset7d"}}}
]}
JSON
    # Step 2: the same accounts, but claude-swap can no longer measure alice. Her bars can
    # only come from the retained file that step 1's build wrote.
    jq '.accounts[0].usageStatus = "unavailable" | .accounts[0].usage = {} | del(.accounts[0].usageFetchedAt)' \
        "$DATA/cswap-step1.json" > "$DATA/cswap-step2.json"
    # tcr list v1: same slots and emails as claude-swap, no active account, no switching;
    # alice unavailable here too, bob at 30%.
    jq '.activeAccountNumber = null | .supportsAccountSwitching = false
        | .accounts[0].active = false | .accounts[1].usage.fiveHour.pct = 30.0' \
        "$DATA/cswap-step2.json" > "$DATA/tcr.json"

    cat > "$BIN/cswap" <<SH
#!/bin/bash
# FAKE cswap: answers only \`--list --json\` with the current step's file.
[ "\$*" = "--list --json" ] || { echo "fake cswap: unexpected args: \$*" >&2; exit 2; }
cat "$DATA/cswap-\$(cat "$DATA/step").json"
SH
    cat > "$BIN/tcr" <<SH
#!/bin/bash
# FAKE tcr: answers only \`list --json\`.
[ "\$*" = "list --json" ] || { echo "fake tcr: unexpected args: \$*" >&2; exit 2; }
cat "$DATA/tcr.json"
SH
    chmod +x "$BIN/cswap" "$BIN/tcr"

    # Upstream config: Claude on, claude-swap on, NO claudeSwapSource key.
    cat > "$CONFIG" <<JSON
{
  "version": 1,
  "providers": [
    {
      "id": "claude",
      "enabled": true,
      "source": "oauth",
      "claudeSwapEnabled": true,
      "claudeSwapExecutablePath": "$BIN/cswap"
    },
    {
      "id": "codex",
      "enabled": false
    }
  ]
}
JSON

    say "Config (written once; steps 1 and 2 share it untouched)"
    run cat "$CONFIG"
    printf 'claudeSwapSource key present: %s\n' "$(jq '.providers[0] | has("claudeSwapSource")' "$CONFIG")"
    shasum -a 256 "$CONFIG" | cut -d' ' -f1 > "$SCRATCH/config-step1.sha"

    say "Widget pins main writes: claude/swap:<slot>:sha256(<slot> NUL <email>), computed here in shell"
    printf '(the CLI cannot print pins; the branch test that pins these bytes is\n'
    printf ' ClaudeSwapTcrConsumerTests "claude-swap widget pins keep the exact bytes main writes")\n'
    pin_for swap 1 alice@example.com | tee "$SCRATCH/pins-swap.txt"
    pin_for swap 2 bob@example.com | tee -a "$SCRATCH/pins-swap.txt"

    # ---------------------------------------------------------------- step 1
    echo step1 > "$DATA/step"
    say "STEP 1  upstream main CLI, claude-swap source (key absent)"
    run "$BIN/cswap" --list --json
    cli "$BASE_CLI" cards --provider claude --no-color
    show_dashboard_accounts "$BASE_CLI"
    say "STEP 1  persisted by upstream main"
    (cd "$FAKE_HOME" && find . -type f | sort)
    show_retained
    cp "$RETAINED" "$SCRATCH/retained-after-step1.json"

    # ---------------------------------------------------------------- step 2
    echo step2 > "$DATA/step"
    say "STEP 2  PR branch CLI, SAME config, SAME persisted data"
    printf 'config sha256 unchanged since step 1: %s\n' \
        "$([ "$(shasum -a 256 "$CONFIG" | cut -d' ' -f1)" = "$(cat "$SCRATCH/config-step1.sha")" ] && echo yes || echo NO)"
    printf 'retained file unchanged since step 1: %s\n' \
        "$(cmp -s "$RETAINED" "$SCRATCH/retained-after-step1.json" && echo yes || echo NO)"
    run "$BIN/cswap" --list --json
    # Mirror of the branch's resolvedClaudeSwapSource: an absent key reads as claude-swap.
    printf 'claudeSwapSource in config: %s  -> resolves to claude-swap (the branch default)\n' \
        "$(jq -r '.providers[0].claudeSwapSource // "(absent)"' "$CONFIG")"
    cp -R "$FAKE_HOME" "$SCRATCH/home-before-step2"
    cli "$HEAD_CLI" cards --provider claude --no-color
    show_dashboard_accounts "$HEAD_CLI"
    say "STEP 2  persisted file after the PR branch rewrote it"
    show_retained
    printf 'fingerprints identical to step 1: %s\n' \
        "$([ "$(jq -c '[.[] | [.opaqueID, .accountFingerprint]]' "$RETAINED")" = \
             "$(jq -c '[.[] | [.opaqueID, .accountFingerprint]]' "$SCRATCH/retained-after-step1.json")" ] && echo yes || echo NO)"
    # JSONEncoder does not sort keys, so the raw bytes can differ run to run; compare content.
    printf 'whole file content identical to step 1 (jq -S, key order ignored): %s\n' \
        "$([ "$(jq -S -c . "$RETAINED")" = "$(jq -S -c . "$SCRATCH/retained-after-step1.json")" ] && echo yes || echo NO)"
    jq -r '.[] | "claude/swap:\(.opaqueID):\(.accountFingerprint)"' "$RETAINED" > "$SCRATCH/pins-from-file.txt"
    printf 'pins rebuilt from the retained file equal the pins main writes: %s\n' \
        "$(cmp -s "$SCRATCH/pins-swap.txt" "$SCRATCH/pins-from-file.txt" && echo yes || echo NO)"

    say "STEP 2 control: same branch, same input, retained file removed (alice must lose her 100%)"
    local ctl="$SCRATCH/control"
    mkdir -p "$ctl"
    cp -R "$SCRATCH/home-before-step2" "$ctl/home"
    rm "$ctl/home/Library/Application Support/CodexBar/claude-swap-retained-usage.json"
    printf '$ [head] CodexBarCLI cards --provider claude --no-color   (control home, no retained file)\n'
    env -i HOME="$ctl/home" CFFIXED_USER_HOME="$ctl/home" PATH=/usr/bin:/bin TMPDIR="$SCRATCH/tmp/" \
        TERM=dumb NO_COLOR=1 CODEXBAR_CONFIG="$CONFIG" CODEXBAR_DISABLE_KEYCHAIN_ACCESS=1 \
        "$HEAD_CLI" cards --provider claude --no-color
    printf '[exit %s]\n' "$?"

    # ---------------------------------------------------------------- step 3
    say "STEP 3  PR branch CLI, config switched to tcr"
    jq --arg tcr "$BIN/tcr" '.providers[0].claudeSwapSource = "tcr" | .providers[0].claudeSwapExecutablePath = $tcr' \
        "$CONFIG" > "$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
    run cat "$CONFIG"
    printf 'retained file going in (from step 2):\n'
    show_retained
    run "$BIN/tcr" list --json
    cli "$HEAD_CLI" cards --provider claude --no-color
    show_dashboard_accounts "$HEAD_CLI"
    say "STEP 3  persisted file after the tcr run"
    show_retained
    # Relabelling would show as a tcr record for slot 1 carrying claude-swap's 100%, or a
    # tcr slot 2 record carrying claude-swap's 20% instead of tcr's own 30%.
    printf 'tcr records carrying a claude-swap window (slot 1 at 100%%, or slot 2 at 20%%): %s\n' \
        "$(jq '[.[] | select(.source == "tcr") | select((.opaqueID == "1" and .primary.usedPercent == 100)
                or (.opaqueID == "2" and .primary.usedPercent == 20))] | length' "$RETAINED")"
    printf 'claude-swap records left in the file: %s (the file holds the last run'"'"'s source only)\n' \
        "$(jq '[.[] | select(.source == null)] | length' "$RETAINED")"
    say "Expected tcr widget pins (separate namespace, same fingerprint material)"
    pin_for tcr 1 alice@example.com
    pin_for tcr 2 bob@example.com

    # ---------------------------------------------------------------- isolation
    say "Real ~/Library/Application Support/CodexBar AFTER (find -maxdepth 2)"
    real_support_listing | tee "$SCRATCH/real-after.txt"
    real_support_hashes > "$SCRATCH/real-after-hashes.txt"
    if diff "$SCRATCH/real-before.txt" "$SCRATCH/real-after.txt" >/dev/null; then
        printf 'listing: IDENTICAL before and after\n'
    else
        printf 'listing: DIFFERENT\n'; diff "$SCRATCH/real-before.txt" "$SCRATCH/real-after.txt"
    fi
    if diff "$SCRATCH/real-before-hashes.txt" "$SCRATCH/real-after-hashes.txt" >/dev/null; then
        printf 'file contents (sha256 of every file at depth <= 2): IDENTICAL\n'
    else
        printf 'file contents: DIFFERENT for:\n'
        diff "$SCRATCH/real-before-hashes.txt" "$SCRATCH/real-after-hashes.txt" | sed -n 's/^[<>] [0-9a-f]* *//p' | sort -u
    fi
    say "Every file the CLI wrote under the scratch home"
    (cd "$FAKE_HOME" && find . -type f | sort)
}

BASE_REV="${BASE_REV:-unknown}"
HEAD_REV="${HEAD_REV:-unknown}"
main > "$RAW" 2>&1
status=$?
# Redact the local user name from paths; scratch paths read as <scratch>.
sed -e "s#$SCRATCH#<scratch>#g" -e "s#$HOME#~#g" "$RAW" > "$OUT"
printf 'transcript: %s (main exit %s, scratch %s)\n' "$OUT" "$status" "$SCRATCH"
exit "$status"
