#!/bin/sh
# Standalone ArgoCD audit snapshot. Dependencies: POSIX shell, kubectl, date.
# Cluster access is read-only and uses kubectl get exclusively.
set -eu
umask 077

usage() {
    cat <<'EOF'
Usage: sh argocd-user-audit.sh [-n NAMESPACE] [--context CONTEXT] [-o FILE]

Defaults: namespace argocd, current kubeconfig context, report to stdout.
  -n, --namespace  Namespace containing the ArgoCD Application resources
  --context       Use this kubeconfig context without changing kubeconfig
  -o, --output    Create a private report file; refuse to overwrite a file
  -h, --help      Show this help

Examples:
  sh argocd-user-audit.sh
  sh argocd-user-audit.sh --context production -o audit-report.txt
  sh argocd-user-audit.sh -n argocd-apps

Requires get/list permission for events and applications.argoproj.io.
Run once per Application namespace when applications-in-any-namespace is used.
Only kubectl get is executed; nothing is installed or changed on the cluster.
Exit status: 0 = all queries succeeded, 1 = partial report, 2 = usage error.
A successful export does not imply complete audit coverage.
EOF
}

namespace=argocd
context=
output=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -n|--namespace|--context|-o|--output)
            [ "$#" -ge 2 ] && [ -n "$2" ] || { printf 'Missing value for %s\n' "$1" >&2; exit 2; }
            case "$1" in
                -n|--namespace) namespace=$2 ;;
                --context) context=$2 ;;
                -o|--output) output=$2 ;;
            esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done
command -v kubectl >/dev/null 2>&1 || { printf 'kubectl is required.\n' >&2; exit 2; }

# Capture an existing kubeconfig context through kubectl flags, never config use-context.
kget() {
    if [ -n "$context" ]; then
        kubectl --context="$context" --namespace="$namespace" --request-timeout=30s get "$@"
    else
        kubectl --namespace="$namespace" --request-timeout=30s get "$@"
    fi
}

failed=0
section() {
    title=$1
    shift
    printf '\n=== %s ===\n' "$title"
    if ! kget "$@"; then
        printf '[QUERY FAILED: this section is unavailable; inspect stderr]\n'
        failed=$((failed + 1))
    fi
}

report() {
    printf 'ArgoCD user action evidence snapshot\nGenerated UTC: %s\nNamespace: %s\nContext: %s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$namespace" "${context:-current kubeconfig context}"
    cat <<'EOF'

Coverage: currently retained Kubernetes events and Application status/history.
Rows describe evidence, not a count of distinct actions. Events may aggregate
repeated activity (COUNT); latest operation state can overwrite earlier state.
USERNAME is the initiator stored by ArgoCD; AUTOMATED=true means controller
initiation. A blank/<none>/<no value> username means identity is unavailable,
not necessarily anonymous. History contains retained deployment records only.

Events expire, deployment history is bounded, and deleted applications are
absent. Logins, reads, failed authentication, denied requests, and arbitrary
API changes are not comprehensively available through kubectl get. Use ArgoCD
API logs, identity-provider events, and Kubernetes API audit logs for those.
No claim of a complete or immutable compliance audit trail is made here.
Queries are separate snapshots, not an atomic view of the cluster.

Event messages can include user-controlled text or sensitive error details.
Treat this report as confidential; do not execute its contents or publish it.
No Secret, request body, token, full Application spec, or kubeconfig is exported.
EOF

    section 'Application events (oldest lastTimestamp first)' events \
        --field-selector=involvedObject.kind=Application --sort-by=.lastTimestamp \
        '-o=custom-columns=FIRST:.firstTimestamp,LAST:.lastTimestamp,EVENT_TIME:.eventTime,COUNT:.count,APPLICATION:.involvedObject.name,REASON:.reason,TYPE:.type,MESSAGE:.message'

    section 'AppProject events (oldest lastTimestamp first)' events \
        --field-selector=involvedObject.kind=AppProject --sort-by=.lastTimestamp \
        '-o=custom-columns=FIRST:.firstTimestamp,LAST:.lastTimestamp,EVENT_TIME:.eventTime,COUNT:.count,PROJECT:.involvedObject.name,REASON:.reason,TYPE:.type,MESSAGE:.message'

    section 'Latest operation state and recorded initiator' applications.argoproj.io \
        '-o=custom-columns=APPLICATION:.metadata.name,PROJECT:.spec.project,STARTED:.status.operationState.startedAt,FINISHED:.status.operationState.finishedAt,USERNAME:.status.operationState.operation.initiatedBy.username,AUTOMATED:.status.operationState.operation.initiatedBy.automated,PHASE:.status.operationState.phase,REVISION:.status.operationState.syncResult.revision,REVISIONS:.status.operationState.syncResult.revisions'

    section 'Pending/current operation request' applications.argoproj.io \
        '-o=custom-columns=APPLICATION:.metadata.name,USERNAME:.operation.initiatedBy.username,AUTOMATED:.operation.initiatedBy.automated,REVISION:.operation.sync.revision,REVISIONS:.operation.sync.revisions,PRUNE:.operation.sync.prune,DRY_RUN:.operation.sync.dryRun'

    # Capture the application name before ranging into its history.
    # Render selected fields only; source/values and other specs are excluded.
    section 'Retained deployment history (tab-separated fields)' applications.argoproj.io \
        '-o=go-template={{printf "APPLICATION\tID\tSTARTED\tDEPLOYED\tUSERNAME\tAUTOMATED\tREVISION\tREVISIONS\n"}}{{range .items}}{{$app := .metadata.name}}{{range .status.history}}{{$app}}{{"\t"}}{{.id}}{{"\t"}}{{.deployStartedAt}}{{"\t"}}{{.deployedAt}}{{"\t"}}{{if .initiatedBy}}{{.initiatedBy.username}}{{end}}{{"\t"}}{{if .initiatedBy}}{{.initiatedBy.automated}}{{end}}{{"\t"}}{{.revision}}{{"\t"}}{{.revisions}}{{"\n"}}{{end}}{{end}}'

    printf '\nQuery failures: %s\n' "$failed"
    if [ "$failed" -gt 0 ]; then
        printf 'PARTIAL REPORT: one or more sections could not be collected.\n'
        return 1
    fi
    printf 'All queries succeeded. Coverage limitations above still apply.\n'
}

if [ -n "$output" ]; then
    # Open once with noclobber to protect existing files, including symlinks.
    set -C
    exec 3>"$output"
    set +C
    report >&3
else
    report
fi
