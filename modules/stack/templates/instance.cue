package templates

// #Instance assembles all Kubernetes objects for the grafana-stack module.
#Instance: {
	config: #Config

	_m: #Monitoring & {_cfg: config}
	_n: #Minio & {_cfg: config}

	// Each 'if' clause adds exactly one element; the condition filters at build time.
	objects: [
		// Monitoring
		if config.monitoring.enabled {_m.monitoring_namespace},
		if config.monitoring.enabled && config.monitoring.ingress.enabled {_m.ingress_grafana},
		if config.monitoring.enabled && config.monitoring.ingress.enabled {_m.ingress_prometheus},
		if config.monitoring.enabled && config.monitoring.ingress.enabled {_m.ingress_alertmanager},
		if config.monitoring.enabled && config.monitoring.dashboards.enabled {_m.configmap_node_taint_monitor},
		if config.monitoring.enabled && config.monitoring.dashboards.enabled {_m.configmap_pod_ns_resources},
		if config.monitoring.enabled && config.monitoring.dashboards.enabled {_m.configmap_chaos_dr},
		// MinIO
		if config.minio.enabled {_n.minio_namespace},
		if config.minio.enabled {_n.pvc_minio1},
		if config.minio.enabled {_n.deployment_minio1},
		if config.minio.enabled {_n.service_minio1},
		if config.minio.enabled {_n.pvc_minio2},
		if config.minio.enabled {_n.deployment_minio2},
		if config.minio.enabled {_n.service_minio2},
		// Migration job
		if config.minio.enabled && config.minio.migrate.enabled {_n.secret_minio1_creds},
		if config.minio.enabled && config.minio.migrate.enabled {_n.secret_minio2_creds},
		if config.minio.enabled && config.minio.migrate.enabled {_n.job_minio_migrate},
	]
}
