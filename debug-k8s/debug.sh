#!/usr/bin/env bash
# k8s-debug.sh - read-only Kubernetes triage helper. Never modifies the cluster.
#
#   k8s-debug.sh pod  <name> [-n ns] [-c container] [--tail N]   why is this pod broken?
#   k8s-debug.sh node <name>                                     why is this node unhealthy?
#   k8s-debug.sh svc  <name> [-n ns]                             why does this service have no traffic?
#   k8s-debug.sh ns   [-n ns | -A]                               what is unhealthy right now?
#
# Global options: --context <ctx>   -n/--namespace <ns>   -A/--all-namespaces
# Env: RESTART_WARN=5 (restart count that flags a pod as unhealthy)

set -uo pipefail   # no -e on purpose: keep going when one diagnostic step fails

NS="" CTX="" CONTAINER="" TAIL=50 ALL=0
RESTART_WARN="${RESTART_WARN:-5}"

if [[ -t 1 ]]; then B=$'\033[1m' Y=$'\033[33m' Z=$'\033[0m'; else B="" Y="" Z=""; fi
hdr()  { printf '\n%s== %s ==%s\n' "$B" "$*" "$Z"; }
warn() { printf '%s[!] %s%s\n' "$Y" "$*" "$Z"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
k()    { kubectl ${CTX:+--context "$CTX"} "$@"; }

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ------------------------------------------------------------------ hints
exit_hint() {  # $1=exit code  $2=reason
  case $1 in
    1)   echo "application error: read the previous logs" ;;
    2)   echo "bad arguments / shell misuse in the entrypoint" ;;
    126) echo "command found but not executable (permissions / wrong arch)" ;;
    127) echo "command not found: wrong command/args/entrypoint or missing binary" ;;
    137) if [[ ${2:-} == OOMKilled ]]; then echo "OOMKilled: raise the memory limit or fix a leak"
         else echo "SIGKILL: OOM, failing liveness probe, or node pressure"; fi ;;
    139) echo "segfault in the application" ;;
    143) echo "SIGTERM: normal shutdown, eviction, rollout or probe restart" ;;
    *)   echo "non-zero exit, check logs" ;;
  esac
}

waiting_hint() {
  case $1 in
    ImagePullBackOff|ErrImagePull|InvalidImageName)
      echo "check image name/tag, registry reachability, imagePullSecrets" ;;
    CrashLoopBackOff)
      echo "container keeps exiting: see previous logs and exit code" ;;
    CreateContainerConfigError)
      echo "missing ConfigMap/Secret or key referenced by the pod" ;;
    CreateContainerError|RunContainerError)
      echo "runtime could not start the container: see events" ;;
    ContainerCreating)
      echo "stuck creating: volume mount, CNI or image pull in progress" ;;
    *) echo "" ;;
  esac
}

# ------------------------------------------------------------------ helpers
pj() { k -n "$NS" get pod "$1" -o jsonpath="$2"; }

check_ref() {  # kind name
  if k -n "$NS" get "$1" "$2" >/dev/null 2>&1; then echo "  ok       $1/$2"
  else warn "MISSING  $1/$2 (ignore if the reference is optional)"; fi
}

node_conditions() {
  local t s r m bad=0
  while IFS='|' read -r t s r m; do
    [[ -n $t ]] || continue
    if { [[ $t == Ready && $s != True ]] || [[ $t != Ready && $s == True ]]; }; then
      warn "$t=$s ${r:-} ${m:-}"; bad=1
    fi
  done < <(k get node "$1" -o jsonpath='{range .status.conditions[*]}{.type}|{.status}|{.reason}|{.message}{"\n"}{end}')
  (( bad )) || echo "  all node conditions healthy"
}

filter_unhealthy() {  # stdin: `kubectl get pods` table; $1 = 1 when -A adds a NAMESPACE column
  awk -v o="$1" -v rw="$RESTART_WARN" '
    NR==1 { h=$0; next }
    { st=$(3+o); split($(2+o), r, "/"); rs=$(4+o)+0
      if (st=="Completed") next
      if (st!="Running" || r[1]!=r[2] || rs>=rw) { if (!n++) print h; print } }
    END { if (!n) print "  (none)" }'
}

