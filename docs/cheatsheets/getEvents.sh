# Calculate the ISO-8601 timestamp for 48 hours ago
THRESHOLD_TIME=$(date -u -d '48 hours ago' +%Y-%m-%dT%H:%M:%SZ)

# Fetch all events across namespaces, sort, and filter
kubectl get events -A -o json | jq -r --arg time "$THRESHOLD_TIME" '
  .items[] 
  | select((.lastTimestamp // .eventTime) > $time) 
  | select(.reason | ascii_downcase | contains("patch"))
  | [.lastTimestamp, .metadata.namespace, .involvedObject.kind, .involvedObject.name, .reason, .message] 
  | @tsv' | column -t -s $'\t'
