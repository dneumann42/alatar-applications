#!/usr/bin/env bash
set -eu

# Give this session its own Ellipse display so other projects can stay open.
display_dir=$(mktemp -d /tmp/systemdui-hot.XXXXXXXX)
export ELLIPSE_DISPLAY_SOCKET="$display_dir/display.sock"

cleanup() {
    if [[ -n ${ui_pid:-} ]]; then
        kill "$ui_pid" 2>/dev/null || true
        wait "$ui_pid" 2>/dev/null || true
    fi
    kill "$display_pid" 2>/dev/null || true
    wait "$display_pid" 2>/dev/null || true
    rm -f "$ELLIPSE_DISPLAY_SOCKET" "$ELLIPSE_DISPLAY_SOCKET.lock"
    rmdir "$display_dir"
}

./build/systemdui --display-serve &
display_pid=$!
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Wait for the window process to bind before attaching the reloadable UI.
until [[ -S "$ELLIPSE_DISPLAY_SOCKET" ]]; do
    if ! kill -0 "$display_pid" 2>/dev/null; then
        echo "SystemDUI display exited before the UI could attach" >&2
        exit 1
    fi
    sleep 0.05
done

./build/systemdui --hot-app --display-attach &
ui_pid=$!
wait -n "$display_pid" "$ui_pid"
