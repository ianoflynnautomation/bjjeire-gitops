#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

readonly LABEL_SELECTOR='bjjeire.io/pr-env=true'
readonly TTL_ANNOTATION='janitor/ttl'
readonly DEFAULT_TTL_SECONDS=7200    # 2h

log()  { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

ttl_to_seconds() {
  local v="${1:-}"
  case "${v}" in
    *s) printf '%s\n' "${v%s}" ;;
    *m) printf '%s\n' $(( ${v%m} * 60 )) ;;
    *h) printf '%s\n' $(( ${v%h} * 3600 )) ;;
    *d) printf '%s\n' $(( ${v%d} * 86400 )) ;;
    *)  printf '%s\n' "${DEFAULT_TTL_SECONDS}" ;;
  esac
}

list_pr_namespaces() {
  kubectl get namespaces -l "${LABEL_SELECTOR}" -o jsonpath="\
{range .items[*]}\
{.metadata.name}{'\t'}\
{.metadata.creationTimestamp}{'\t'}\
{.metadata.annotations['${TTL_ANNOTATION}']}\
{'\n'}{end}"
}

main() {
  local now_epoch inspected=0 reaped=0 failed=0
  local name created ttl ttl_s created_epoch age
  now_epoch=$(date -u +%s)

  while IFS=$'\t' read -r name created ttl; do
    [[ -z ${name} ]] && continue
    (( inspected++ ))

    ttl_s=$(ttl_to_seconds "${ttl}")
    created_epoch=$(date -u -d "${created}" +%s)
    age=$(( now_epoch - created_epoch ))

    if (( age >= ttl_s )); then
      log "reap ${name} age=${age}s ttl=${ttl_s}s"
      if kubectl delete namespace "${name}" --wait=false; then
        (( reaped++ ))
      else
        (( failed++ ))
        log "WARN delete failed for ${name}"
      fi
    else
      log "keep ${name} age=${age}s ttl=${ttl_s}s"
    fi
  done < <(list_pr_namespaces)

  log "done inspected=${inspected} reaped=${reaped} failed=${failed}"
  (( failed == 0 )) || fail "${failed} namespace(s) failed to delete"
}

main "$@"