# ------------------------------------------------------------------ pod
diag_pod() {
  local pod=$1 node c name kind a b h found=0 x
  k -n "$NS" get pod "$pod" >/dev/null 2>&1 || die "pod $NS/$pod not found (check -n / --context)"

  hdr "Pod"
  k -n "$NS" get pod "$pod" -o wide
  pj "$pod" 'owner={.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}  qos={.status.qosClass}  phase={.status.phase}  reason={.status.reason}{"\n"}'

  hdr "Conditions"
  pj "$pod" '{range .status.conditions[*]}{.type}={.status}  {.reason}  {.message}{"\n"}{end}'

  node=$(pj "$pod" '{.spec.nodeName}')
  [[ -n $node ]] || warn "not scheduled to any node: see FailedScheduling events (resources, taints, affinity, PVC)"

  hdr "Containers"
  local frag='ready={.ready} restarts={.restartCount} waiting={.state.waiting.reason} terminated={.state.terminated.reason}/{.state.terminated.exitCode} last={.lastState.terminated.reason}/{.lastState.terminated.exitCode}{"\n"}'
  pj "$pod" "{range .status.initContainerStatuses[*]}init/{.name} ${frag}{end}{range .status.containerStatuses[*]}{.name} ${frag}{end}" |
    sed -E -e ':a' -e 's/ (waiting|terminated|last)=\/?( |$)/\2/' -e 'ta'

  hdr "Diagnosis hints"
  local per='{.name}{" waiting "}{.state.waiting.reason}{"\n"}{.name}{" last "}{.lastState.terminated.exitCode}{" "}{.lastState.terminated.reason}{"\n"}{.name}{" now "}{.state.terminated.exitCode}{" "}{.state.terminated.reason}{"\n"}'
  while read -r name kind a b; do
    [[ -n ${a:-} ]] || continue
    case $kind in
      waiting)
        h=$(waiting_hint "$a")
        [[ -n $h ]] && { warn "$name is waiting: $a -> $h"; found=1; } ;;
      last|now)
        [[ $a == 0 ]] && continue
        warn "$name $( [[ $kind == last ]] && echo 'last exited' || echo 'exited' ) with $a (${b:-no reason}) -> $(exit_hint "$a" "${b:-}")"
        found=1 ;;
    esac
  done < <(pj "$pod" "{range .status.initContainerStatuses[*]}${per}{end}{range .status.containerStatuses[*]}${per}{end}")
  (( found )) || echo "  no container-level failure detected"

  hdr "Referenced ConfigMaps / Secrets / PVCs"
  for x in $(pj "$pod" '{.spec.volumes[*].configMap.name} {.spec.containers[*].envFrom[*].configMapRef.name} {.spec.containers[*].env[*].valueFrom.configMapKeyRef.name} {.spec.initContainers[*].envFrom[*].configMapRef.name} {.spec.initContainers[*].env[*].valueFrom.configMapKeyRef.name}' | tr ' ' '\n' | sort -u); do
    check_ref configmap "$x"
  done
  for x in $(pj "$pod" '{.spec.volumes[*].secret.secretName} {.spec.containers[*].envFrom[*].secretRef.name} {.spec.containers[*].env[*].valueFrom.secretKeyRef.name} {.spec.initContainers[*].envFrom[*].secretRef.name} {.spec.initContainers[*].env[*].valueFrom.secretKeyRef.name}' | tr ' ' '\n' | sort -u); do
    check_ref secret "$x"
  done
  for x in $(pj "$pod" '{.spec.volumes[*].persistentVolumeClaim.claimName}' | tr ' ' '\n' | sort -u); do
    if ! k -n "$NS" get pvc "$x" --no-headers 2>/dev/null; then warn "MISSING  pvc/$x"; fi
  done

  hdr "Events"
  k -n "$NS" get events --field-selector "involvedObject.name=$pod" --sort-by=.lastTimestamp 2>&1 | tail -n 20

  hdr "Logs (last $TAIL lines)"
  local prev
  for c in $(pj "$pod" '{.spec.initContainers[*].name} {.spec.containers[*].name}'); do
    [[ -z $CONTAINER || $c == "$CONTAINER" ]] || continue
    echo "--- $c (current)"
    k -n "$NS" logs "$pod" -c "$c" --tail="$TAIL" 2>&1 | sed 's/^/    /'
    prev=$(k -n "$NS" logs "$pod" -c "$c" --previous --tail="$TAIL" 2>/dev/null)
    if [[ -n $prev ]]; then echo "--- $c (previous instance)"; printf '%s\n' "$prev" | sed 's/^/    /'; fi
  done

  if [[ -n $node ]]; then
    hdr "Node $node"
    node_conditions "$node"
  fi
}

# ------------------------------------------------------------------ node
diag_node() {
  local n=$1
  k get node "$n" >/dev/null 2>&1 || die "node $n not found (check --context)"
  hdr "Node";        k get node "$n" -o wide
  hdr "Conditions";  node_conditions "$n"
  hdr "Cordon / taints"
  k get node "$n" -o jsonpath='unschedulable={.spec.unschedulable}{"\n"}{range .spec.taints[*]}taint {.key}={.value}:{.effect}{"\n"}{end}'
  hdr "Allocated resources (requests vs allocatable)"
  k describe node "$n" | sed -n '/^Allocated resources:/,/^Events:/p' | sed '$d'
  hdr "Live usage (needs metrics-server)"
  k top node "$n" 2>&1
  hdr "Unhealthy pods on this node"
  k get pods -A --field-selector "spec.nodeName=$n" | filter_unhealthy 1
  hdr "Node events"
  k get events -A --field-selector "involvedObject.kind=Node,involvedObject.name=$n" --sort-by=.lastTimestamp 2>&1 | tail -n 15
  echo
  echo "Next (on the node): journalctl -u kubelet --since '30 min ago'; systemctl status kubelet containerd; crictl ps -a"
}

