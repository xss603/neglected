package templates

// _monitoringObjects returns a struct of monitoring Kubernetes resources derived from config.
// Fields are conditionally present based on enabled flags.
#Monitoring: {
	_cfg: #Config

	// Derived service names from Helm release convention
	_grafanaSvc:      "\(_cfg.monitoring.helmRelease)-grafana"
	_promSvc:         "\(_cfg.monitoring.helmRelease)-kube-prometheus-prometheus"
	_alertSvc:        "\(_cfg.monitoring.helmRelease)-kube-prometheus-alertmanager"

	_ingressAnnotations: {
		"nginx.ingress.kubernetes.io/rewrite-target": "/"
	} & _cfg.monitoring.ingress.annotations

	// Namespace
	monitoring_namespace: {
		apiVersion: "v1"
		kind:       "Namespace"
		metadata: name: _cfg.monitoring.namespace
	}

	// Ingress objects — present only when ingress.enabled
	if _cfg.monitoring.ingress.enabled {
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
				rules: [{
					host: _cfg.monitoring.grafana.host
					http: paths: [{
						path:     "/"
						pathType: "Prefix"
						backend: service: {
							name: _grafanaSvc
							port: number: _cfg.monitoring.grafana.servicePort
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
				rules: [{
					host: _cfg.monitoring.prometheus.host
					http: paths: [{
						path:     "/"
						pathType: "Prefix"
						backend: service: {
							name: _promSvc
							port: number: _cfg.monitoring.prometheus.servicePort
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
				rules: [{
					host: _cfg.monitoring.alertmanager.host
					http: paths: [{
						path:     "/"
						pathType: "Prefix"
						backend: service: {
							name: _alertSvc
							port: number: _cfg.monitoring.alertmanager.servicePort
						}
					}]
				}]
			}
		}
	}

	// Dashboard ConfigMaps — present only when dashboards.enabled
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
