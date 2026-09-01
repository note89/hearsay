#!/usr/bin/env bash
# Live session timings and errors from the running app.
exec /usr/bin/log stream --level info --style compact --predicate 'subsystem == "computer.borrowed.hearsay"'
