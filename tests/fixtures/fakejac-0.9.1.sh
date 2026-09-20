#!/bin/sh
# Deterministic stand-in for a released `jac` binary (fixture v0.9.1).
# Prints its identity, echoes each received argument, and exits with
# $FAKEJAC_EXIT (default 0) so callers can verify exit-code propagation.
echo "fake-jac 0.9.1"
for arg in "$@"; do
  echo "arg: $arg"
done
exit "${FAKEJAC_EXIT:-0}"