# ------------------------------------------------------------------ service
diag_svc() {
  local svc=$1 sel count
  k -n "$NS" get svc "$svc" >/dev/null 2>&1 || die "service $NS/$svc not found"
  hdr "Service"
  k -n "$NS" get svc "$svc" -o wide
  k -n "$NS" get svc "$svc" -o jsonpath='{range .spec.ports[*]}port={.port} targetPort={.targetPort} name={.name} protocol={.protocol}{"\n"}{end}'

  sel=$(k -n "$NS" get svc "$svc" -o go-template='{{range $k,$v := .spec.selector}}{{$k}}={{$v}},{{end}}')
  sel=${sel%,}

  hdr "Endpoints (from EndpointSlices)"
  local eps
  eps=$(k -n "$NS" get endpointslices -l "kubernetes.io/service-name=$svc" \
        -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]} ready={.conditions.ready} pod={.targetRef.name}{"\n"}{end}' 2>&1)
  if [[ -n $eps ]]; then echo "$eps"; else warn "no endpoints: nothing will receive traffic"; fi

  if [[ -z $sel ]]; then
    warn "service has no selector (ExternalName, headless or manually managed endpoints)"
    return
  fi

  hdr "Pods matching selector ($sel)"
  count=$(k -n "$NS" get pods -l "$sel" --no-headers 2>/dev/null | wc -l)
  if (( count == 0 )); then
    warn "no pods match the selector: check the service selector against pod labels"
  else
    k -n "$NS" get pods -l "$sel" -o wide
    hdr "Container ports (compare with targetPort)"
    k -n "$NS" get pods -l "$sel" -o jsonpath='{range .items[*]}{.metadata.name}: {range .spec.containers[*].ports[*]}{.name}={.containerPort} {end}{"\n"}{end}'
    echo
    echo "Pods matching but missing from endpoints are not Ready: check readiness probes."
  fi
}

# ------------------------------------------------------------------ namespace / cluster overview
diag_ns() {
  local scope=(-n "$NS") off=0 label="namespace $NS"
  if (( ALL )); then scope=(-A); off=1; label="all namespaces"; fi

  hdr "Nodes not Ready"
  k get nodes | awk 'NR==1{h=$0;next} $2!="Ready"{if(!n++)print h;print} END{if(!n)print "  (none)"}'

  hdr "Unhealthy pods ($label)"
  k get pods "${scope[@]}" | filter_unhealthy "$off"

  hdr "Deployments not fully ready"
  k get deploy "${scope[@]}" | awk -v o="$off" 'NR==1{h=$0;next} {split($(2+o),r,"/"); if(r[1]!=r[2]){if(!n++)print h;print}} END{if(!n)print "  (none)"}'

  hdr "PVCs not Bound"
  k get pvc "${scope[@]}" | awk -v o="$off" 'NR==1{h=$0;next} $(2+o)!="Bound"{if(!n++)print h;print} END{if(!n)print "  (none)"}'

  hdr "Recent Warning events (last 20)"
  k get events "${scope[@]}" --field-selector type=Warning --sort-by=.lastTimestamp 2>&1 | tail -n 20
}

# ------------------------------------------------------------------ main
command -v kubectl >/dev/null || die "kubectl not found in PATH"

cmd="${1:-}"
[[ -z $cmd || $cmd == -h || $cmd == --help ]] && usage 0
shift

target=""
while (($#)); do
  case $1 in
    -n|--namespace)      [[ $# -ge 2 ]] || die "$1 needs a value"; NS=$2; shift 2 ;;
    -A|--all-namespaces) ALL=1; shift ;;
    -c|--container)      [[ $# -ge 2 ]] || die "$1 needs a value"; CONTAINER=$2; shift 2 ;;
    --context)           [[ $# -ge 2 ]] || die "$1 needs a value"; CTX=$2; shift 2 ;;
    --tail)              [[ $# -ge 2 ]] || die "$1 needs a value"; TAIL=$2; shift 2 ;;
    -h|--help)           usage 0 ;;
    -*)                  die "unknown option: $1" ;;
    *)                   target=$1; shift ;;
  esac
done

if [[ -z $NS ]]; then
  NS=$(k config view --minify -o jsonpath='{..namespace}' 2>/dev/null)
  NS=${NS:-default}
fi

case $cmd in
  pod)         [[ -n $target ]] || die "usage: $0 pod <name> [-n ns]";  diag_pod "$target" ;;
  node)        [[ -n $target ]] || die "usage: $0 node <name>";         diag_node "$target" ;;
  svc|service) [[ -n $target ]] || die "usage: $0 svc <name> [-n ns]";  diag_svc "$target" ;;
  ns|overview) diag_ns ;;
  *)           usage 1 ;;
esac
