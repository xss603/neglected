# k9s Cheat Sheet

## Launch

| Command | Description |
|---|---|
| `k9s` | Open default context/namespace |
| `k9s -n <namespace>` | Open in a specific namespace |
| `k9s --context <ctx>` | Open with a specific kube context |
| `k9s --readonly` | Read-only mode (disables mutations) |
| `k9s --headless` | No header bar |

---

## Navigation

| Key | Description |
|---|---|
| `:` | Open command mode (type a resource, e.g. `:pod`, `:deploy`) |
| `/` | Filter/search the current list |
| `Esc` | Clear filter / go back |
| `Enter` | Drill into selected resource |
| `u` | Back up one level |
| `Ctrl+a` | Show all available resources (aliases) |
| `Tab` | Switch between panels |
| `?` | Show help / keybindings for current view |

### Common resource shortcuts (type after `:`)

| Alias | Resource |
|---|---|
| `po` | Pods |
| `dp` | Deployments |
| `rs` | ReplicaSets |
| `sts` | StatefulSets |
| `ds` | DaemonSets |
| `svc` | Services |
| `ing` | Ingresses |
| `cm` | ConfigMaps |
| `sec` | Secrets |
| `pv` | PersistentVolumes |
| `pvc` | PersistentVolumeClaims |
| `ns` | Namespaces |
| `no` | Nodes |
| `cj` | CronJobs |
| `job` | Jobs |
| `sa` | ServiceAccounts |
| `rb` | RoleBindings |
| `cr` | ClusterRoles |
| `ctx` | Contexts (switch kube context) |
| `hpa` | HorizontalPodAutoscalers |
| `ev` | Events |
| `wf` | Argo Workflows |
| `wft` | Argo WorkflowTemplates |
| `cwft` | Argo ClusterWorkflowTemplates |

---

## Pod actions (while a pod is selected)

| Key | Description |
|---|---|
| `l` | View logs |
| `s` | Shell into container (`exec -it`) |
| `d` | Describe resource (YAML-style summary) |
| `e` | Edit resource in `$KUBE_EDITOR` |
| `Ctrl+d` | Delete resource (confirmation required) |
| `Ctrl+k` | Kill (force delete) |
| `f` | Port-forward |
| `y` | View raw YAML |
| `x` | Decode secret values |

---

## Log viewer (after pressing `l`)

| Key | Description |
|---|---|
| `f` | Toggle full-screen |
| `w` | Toggle line wrap |
| `0`–`5` | Change log level filter (if structured logs) |
| `/` | Search log output |
| `n` / `p` | Next / previous search match |
| `s` | Save log to file |
| `Ctrl+s` | Toggle auto-scroll |
| `t` | Toggle timestamps |
| `c` | Copy selected line |
| `Esc` | Exit log view |

---

## Namespace & context switching

| Key / Command | Description |
|---|---|
| `:ns` | List and switch namespaces |
| `:ctx` | List and switch kube contexts |
| `Ctrl+Space` | Cycle through pinned namespaces |

---

## General keys (most views)

| Key | Description |
|---|---|
| `Ctrl+r` | Refresh current view |
| `g` | Jump to top of list |
| `G` | Jump to bottom of list |
| `k` / `↑` | Move up |
| `j` / `↓` | Move down |
| `Ctrl+f` | Page down |
| `Ctrl+b` | Page up |
| `q` / `Ctrl+c` | Quit k9s |

---

## Sorting & filtering

| Key | Description |
|---|---|
| `Shift+n` | Sort by name |
| `Shift+c` | Sort by CPU |
| `Shift+m` | Sort by memory |
| `Shift+r` | Sort by ready state |
| `Shift+a` | Sort by age |

---

## Benchmarking (HTTP)

| Key | Description |
|---|---|
| `Ctrl+b` | Run benchmark against a selected service |
| `:bench` | View benchmark results |

---

## Pulses / overview

| Command | Description |
|---|---|
| `:pulse` | Cluster pulse overview |
| `:xray po` | Xray view — shows pod → container tree |
| `:xray dp` | Xray view for Deployments |
| `:popeye` | Run Popeye linter (if installed) |

---

## Useful config locations

| Path | Description |
|---|---|
| `~/.config/k9s/config.yaml` | Main config (theme, refresh rate, log buffer, etc.) |
| `~/.config/k9s/hotkeys.yaml` | Custom hotkey definitions |
| `~/.config/k9s/aliases.yaml` | Custom resource aliases |
| `~/.config/k9s/plugins.yaml` | Plugin definitions |
| `~/.config/k9s/skins/` | Custom colour themes |

### Example: bump log buffer in `config.yaml`
```yaml
k9s:
  refreshRate: 2
  logBufferSize: 5000
  logRequestSize: 200
```

### Example: custom hotkey in `hotkeys.yaml`
```yaml
hotKeys:
  shift-0:
    shortCut: Shift-0
    description: View Argo Workflows
    command: wf
```

### Example: custom alias in `aliases.yaml`
```yaml
aliases:
  wf: workflows.argoproj.io
  wft: workflowtemplates.argoproj.io
```

---

## Tips

- **Multi-namespace view**: use `:po --all-namespaces` or launch with `-n ""`.
- **Read-only CI inspection**: `k9s --readonly` prevents accidental mutations.
- **Port-forward shortcut**: select a pod, press `f`, choose the port — k9s manages the tunnel.
- **Xray** shows resource ownership chains (Deployment → ReplicaSet → Pod) in one tree.
- **Popeye integration**: run `:popeye` for a live best-practice lint of the cluster.
