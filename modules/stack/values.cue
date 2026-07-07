package main

// values provides the defaults for all configurable fields.
// Override any field via --values my-values.yaml at apply time.
values: {
	toleration: {
		key:      "zone"
		operator: "Equal"
		value:    "local"
		effect:   "NoSchedule"
	}
	monitoring: {
		enabled:     true
		namespace:   "monitoring"
		helmRelease: "kube-prom"
		ingress: {
			enabled:   true
			className: "nginx"
			annotations: {}
		}
		grafana: {
			host:        "grafana.local"
			servicePort: 80
		}
		prometheus: {
			host:        "prometheus.local"
			servicePort: 9090
		}
		alertmanager: {
			host:        "alertmanager.local"
			servicePort: 9093
		}
		dashboards: {
			enabled:      true
			sidecarLabel: "grafana_dashboard"
			sidecarValue: "1"
		}
		helm: {
			grafanaAdminPassword:                    "admin"
			serviceMonitorSelectorNilUsesHelmValues: false
			podMonitorSelectorNilUsesHelmValues:     false
		}
	}
	minio: {
		enabled:   true
		namespace: "minio"
		instance1: {
			name:         "minio1"
			rootUser:     "minio1admin"
			rootPassword: "minio1secret"
			storage:      "2Gi"
			apiPort:      9000
			consolePort:  9001
			buckets: ["logs", "configs", "backups"]
		}
		instance2: {
			name:         "minio2"
			rootUser:     "minio2admin"
			rootPassword: "minio2secret"
			storage:      "2Gi"
			apiPort:      9000
			consolePort:  9001
			buckets: ["logs", "configs", "backups"]
		}
		migrate: {
			enabled: false
			image:   "minio/mc:latest"
			bucketPairs: [
				["logs",    "logs"],
				["configs", "configs"],
				["backups", "backups"],
			]
		}
	}
}
