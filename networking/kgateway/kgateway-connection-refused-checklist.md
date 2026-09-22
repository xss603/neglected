# Kgateway — Troubleshooting ERR_CONNECTION_REFUSED

## Contexte
- Gateway: OK (pod + VIP générés)
- HttpRoute: OK (attaché)
- GatewayParameters: OK
- Backend (svc + deployment): OK
- Symptôme: `ERR_CONNECTION_REFUSED` côté client

Le control-plane (K8s Gateway API) est propre → le problème est réseau (L3/L4) ou binding Envoy.

---

## 1. Vérifier le Service du Gateway (pas le backend)

```bash
kubectl get svc -n <gw-ns> -o wide
```

Points à valider :
- `TYPE` = `LoadBalancer` (ou `NodePort` selon cloud/on-prem)
- `EXTERNAL-IP` != `<pending>`
- Le port exposé correspond au listener déclaré dans le `Gateway`

```bash
kubectl get gateway <gw-name> -n <gw-ns> -o yaml | grep -A5 listeners
```

---

## 2. Vérifier les Endpoints (pod Gateway Ready ?)

```bash
kubectl get endpoints -n <gw-ns> <gateway-svc-name>
kubectl get pods -n <gw-ns> -o wide -l gateway.networking.k8s.io/gateway-name=<gw-name>
```

Si `ENDPOINTS` vide → le pod Envoy n'est pas Ready.

```bash
kubectl describe pod -n <gw-ns> <gateway-pod-name> | grep -A10 "Readiness\|Events"
kubectl logs -n <gw-ns> <gateway-pod-name> --tail=100
```

---

## 3. Test interne (bypass LB/firewall)

Script de diagnostic rapide :

```bash
#!/usr/bin/env bash
set -euo pipefail
NS="<gw-ns>"
GW_SVC="<gateway-svc-name>"
PORT="<listener-port>"

CLUSTER_IP=$(kubectl get svc -n "$NS" "$GW_SVC" -o jsonpath='{.spec.clusterIP}')
echo ">> ClusterIP: $CLUSTER_IP:$PORT"

kubectl run debug-curl --rm -it --restart=Never \
  --image=curlimages/curl -n "$NS" -- \
  curl -v --max-time 5 "http://${CLUSTER_IP}:${PORT}/"
```

Résultats :

| ClusterIP | NodePort | LB externe | Diagnostic |
|---|---|---|---|
| OK | OK | KO | Firewall/SG cloud ou LB health-check KO |
| OK | KO | KO | kube-proxy / NetworkPolicy / iptables |
| KO | KO | KO | Envoy ne bind pas le port (GatewayParameters) |

---

## 3bis. Test via NodePort (bypass LoadBalancer cloud)

Utile pour isoler si le problème vient du LB cloud ou du cluster lui-même.

```bash
#!/usr/bin/env bash
set -euo pipefail
NS="<gw-ns>"
GW_SVC="<gateway-svc-name>"

# Récupérer le NodePort assigné (si svc type LoadBalancer, K8s alloue aussi un NodePort)
NODE_PORT=$(kubectl get svc -n "$NS" "$GW_SVC" -o jsonpath='{.spec.ports[0].nodePort}')
echo ">> NodePort: $NODE_PORT"

# Récupérer une IP de node (interne ou externe selon accès)
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo ">> Node IP: $NODE_IP"

curl -v --max-time 5 "http://${NODE_IP}:${NODE_PORT}/"
```

Résultat :
- **OK sur NodePort, KO sur LB externe** → problème 100% côté LB cloud (SG/firewall/health-check LB) ou provisioning.
- **KO même sur NodePort** → problème cluster (kube-proxy, NetworkPolicy, ou Envoy ne bind pas — voir section 4).

⚠️ Si `NetworkPolicy` restrictive sur le namespace, penser à vérifier qu'elle autorise le trafic entrant depuis les nodes :

```bash
kubectl get networkpolicy -n "$NS" -o yaml
```

---

## 3ter. Test avec curl --resolve (bypass DNS, force l'IP du LB)

Permet de tester le vhost/SNI/routing exact sans dépendre du DNS (cache, propagation, split-horizon).

```bash
LB_IP=$(kubectl get svc -n <gw-ns> <gateway-svc-name> \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# HTTP simple
curl -v --resolve <votre-domaine>:80:${LB_IP} \
  "http://<votre-domaine>/" --max-time 5

# HTTPS avec vérif SNI/TLS (utile si HttpRoute matche sur Host header)
curl -v --resolve <votre-domaine>:443:${LB_IP} \
  "https://<votre-domaine>/" --max-time 5 -k
```

Cas d'usage :
- Confirme que le routing par `Host` header dans `HttpRoute` fonctionne indépendamment du DNS.
- Si `--resolve` fonctionne mais l'URL normale échoue → **problème DNS pur** (cache local, TTL, résolveur).
- Si `--resolve` échoue aussi → confirme un problème LB/Envoy (retour à sections 1-4).

---

## 4. Vérifier le binding réel d'Envoy

```bash
kubectl exec -n <gw-ns> <gateway-pod-name> -- ss -tlnp
```

Le port du listener doit apparaître en `LISTEN`. Sinon, comparer :

```bash
kubectl get gatewayparameters -n <gw-ns> <gwp-name> -o yaml | grep -A10 "service:\|ports:"
```

→ Mismatch fréquent entre `Gateway.spec.listeners[].port` et `GatewayParameters.spec.kube.service.ports`.

---

## 5. Firewall / Security Group cloud (cause n°1 en prod)

- **GCP** : `gcloud compute firewall-rules list --filter="name~<lb-name>"`
- **AWS** : vérifier le Security Group attaché au NLB/ALB (port ingress ouvert 0.0.0.0/0 ou IP autorisée)
- **Azure** : NSG associé au Load Balancer

```bash
# AWS exemple
aws ec2 describe-security-groups --group-ids <sg-id> \
  --query 'SecurityGroups[0].IpPermissions'
```

---

## 6. DNS — vérifier la résolution réelle

```bash
dig +short <votre-url>
nslookup <votre-url>
kubectl get svc -n <gw-ns> <gateway-svc-name> -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Comparer l'IP résolue par DNS vs l'`EXTERNAL-IP` actuel (cache DNS obsolète = cause fréquente après recréation du LB).

---

## 7. Checklist de validation finale

```bash
# 1. Gateway status
kubectl get gateway <gw-name> -n <gw-ns> -o jsonpath='{.status.conditions}' | jq

# 2. HTTPRoute status
kubectl get httproute <route-name> -n <gw-ns> -o jsonpath='{.status.parents}' | jq

# 3. Full state dump
kubectl get svc,ep,pods -n <gw-ns> -o wide
```

---

## Rollback / Reset propre

```bash
kubectl rollout restart deploy -n <gw-ns> <gateway-deployment-name>
kubectl wait --for=condition=Ready pod -l gateway.networking.k8s.io/gateway-name=<gw-name> -n <gw-ns> --timeout=60s
```

---

## Causes les plus fréquentes (par ordre de probabilité)

- Firewall/SG cloud bloquant le port du LB
- Mismatch port listener Gateway ↔ port Service (GatewayParameters)
- Readiness probe Envoy en échec (pod non Ready → endpoints vides)
- DNS pointant vers une ancienne IP après recréation du LB
- EXTERNAL-IP encore `<pending>` (quota LB cloud atteint)
