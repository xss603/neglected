package templates

// #Monitoring builds all monitoring-stack Kubernetes objects from config.
#Monitoring: {
	_cfg: #Config

	// Derived service names from Helm release convention.
	_grafanaSvc:  "\(_cfg.monitoring.helmRelease)-grafana"
	_promSvc:     "\(_cfg.monitoring.helmRelease)-kube-prometheus-prometheus"
	_alertSvc:    "\(_cfg.monitoring.helmRelease)-kube-prometheus-alertmanager"

	_ingressAnnotations: {
		"nginx.ingress.kubernetes.io/rewrite-target": "/"
	} & _cfg.monitoring.ingress.annotations

	// ── Namespace ─────────────────────────────────────────────────────────────
	monitoring_namespace: {
		apiVersion: "v1"
		kind:       "Namespace"
		metadata: name: _cfg.monitoring.namespace
	}

	// ── Ingress objects (conditional on ingress.enabled) ──────────────────────
	if _cfg.monitoring.ingress.enabled {
		_ingressTLS: []
		if _cfg.monitoring.ingress.tls.enabled {
			_ingressTLS: [{
				hosts: [
					_cfg.monitoring.ingress.grafana.host,
					_cfg.monitoring.ingress.prometheus.host,
					_cfg.monitoring.ingress.alertmanager.host,
				]
				secretName: _cfg.monitoring.ingress.tls.secretName
			}]
		}

		ingress_grafana: {
			apiVersion: "networking.k8s.io/v1"
			kind:       "Ingress"
			metadata: {
				name:        "grafana"
				namespace:   _cfg.monitoring.namespace
				annotations: _ingressAnnotations
			}
			spec: {
				ingressClassName: _cfg.monitoring.ingress.className
				if _cfg.monitoring.ingress.tls.enabled { tls: _ingressTLS }
				rules: [{
					host: _cfg.monitoring.ingress.grafana.host
					http: paths: [{
						path:     "/"
						pathType: "Prefix"
						backend: service: {
							name: _grafanaSvc
							port: number: _cfg.monitoring.ingress.grafana.port
						}
					}]
				}]
			}
		}

		ingress_prometheus: {
			apiVersion: "networking.k8s.io/v1"
			kind:       "Ingress"
			metadata: {
				name:        "prometheus"
				namespace:   _cfg.monitoring.namespace
				annotations: _ingressAnnotations
			}
			spec: {
				ingressClassName: _cfg.monitoring.ingress.className
				if _cfg.monitoring.ingress.tls.enabled { tls: _ingressTLS }
				rules: [{
					host: _cfg.monitoring.ingress.prometheus.host
					http: paths: [{
						path:     "/"
						pathType: "Prefix"
						backend: service: {
							name: _promSvc
							port: number: _cfg.monitoring.ingress.prometheus.port
						}
					}]
				}]
			}
		}

		ingress_alertmanager: {
			apiVersion: "networking.k8s.io/v1"
			kind:       "Ingress"
			metadata: {
				name:        "alertmanager"
				namespace:   _cfg.monitoring.namespace
				annotations: _ingressAnnotations
			}
			spec: {
				ingressClassName: _cfg.monitoring.ingress.className
				if _cfg.monitoring.ingress.tls.enabled { tls: _ingressTLS }
				rules: [{
					host: _cfg.monitoring.ingress.alertmanager.host
					http: paths: [{
						path:     "/"
						pathType: "Prefix"
						backend: service: {
							name: _alertSvc
							port: number: _cfg.monitoring.ingress.alertmanager.port
						}
					}]
				}]
			}
		}
	}

	// ── Dashboard ConfigMaps (picked up by Grafana sidecar) ───────────────────
	if _cfg.monitoring.dashboards.enabled {
		_label: {"\(_cfg.monitoring.dashboards.sidecarLabel)": _cfg.monitoring.dashboards.sidecarValue}

		configmap_node_taint_monitor: {
			apiVersion: "v1"
			kind:       "ConfigMap"
			metadata: {
				name:      "node-taint-monitor-dashboard"
				namespace: _cfg.monitoring.namespace
				labels:    _label
			}
			data: "node-taint-monitor.json": "{}"
		}

		configmap_pod_ns_resources: {
			apiVersion: "v1"
			kind:       "ConfigMap"
			metadata: {
				name:      "pod-ns-resources-dashboard"
				namespace: _cfg.monitoring.namespace
				labels:    _label
			}
			data: "pod-namespace-resources.json": "{}"
		}

		configmap_chaos_dr: {
			apiVersion: "v1"
			kind:       "ConfigMap"
			metadata: {
				name:      "chaos-dr-monitor-dashboard"
				namespace: _cfg.monitoring.namespace
				labels:    _label
			}
			data: "chaos-dr-monitor.json": "{}"
		}
	}
}
