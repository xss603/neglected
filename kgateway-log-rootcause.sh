#!/usr/bin/env bash
# kgateway-log-rootcause.sh
# Capture N secondes de logs controller + envoy, puis les parse pour isoler
# la root cause d'une URL qui repond ERR_CONNECTION_REFUSED.
#
# Usage: ./kgateway-log-rootcause.sh <controller-ns> <controller-pod> <gw-ns> <gw-pod> [duration_sec]
#
# Env vars optionnelles:
#   ENVOY_CONTAINER   force le nom du container Envoy (sinon auto-detecte)
#   CTRL_CONTAINER    force le nom du container controller (sinon defaut du pod)
#
# Changelog vs. version precedente (bugs reels corriges, details dans le
# fichier de review associe):
#   - `--since=0s` remplace par `--since-time=<now>`: kubectl ignore une duree
#     nulle et rapatriait TOUT l'historique du buffer, pas la fenetre demandee.
#     Toutes les conclusions "pendant la fenetre" etaient donc fausses.
#   - `-c envoy` en dur remplace par une auto-detection + validation: si le nom
#     etait faux, l'erreur kubectl atterrissait dans envoy.log via `2>&1` et
#     TOUTES les sections Envoy affichaient CLEAN sur un fichier qui ne
#     contenait aucun log (faux negatif total).
#   - stderr separe de stdout (plus de pollution des greps).
#   - trap EXIT: plus de `kubectl logs -f` orphelins sur Ctrl-C.
#   - restartCount lu depuis l'API (fiable) au lieu de grep "caught signal".
#   - logs `--previous` recuperes si le pod a redemarre: sur un crashloop la
#     cause est dans le container precedent, jamais dans le courant.
#   - NEW: histogramme des RESPONSE_FLAGS Envoy (NR/UH/UF/NC/UT...) - le signal
#     le plus diagnostique des access logs, absent de la version precedente.
#   - NEW: test decisif "Envoy a-t-il vu passer LA MOINDRE requete ?" - pour un
#     ERR_CONNECTION_REFUSED client c'est LE branchement qui tranche entre
#     "trafic n'atteint jamais Envoy" et "Envoy repond mais mal".
#   - verdict final pondere et oriente connection-refused, au lieu d'un simple
#     compteur de categories.
#   - plus de `declare -A` (bash 3.2 / macOS compatible).

set -uo pipefail

usage(){ sed -n '2,12p' "$0"; exit "${1:-0}"; }
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage 0

CTRL_NS="${1:?controller namespace}"
CTRL_POD="${2:?controller pod name}"
GW_NS="${3:?gateway namespace}"
GW_POD="${4:?gateway/envoy pod name}"
DURATION="${5:-180}"

command -v kubectl >/dev/null 2>&1 || { echo "kubectl introuvable" >&2; exit 2; }

OUTDIR="/tmp/kgw-logs-$(date +%s)"
mkdir -p "$OUTDIR"

RED="\033[31m"; YEL="\033[33m"; GRN="\033[32m"; BLU="\033[34m"; NC="\033[0m"
hit(){   echo -e "${RED}[HIT]${NC} $1"; }
info(){  echo -e "${YEL}[INFO]${NC} $1"; }
clean(){ echo -e "${GRN}[CLEAN]${NC} $1"; }
step(){  echo -e "\n${BLU}--- $1 ---${NC}"; }

