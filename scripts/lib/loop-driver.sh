#!/usr/bin/env bash
# loop-driver.sh — Core loop driver logic.
# Extracted from sw-loop.sh as a thin orchestrator module.
# Individual loop functions will migrate here from sw-loop.sh incrementally.
# Currently serves as the canonical entry point for loop lib modules.
set -euo pipefail
[[ -n "${_LOOP_DRIVER_LOADED:-}" ]] && return 0
_LOOP_DRIVER_LOADED=1

_LD_DIR="$(dirname "${BASH_SOURCE[0]}")"

# Source loop lib modules
# shellcheck source=loop-restart.sh
[[ -n "${_LOOP_RESTART_LOADED:-}" ]] || { [[ -f "$_LD_DIR/loop-restart.sh" ]] && source "$_LD_DIR/loop-restart.sh"; }
# shellcheck source=loop-convergence.sh
[[ -n "${_LOOP_CONVERGENCE_LOADED:-}" ]] || { [[ -f "$_LD_DIR/loop-convergence.sh" ]] && source "$_LD_DIR/loop-convergence.sh"; }
# shellcheck source=loop-iteration.sh
[[ -n "${_LOOP_ITERATION_LOADED:-}" ]] || { [[ -f "$_LD_DIR/loop-iteration.sh" ]] && source "$_LD_DIR/loop-iteration.sh"; }
# shellcheck source=loop-progress.sh
[[ -n "${_LOOP_PROGRESS_LOADED:-}" ]] || { [[ -f "$_LD_DIR/loop-progress.sh" ]] && source "$_LD_DIR/loop-progress.sh"; }
# shellcheck source=loop-cost.sh
[[ -n "${_LOOP_COST_LOADED:-}" ]] || { [[ -f "$_LD_DIR/loop-cost.sh" ]] && source "$_LD_DIR/loop-cost.sh"; }
