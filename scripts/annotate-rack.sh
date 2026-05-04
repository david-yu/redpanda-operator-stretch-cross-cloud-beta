#!/usr/bin/env bash
# scripts/annotate-rack.sh — (re-)annotate every node in each cluster with
# `redpanda.com/cloud=<aws|gcp|azure>` so the operator's rack-aware
# leader-pinning picks up the right rack for newly-added nodes.
#
# `bootstrap-redpanda.sh` annotates nodes once at bootstrap time, but
# nodes added later (e.g., GKE node-pool resize during Demo B's capacity
# injection step, or any cluster autoscaler activity) come up unannotated
# — broker pods that schedule on those nodes then join with `RACK: -`,
# which breaks `default_leaders_preference` matching for that broker.
#
# Idempotent — safe to re-run after every scaling operation. Caught
# during 2026-05-04 e2e v3 Demo B.
#
# Usage:
#   ./scripts/annotate-rack.sh

set -euo pipefail

CONTEXTS=(rp-aws rp-gcp rp-azure)

cloud_of() {
  case "$1" in
    rp-aws)   echo "aws" ;;
    rp-gcp)   echo "gcp" ;;
    rp-azure) echo "azure" ;;
    *) echo "unknown ctx: $1" >&2; exit 2 ;;
  esac
}

log() { echo "[annotate-rack] $*" >&2; }

for ctx in "${CONTEXTS[@]}"; do
  cloud=$(cloud_of "$ctx")
  if ! kubectl --context "$ctx" cluster-info >/dev/null 2>&1; then
    log "$ctx unreachable — skipping"
    continue
  fi
  count=$(kubectl --context "$ctx" get nodes -o name 2>/dev/null | wc -l | tr -d ' ')
  log "$ctx: annotating $count node(s) with redpanda.com/cloud=$cloud"
  kubectl --context "$ctx" annotate nodes --all "redpanda.com/cloud=$cloud" --overwrite >/dev/null
done

log "done"