CTRL_PID=""; ENVOY_PID=""
cleanup(){
  [[ -n "$CTRL_PID"  ]] && kill "$CTRL_PID"  2>/dev/null
  [[ -n "$ENVOY_PID" ]] && kill "$ENVOY_PID" 2>/dev/null
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 0. Pre-flight: les pods existent, et on resout le vrai nom du container Envoy
# ---------------------------------------------------------------------------
echo "=== 0. Pre-flight ==="

kubectl get pod -n "$CTRL_NS" "$CTRL_POD" >/dev/null 2>&1 \
  || { hit "Pod controller $CTRL_POD introuvable dans $CTRL_NS"; exit 1; }
kubectl get pod -n "$GW_NS" "$GW_POD" >/dev/null 2>&1 \
  || { hit "Pod gateway $GW_POD introuvable dans $GW_NS"; exit 1; }

GW_CONTAINERS=$(kubectl get pod -n "$GW_NS" "$GW_POD" -o jsonpath='{.spec.containers[*].name}')
echo "Containers du pod gateway: $GW_CONTAINERS"

if [[ -n "${ENVOY_CONTAINER:-}" ]]; then
  ENVOY_C="$ENVOY_CONTAINER"
else
  # kgateway nomme ce container differemment selon la version/chart
  ENVOY_C=""
  for cand in envoy envoy-wrapper kgateway-proxy proxy gateway-proxy; do
    if echo " $GW_CONTAINERS " | grep -q " $cand "; then ENVOY_C="$cand"; break; fi
  done
  # fallback: premier container du pod
  [[ -z "$ENVOY_C" ]] && ENVOY_C=$(echo "$GW_CONTAINERS" | awk '{print $1}')
fi
clean "Container Envoy retenu: $ENVOY_C (override possible via \$ENVOY_CONTAINER)"

CTRL_C_ARG=()
[[ -n "${CTRL_CONTAINER:-}" ]] && CTRL_C_ARG=(-c "$CTRL_CONTAINER")

# Restart counts: bien plus fiable qu'un grep "caught signal" dans les logs
GW_RESTARTS=$(kubectl get pod -n "$GW_NS" "$GW_POD" \
  -o jsonpath="{.status.containerStatuses[?(@.name=='$ENVOY_C')].restartCount}" 2>/dev/null)
GW_RESTARTS="${GW_RESTARTS:-0}"
CTRL_RESTARTS=$(kubectl get pod -n "$CTRL_NS" "$CTRL_POD" \
  -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
CTRL_RESTARTS="${CTRL_RESTARTS:-0}"

[[ "$GW_RESTARTS"   -gt 0 ]] && hit "Envoy a redemarre $GW_RESTARTS fois"        || clean "Envoy: 0 restart"
[[ "$CTRL_RESTARTS" -gt 0 ]] && hit "Controller a redemarre $CTRL_RESTARTS fois" || clean "Controller: 0 restart"

# Sur un crashloop, la cause est dans le container PRECEDENT, pas le courant.
if [[ "$GW_RESTARTS" -gt 0 ]]; then
  kubectl logs -n "$GW_NS" "$GW_POD" -c "$ENVOY_C" --previous --tail=100 \
    > "$OUTDIR/envoy.previous.log" 2>/dev/null \
    && info "Logs du container Envoy precedent: $OUTDIR/envoy.previous.log"
fi

# ---------------------------------------------------------------------------
# 1. Capture de la fenetre
# ---------------------------------------------------------------------------
# BUG CORRIGE: `--since=0s` etait ignore par kubectl (duree nulle == non
# positionnee) et rapatriait tout l'historique. On ancre sur un timestamp reel.
START_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo
echo ">> Capture ${DURATION}s a partir de $START_TS"
echo ">> Controller: $CTRL_POD ($CTRL_NS) | Envoy: $GW_POD ($GW_NS, container=$ENVOY_C)"
info "Genere du trafic vers l'URL en panne MAINTENANT pour qu'il tombe dans la fenetre."

timeout "$((DURATION+5))" kubectl logs -n "$CTRL_NS" "$CTRL_POD" "${CTRL_C_ARG[@]+"${CTRL_C_ARG[@]}"}" \
  -f --since-time="$START_TS" > "$OUTDIR/controller.log" 2>"$OUTDIR/controller.stderr" &
CTRL_PID=$!
timeout "$((DURATION+5))" kubectl logs -n "$GW_NS" "$GW_POD" -c "$ENVOY_C" \
  -f --since-time="$START_TS" > "$OUTDIR/envoy.log" 2>"$OUTDIR/envoy.stderr" &
ENVOY_PID=$!

for ((i=DURATION; i>0; i-=10)); do
  printf "\r>> %ds restantes...   " "$i"
  sleep $(( i > 10 ? 10 : i ))
done
printf "\r>> Capture terminee.        \n"

kill "$CTRL_PID" "$ENVOY_PID" 2>/dev/null
wait "$CTRL_PID" "$ENVOY_PID" 2>/dev/null
CTRL_PID=""; ENVOY_PID=""

# Validation: un stderr non vide veut dire que kubectl a echoue, et donc que
# les greps qui suivent tourneraient sur un fichier vide -> faux "CLEAN".
for pair in "controller:$OUTDIR/controller" "envoy:$OUTDIR/envoy"; do
  name="${pair%%:*}"; base="${pair#*:}"
  if [[ -s "${base}.stderr" ]]; then
    hit "kubectl logs a echoue pour $name - les sections $name ci-dessous ne sont PAS fiables:"
    sed 's/^/    /' "${base}.stderr" | head -5
  elif [[ ! -s "${base}.log" ]]; then
    info "Aucune ligne de log $name sur la fenetre (pod silencieux, ou verbosite trop basse)"
  else
    clean "$name: $(wc -l < "${base}.log") lignes capturees"
  fi
done

echo
echo "================= ANALYSE ================="

# scan <fichier> <sortie> <regex> <label> <explication>
scan(){
  local src="$1" out="$2" re="$3" label="$4" why="$5"
  [[ -f "$src" ]] || { info "$label: source absente"; return 1; }
  grep -iE "$re" "$src" > "$out" 2>/dev/null
  if [[ -s "$out" ]]; then
    hit "$label ($(wc -l < "$out") ligne(s)) - $why"
    head -10 "$out" | sed 's/^/    /'
    return 0
  else
    clean "$label: rien"
    return 1
  fi
}

FINDINGS=""
note(){ FINDINGS="${FINDINGS}$1"$'\n'; }

step "1. Controller: erreurs de reconciliation / push xDS"
# -A2 pour garder le contexte: un `panic:` seul n'a jamais les mots-cles
# gateway/httproute sur la MEME ligne, l'ancien double-grep les perdait.
grep -iE -A2 "error|failed|reject|invalid|panic" "$OUTDIR/controller.log" 2>/dev/null \
  | grep -iE -B1 -A1 "gateway|httproute|gatewayparameters|xds|snapshot|listener" \
  > "$OUTDIR/ctrl_errors.txt" 2>/dev/null
if [[ -s "$OUTDIR/ctrl_errors.txt" ]]; then
  hit "Erreurs controller ($(wc -l < "$OUTDIR/ctrl_errors.txt") lignes)"
  head -20 "$OUTDIR/ctrl_errors.txt" | sed 's/^/    /'
  note "controller-errors"
else
  clean "Aucune erreur de reconciliation cote controller"
fi

step "2. Controller: rejets de config (status conditions negatives)"
scan "$OUTDIR/controller.log" "$OUTDIR/ctrl_rejects.txt" \
  "ResolvedRefs.*[Ff]alse|Accepted.*[Ff]alse|Programmed.*[Ff]alse|backendRef.*not found|no matching (route|listener)|refused to bind" \
  "Config rejetee par le controller" \
  "le controller refuse de programmer cette config" && note "controller-reject"

step "3. RBAC controller (ne peut pas watch les ressources)"
scan "$OUTDIR/controller.log" "$OUTDIR/ctrl_rbac_errors.txt" \
  "forbidden|unauthorized|cannot list|cannot watch|cannot get|is not allowed" \
  "Erreurs RBAC controller" \
  "le controller ne voit pas une ressource -> traduction silencieusement incomplete, status vert malgre tout" \
  && note "rbac"

step "4. Version mismatch CRD / controller"
scan "$OUTDIR/controller.log" "$OUTDIR/ctrl_version_errors.txt" \
  "unknown field|failed to decode|unmarshal.*error|schema.*mismatch|no kind.*registered|no matches for kind" \
  "Indices de version mismatch CRD/controller" \
  "CRDs et controller desynchronises" && note "crd-mismatch"

step "5. Envoy: echec de bind socket (cause DIRECTE d'un connection refused)"
scan "$OUTDIR/envoy.log" "$OUTDIR/envoy_bind_errors.txt" \
  "bind.*fail|address already in use|cannot bind|error adding listener|failed to add listener|permission denied.*bind" \
  "Echec de bind socket Envoy" \
  "Envoy n'ecoute pas sur le port -> tout client recoit un RST immediat" \
  && note "bind-failure"

step "6. Envoy: NACK xDS (LDS/RDS/CDS/EDS rejetes)"
scan "$OUTDIR/envoy.log" "$OUTDIR/envoy_xds_errors.txt" \
  "gRPC config stream|NACK|rejected.*resource|rejecting|lds.*(error|reject)|cds.*(error|reject)|rds.*(error|reject)|eds.*(error|reject)" \
  "NACK xDS Envoy" \
  "Envoy refuse la config poussee par le controller -> ancienne config (ou aucune) reste active" \
  && note "xds-nack"

step "7. Envoy: upstream / cluster unhealthy"
scan "$OUTDIR/envoy.log" "$OUTDIR/envoy_upstream_errors.txt" \
  "upstream connect error|no healthy upstream|no cluster|failed_outlier_check|host.*unhealthy|upstream reset" \
  "Problemes upstream/backend" \
  "Envoy accepte bien la connexion mais n'atteint pas le backend" \
  && note "upstream"

step "8. Envoy: histogramme des RESPONSE_FLAGS (access logs)"
# Les response flags sont le signal le plus diagnostique des access logs Envoy.
# On restreint aux lignes qui ressemblent vraiment a un access log pour limiter
# les faux positifs sur des mots isoles.
grep -E 'HTTP/[0-9]' "$OUTDIR/envoy.log" 2>/dev/null > "$OUTDIR/envoy_access.log"
ACCESS_COUNT=$(wc -l < "$OUTDIR/envoy_access.log" 2>/dev/null || echo 0)
if [[ "$ACCESS_COUNT" -gt 0 ]]; then
  clean "$ACCESS_COUNT ligne(s) d'access log capturee(s)"
  echo "  Flags observes:"
  grep -oE '\b(NR|UH|UF|UO|NC|UT|URX|DC|SI|RL|DPE|LH|UAEX|LR|UPE)\b' "$OUTDIR/envoy_access.log" \
    | sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'
  echo "    NR=no route configured | NC=no cluster | UH=no healthy upstream"
  echo "    UF=upstream connect fail | UT=upstream timeout | DC=downstream disconnect"
else
  info "Aucun access log Envoy sur la fenetre"
fi

step "9. TEST DECISIF: Envoy a-t-il vu passer la moindre requete ?"
# Pour un ERR_CONNECTION_REFUSED cote client, c'est LE branchement qui tranche.
if [[ "$ACCESS_COUNT" -gt 0 ]]; then
  hit "Envoy A RECU du trafic pendant la fenetre."
  info "=> Le refus n'est donc PAS 'rien n'ecoute': la connexion TCP arrive"
  info "   jusqu'a Envoy. Un ERR_CONNECTION_REFUSED cote navigateur vient alors"
  info "   d'un AUTRE chemin (mauvaise IP/port, LB qui ne pointe pas sur ce"
  info "   Gateway, ou un second listener). Comparer avec les flags section 8."
  note "envoy-received-traffic"
else
  hit "Envoy n'a vu AUCUNE requete pendant ${DURATION}s."
  info "=> Si du trafic a bien ete genere vers l'URL: il n'atteint jamais Envoy."
  info "   Root cause en AMONT du pod: DNS, VIP/LB, firewall/SG cloud,"
  info "   NetworkPolicy, ou Service sans endpoint. Les logs applicatifs ne"
  info "   diront rien de plus - passer sur kgateway-healthcheck.sh sections"
  info "   10 (NodePort) et 11 (DNS vs EXTERNAL-IP)."
  note "envoy-no-traffic"
fi

step "10. Crash / arret d'Envoy pendant la fenetre"
CRASH_COUNT=$(grep -ciE "caught.*signal|terminating|fatal error|core dumped|panic" "$OUTDIR/envoy.log" 2>/dev/null || echo 0)
if [[ "$CRASH_COUNT" -gt 0 ]]; then
  hit "$CRASH_COUNT indice(s) de crash Envoy dans la fenetre"
  note "envoy-crash"
elif [[ "$GW_RESTARTS" -gt 0 ]]; then
  info "Aucun crash dans la fenetre, mais restartCount=$GW_RESTARTS -> voir $OUTDIR/envoy.previous.log"
else
  clean "Pas de crash detecte"
fi

# ---------------------------------------------------------------------------
# Verdict pondere, oriente ERR_CONNECTION_REFUSED
# ---------------------------------------------------------------------------
echo
echo "================= VERDICT ================="
has(){ echo "$FINDINGS" | grep -q "^$1$"; }

if has "bind-failure"; then
  hit "ROOT CAUSE #1: Envoy n'a pas reussi a binder son socket."
  echo "  -> Le port declare dans le Gateway n'est pas ouvert dans le pod."
  echo "  -> Verifier Gateway.spec.listeners[].port vs GatewayParameters container port,"
  echo "     et un eventuel conflit de port entre deux listeners."
elif has "envoy-no-traffic" && ! has "xds-nack" && ! has "controller-errors"; then
  hit "ROOT CAUSE #1: le trafic n'atteint jamais Envoy, et Envoy va bien."
  echo "  -> Chercher en amont: DNS -> VIP/LB -> firewall/SG -> Service/endpoints."
  echo "  -> Les logs sont un cul-de-sac ici; c'est un probleme de chemin reseau."
elif has "rbac"; then
  hit "ROOT CAUSE #1: RBAC insuffisant sur le controller."
  echo "  -> Cas vicieux: Gateway et HTTPRoute affichent Accepted/ResolvedRefs=True"
  echo "     alors que rien n'a ete traduit vers Envoy."
elif has "xds-nack"; then
  hit "ROOT CAUSE #1: Envoy rejette (NACK) la config poussee."
  echo "  -> Envoy tourne sur son ancienne config, ou sur aucune."
elif has "crd-mismatch"; then
  hit "ROOT CAUSE #1: CRDs et controller desynchronises."
elif has "controller-reject" || has "controller-errors"; then
  hit "ROOT CAUSE #1: le controller refuse/echoue a programmer la config."
elif has "upstream"; then
  info "Erreurs upstream uniquement: Envoy accepte les connexions et repond."
  echo "  -> Un ERR_CONNECTION_REFUSED client ne s'explique PAS par ca."
  echo "     Un backend KO donne un 503 HTTP, pas un refus TCP. Chercher ailleurs."
else
  info "Aucun pattern d'erreur connu sur ${DURATION}s."
  echo "  -> Root cause probablement hors logs: firewall/SG cloud, DNS,"
  echo "     NetworkPolicy, ou LB mal cable."
  echo "  -> Enchainer sur ./kgateway-healthcheck.sh <ns> <gw> <domaine>"
fi

echo
echo "Artefacts: $OUTDIR/"
ls -1 "$OUTDIR" | sed 's/^/  /'
