#!/bin/sh
# Exercise the actual Watch-only parser without creating an iOS test double.
set -eu
cd "$(dirname "$0")/.."
{
    sed -n '1,/^private struct WatchActivePayload/p' 'EterHealthWatch Watch App/WatchWorkoutManager.swift' |
        sed '/^import /{ /Foundation/!d; }; /^private struct WatchActivePayload/d'
    printf '%s\n' '
let current = Date(timeIntervalSince1970: 2000)
assert(!WatchTwinPayload(["summaryUpdatedAt": NSNumber(value: 1000.0)]).canReplaceSummary(updatedAt: current))
private let fresh = WatchTwinPayload(["summaryUpdatedAt": NSNumber(value: 3000.0)])
assert(fresh.updatedAt == Date(timeIntervalSince1970: 3000))
assert(fresh.canReplaceSummary(updatedAt: current))
assert(fresh.canReplaceSummary(updatedAt: nil))
assert(!WatchTwinPayload([:]).canReplaceSummary(updatedAt: current))
assert(!WatchTwinPayload(["summaryUpdatedAt": Double.nan]).canReplaceSummary(updatedAt: current))
print("Watch summary regression checks passed")'
} | swift -
