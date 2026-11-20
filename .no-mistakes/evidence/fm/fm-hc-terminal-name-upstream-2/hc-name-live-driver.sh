#!/usr/bin/env bash
set -u
ROOT={run-worktree}
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/hc-test-safety.sh"
export FM_HC_BIN=$(command -v hc)
TMP_ROOT=$(fm_test_tmproot fm-hcname-live)
SES=$("$ROOT/bin/fm-hc-lab.sh" name hcname)
RC=0
cleanup() { local rc=$?; trap - EXIT; hc_test_safe_teardown "$ROOT" "$SES" || rc=1; fm_test_cleanup; exit "$rc"; }
trap cleanup EXIT
"$ROOT/bin/fm-hc-lab.sh" provision "$SES" || { echo "provision failed"; exit 1; }
SOCK=$("$ROOT/bin/fm-hc-lab.sh" socket "$SES")
hc_test_refuse_if_unsafe "$SES" || exit 1
LAB=$(hc_test_lab_dir)/$SES
export HC_SESSION=$SES FM_HC_SOCKET=$SOCK XDG_STATE_HOME="$LAB/env/xdg-state" XDG_CONFIG_HOME="$LAB/env/xdg-config" XDG_DATA_HOME="$LAB/env/xdg-data"
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET
HOME_A=$TMP_ROOT/homeA; HOME_B=$TMP_ROOT/homeB; WORK=$TMP_ROOT/work
mkdir -p "$HOME_A" "$HOME_B" "$WORK"
export FM_HOME=$HOME_A FM_ROOT_OVERRIDE=$HOME_A FM_ROOT=$HOME_A
. "$ROOT/bin/fm-backend.sh"
fm_backend_source hc || exit 1
echo "# hc $(hc --version), lab session $SES"
S2=$(fm_backend_hc_container_ensure) || { echo "ensure failed"; exit 1; }
hcget() { HC_SESSION=$SES HC_SOCKET=$SOCK hc get "$1" --json; }
check() { # <label> <expected-name-or-null>
  local label=$1 want=$2 addr got labels
  if ! addr=$(fm_backend_hc_create_task "$S2" "$label" "$WORK" 2>"$TMP_ROOT/err"); then
    echo "FAIL $label: create_task failed: $(cat "$TMP_ROOT/err")"; RC=1; return; fi
  got=$(hcget "$addr" | jq -r '.name // .terminal.name // "null"')
  labels=$(hcget "$addr" | jq -c '.labels // .terminal.labels')
  if [ "$got" = "$want" ]; then echo "PASS $label -> $addr name=$got labels=$labels"; else echo "FAIL $label -> $addr name=$got want=$want"; RC=1; fi
  LAST=$addr
}
echo "## S1 sanitize: mixed case, dot, underscore"
check fm-Fix.Login_Bug fix-login_bug
echo "## S2 truncation to 32"
check fm-abcdefghij-abcdefghij-abcdefghij-XYZ abcdefghij-abcdefghij-abcdefghij
echo "## S3 id-shaped names skipped, todo/test kept"
check fm-t7 null
check fm-t8f null
check fm-T12 null
check fm-todo todo
check fm-test test
echo "## S4 leading _ and - skipped"
check fm-_x null
check fm--y null
echo "## S5 name_taken fallback: same task id in a second home"
check fm-dup dup
A_ADDR=$LAST
export FM_HOME=$HOME_B FM_ROOT_OVERRIDE=$HOME_B FM_ROOT=$HOME_B; echo "# hometag now $(fm_backend_hometag)"
check fm-dup null
B_ADDR=$LAST
echo "# raw hc on a taken name (oracle):"; HC_SESSION=$SES HC_SOCKET=$SOCK hc run --bg --json --name=dup -- true; echo "# exit=$?"
echo "## S6 identity is labels: steer/capture/close the named and unnamed dup terminals"
export FM_HOME=$HOME_A FM_ROOT_OVERRIDE=$HOME_A FM_ROOT=$HOME_A; echo "# hometag now $(fm_backend_hometag)"
TA="$S2:$A_ADDR"
fm_backend_hc_send_text_line "$TA" "echo Named-A-91" fm-dup || { echo "FAIL send A"; RC=1; }
for i in $(seq 50); do fm_backend_capture hc "$TA" 50 fm-dup | grep -qx Named-A-91 && break; sleep 0.1; done
fm_backend_capture hc "$TA" 50 fm-dup | grep -qx Named-A-91 && echo "PASS home A send+capture on named $A_ADDR" || { echo "FAIL capture A"; RC=1; }
export FM_HOME=$HOME_B FM_ROOT_OVERRIDE=$HOME_B FM_ROOT=$HOME_B; echo "# hometag now $(fm_backend_hometag)"
TB="$S2:$B_ADDR"
fm_backend_hc_send_text_line "$TA" "echo Cross-Home" fm-dup 2>&1 && { echo "FAIL home B could steer home A terminal"; RC=1; } || echo "PASS home B refused to steer home A's $A_ADDR (label check)"
fm_backend_hc_send_text_line "$TB" "echo Unnamed-B-17" fm-dup || { echo "FAIL send B"; RC=1; }
for i in $(seq 50); do fm_backend_capture hc "$TB" 50 fm-dup | grep -qx Unnamed-B-17 && break; sleep 0.1; done
fm_backend_capture hc "$TB" 50 fm-dup | grep -qx Unnamed-B-17 && echo "PASS home B send+capture on unnamed $B_ADDR" || { echo "FAIL capture B"; RC=1; }
fm_backend_kill hc "$TB" "" fm-dup && [ "$(fm_backend_agent_state hc "$TB")" = missing ] && echo "PASS home B closed $B_ADDR" || { echo "FAIL kill B"; RC=1; }
export FM_HOME=$HOME_A FM_ROOT_OVERRIDE=$HOME_A FM_ROOT=$HOME_A; echo "# hometag now $(fm_backend_hometag)"
fm_backend_kill hc "$TA" "" fm-dup && [ "$(fm_backend_agent_state hc "$TA")" = missing ] && echo "PASS home A closed named $A_ADDR" || { echo "FAIL kill A"; RC=1; }
echo "## S7 name freed after close: home A respawns fm-dup and gets the name back"
check fm-dup dup
echo "## hc ls (names as Herdr sees them)"
HC_SESSION=$SES HC_SOCKET=$SOCK hc ls --json | jq -c '(.terminals? // .) | .[]? | objects | {address, name, task: .labels["firstmate.task"]}'
echo "# overall RC=$RC"
exit $RC
