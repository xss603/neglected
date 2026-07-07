// values-override.cue — CUE-format override for the grafana-stack Timoni module.
//
// timoni v0.26.0 has a known bug where YAML/JSON --values files produce
// "undefined value" (see: https://github.com/stefanprodan/timoni/issues).
// Use this CUE file instead of values.yaml for actual timoni builds:
//
//   timoni build grafana-stack ./modules/stack --values values-override.cue
//   timoni apply grafana-stack ./modules/stack --values values-override.cue
//
// The canonical reference format is values.yaml (human-readable). This file
// mirrors it exactly in CUE syntax so both are kept in sync.

package main

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
			// Set to true to emit the migration Job (mc mirror instance1 → instance2).
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
