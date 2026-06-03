# seed-roborev — task runner.
#
# `just test` is the merge gate (claude-config's `just test` convention).
# It runs the standalone unit suites, which mock roborev + $HOME and need no
# live daemon. `ref/verify.sh` is intentionally NOT wired in here — it asserts
# a real installed daemon + global hooks and only runs on a host that has
# actually run the SEED install.

# Run the unit suites (foreground, fail-loud): Claude bridge, pre-push gate, shared hook lib.
test:
    ./ref/test-bridge.sh
    ./ref/test-gate.sh
    ./ref/test-hooklib.sh
