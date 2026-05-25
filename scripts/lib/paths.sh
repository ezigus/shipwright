#!/usr/bin/env bash
set -euo pipefail
SW_HOME="${HOME}/.shipwright"
SW_EVENTS="${SW_HOME}/events.jsonl"
SW_COSTS="${SW_HOME}/costs.json"
SW_HEARTBEATS="${SW_HOME}/heartbeats"
SW_ARTIFACTS="${SW_HOME}/artifacts"
SW_PIPELINE_ARTIFACTS="${PWD}/.claude/pipeline-artifacts"
export SW_HOME SW_EVENTS SW_COSTS SW_HEARTBEATS SW_ARTIFACTS SW_PIPELINE_ARTIFACTS
