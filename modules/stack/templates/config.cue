package templates

// #Config is the full schema for user-provided values.
// Every field has a default so the module is usable without any --values override.
#Config: {
	toleration: {
		key:      string | *"zone"
		operator: string | *"Equal"
		value:    string | *"local"
		effect:   string | *"NoSchedule"
	}

	monitoring: {
		enabled:     bool | *true
		namespace:   string | *"monitoring"
		helmRelease: string | *"kube-prom"

		ingress: {
			enabled:   bool | *true
			className: string | *"nginx"
			annotations: [string]: string
		}

		grafana: {
			host:        string | *"grafana.local"
			servicePort: int | *80
		}
		prometheus: {
			host:        string | *"prometheus.local"
			servicePort: int | *9090
		}
		alertmanager: {
			host:        string | *"alertmanager.local"
			servicePort: int | *9093
		}

		dashboards: {
			enabled:      bool | *true
			sidecarLabel: string | *"grafana_dashboard"
			sidecarValue: string | *"1"
		}

		helm: {
			grafanaAdminPassword:                    string | *"admin"
			serviceMonitorSelectorNilUsesHelmValues: bool | *false
			podMonitorSelectorNilUsesHelmValues:     bool | *false
		}
	}

	minio: {
		enabled:   bool | *true
		namespace: string | *"minio"

		instance1: {
			name:         string | *"minio1"
			rootUser:     string | *"minio1admin"
			rootPassword: string | *"minio1secret"
			storage:      string | *"2Gi"
			apiPort:      int | *9000
			consolePort:  int | *9001
			buckets: [...string] | *["logs", "configs", "backups"]
		}

		instance2: {
			name:         string | *"minio2"
			rootUser:     string | *"minio2admin"
			rootPassword: string | *"minio2secret"
			storage:      string | *"2Gi"
			apiPort:      int | *9000
			consolePort:  int | *9001
			buckets: [...string] | *["logs", "configs", "backups"]
		}

		migrate: {
			enabled: bool | *false
			image:   string | *"minio/mc:latest"
			bucketPairs: [...] | *[
				["logs",    "logs"],
				["configs", "configs"],
				["backups", "backups"],
			]
		}
	}
}
