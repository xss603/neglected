# Prometheus / Grafana cheat sheet — node taint monitoring

## Taint variables (kube-state-metrics)

| Purpose | Query |
|---------|-------|
| Taint key list | `label_values(kube_node_spec_taint, key)` |
| Taint value list filtered by key | `label_values(kube_node_spec_taint{key="$taint_key"}, value)` |
| Effect list for key+value | `label_values(kube_node_spec_taint{key="$taint_key",value="$taint_value"}, effect)` |
| Nodes matching a taint (hidden variable) | `label_values(kube_node_spec_taint{key="$taint_key",value="$taint_value"}, node)` |
| Map node name → node-exporter instance | `label_values(node_uname_info{nodename=~"$tainted_nodes"}, instance)` |

> `tainted_nodes` — set `allValue: .*` and hide this variable. It feeds all resource panels via `=~` matchers.

---

## CPU (node-exporter)

```promql
# Usage % per node
1 - avg by(instance)(
  rate(node_cpu_seconds_total{mode="idle",instance=~"$node_instance"}[$__rate_interval])
)

# iowait %
rate(node_cpu_seconds_total{mode="iowait",instance=~"$node_instance"}[$__rate_interval])

# CPU core count
count by(instance)(node_cpu_seconds_total{mode="idle",instance=~"$node_instance"})
```

---

## Memory (node-exporter)

```promql
# Usage %
1 - (
  node_memory_MemAvailable_bytes{instance=~"$node_instance"}
  / node_memory_MemTotal_bytes{instance=~"$node_instance"}
)

# Used bytes
node_memory_MemTotal_bytes{instance=~"$node_instance"}
- node_memory_MemAvailable_bytes{instance=~"$node_instance"}

# Total bytes
node_memory_MemTotal_bytes{instance=~"$node_instance"}
```

---

## Disk (node-exporter)

```promql
# Usage % (root fs)
1 - (
  node_filesystem_avail_bytes{instance=~"$node_instance",mountpoint="/",fstype!="tmpfs"}
  / node_filesystem_size_bytes{instance=~"$node_instance",mountpoint="/",fstype!="tmpfs"}
)

# Read bytes/s
rate(node_disk_read_bytes_total{instance=~"$node_instance"}[$__rate_interval])

# Write bytes/s
rate(node_disk_written_bytes_total{instance=~"$node_instance"}[$__rate_interval])
```

---

## Network (node-exporter)

```promql
# Receive bytes/s
rate(node_network_receive_bytes_total{instance=~"$node_instance",device!="lo"}[$__rate_interval])

# Transmit bytes/s
rate(node_network_transmit_bytes_total{instance=~"$node_instance",device!="lo"}[$__rate_interval])
```

---

## Pod & capacity (kube-state-metrics)

```promql
# Pod count on tainted nodes
count by(node)(kube_pod_info{node=~"$tainted_nodes"})

# Pod capacity used %
count by(node)(kube_pod_info{node=~"$tainted_nodes"})
/ sum by(node)(kube_node_status_capacity{node=~"$tainted_nodes",resource="pods"})

# CPU requests vs allocatable
sum by(node)(kube_pod_container_resource_requests{node=~"$tainted_nodes",resource="cpu"})
/ sum by(node)(kube_node_status_allocatable{node=~"$tainted_nodes",resource="cpu"})

# Memory requests vs allocatable
sum by(node)(kube_pod_container_resource_requests{node=~"$tainted_nodes",resource="memory"})
/ sum by(node)(kube_node_status_allocatable{node=~"$tainted_nodes",resource="memory"})
```

---

## Node conditions & status (kube-state-metrics)

```promql
# Node ready (value=1 means Ready)
kube_node_status_condition{condition="Ready",status="true",node=~"$tainted_nodes"}

# Pressure conditions (alert when value=1)
kube_node_status_condition{
  condition=~"MemoryPressure|DiskPressure|PIDPressure",
  status="true",
  node=~"$tainted_nodes"
}

# All taints on all nodes (use instant + format=table → labelsToFields transform)
kube_node_spec_taint
```

---

## Grafana variable patterns

### Variable chain for taint filtering

```
taint_key    → label_values(kube_node_spec_taint, key)
taint_value  → label_values(kube_node_spec_taint{key="$taint_key"}, value)
taint_effect → label_values(kube_node_spec_taint{key="$taint_key",value="$taint_value"}, effect)
tainted_nodes (hidden) → label_values(kube_node_spec_taint{key="$taint_key",value="$taint_value"}, node)
node_instance (hidden) → label_values(node_uname_info{nodename=~"$tainted_nodes"}, instance)
```

### Key tips

| Topic | Rule |
|-------|------|
| `$__rate_interval` vs `$__interval` | Always use `$__rate_interval` for `rate()`/`increase()` — auto-adjusts to scrape interval × 4 |
| Multi-value variable regex | Set `allValue: .*` so "All" emits `.*` for `=~` matchers |
| node name → instance bridge | `kube_node_spec_taint` uses `node` label; node-exporter uses `instance`. Bridge with `node_uname_info{nodename=~"$tainted_nodes"}` |
| Table panels | Enable **Instant** toggle — returns one row per series instead of samples over time |
| Instant vs time series | Instant → table/stat/gauge. Time series → timeseries panel |
| `label_values` scope | Add a `match[]` metric to scope label discovery, e.g. `label_values(kube_node_spec_taint{key="zone"}, value)` |
