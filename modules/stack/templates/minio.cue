package templates

import "strings"

// #MinioObjects returns a struct of MinIO Kubernetes resources derived from config.
#Minio: {
	_cfg: #Config

	// Namespace
	minio_namespace: {
		apiVersion: "v1"
		kind:       "Namespace"
		metadata: name: _cfg.minio.namespace
	}

	// Helper to build PVC + Deployment + Service for one MinIO instance.
	#MinioInstance: {
		_inst: {
			name:         string
			rootUser:     string
			rootPassword: string
			storage:      string
			apiPort:      int
			consolePort:  int
			buckets: [...string]
		}
		_ns: string

		pvc: {
			apiVersion: "v1"
			kind:       "PersistentVolumeClaim"
			metadata: {
				name:      "\(_inst.name)-pvc"
				namespace: _ns
			}
			spec: {
				accessModes: ["ReadWriteOnce"]
				resources: requests: storage: _inst.storage
			}
		}

		deployment: {
			apiVersion: "apps/v1"
			kind:       "Deployment"
			metadata: {
				name:      _inst.name
				namespace: _ns
				labels: app: _inst.name
			}
			spec: {
				replicas: 1
				selector: matchLabels: app: _inst.name
				template: {
					metadata: labels: app: _inst.name
					spec: {
						tolerations: [{
							key:      _cfg.toleration.key
							operator: _cfg.toleration.operator
							value:    _cfg.toleration.value
							effect:   _cfg.toleration.effect
						}]
						containers: [{
							name:  "minio"
							image: "quay.io/minio/minio:latest"
							args: ["server", "/data", "--console-address", ":\(_inst.consolePort)"]
							env: [
								{name: "MINIO_ROOT_USER",     value: _inst.rootUser},
								{name: "MINIO_ROOT_PASSWORD", value: _inst.rootPassword},
							]
							ports: [
								{name: "api",     containerPort: _inst.apiPort},
								{name: "console", containerPort: _inst.consolePort},
							]
							volumeMounts: [{
								name:      "data"
								mountPath: "/data"
							}]
							readinessProbe: {
								httpGet: {path: "/minio/health/ready", port: _inst.apiPort}
								initialDelaySeconds: 10
								periodSeconds:       5
							}
						}]
						volumes: [{
							name: "data"
							persistentVolumeClaim: claimName: "\(_inst.name)-pvc"
						}]
					}
				}
			}
		}

		service: {
			apiVersion: "v1"
			kind:       "Service"
			metadata: {
				name:      _inst.name
				namespace: _ns
			}
			spec: {
				selector: app: _inst.name
				ports: [
					{name: "api",     port: _inst.apiPort,     targetPort: _inst.apiPort},
					{name: "console", port: _inst.consolePort, targetPort: _inst.consolePort},
				]
			}
		}
	}

	_i1: #MinioInstance & {_inst: _cfg.minio.instance1, _ns: _cfg.minio.namespace}
	_i2: #MinioInstance & {_inst: _cfg.minio.instance2, _ns: _cfg.minio.namespace}

	pvc_minio1:        _i1.pvc
	deployment_minio1: _i1.deployment
	service_minio1:    _i1.service
	pvc_minio2:        _i2.pvc
	deployment_minio2: _i2.deployment
	service_minio2:    _i2.service

	// Migration job — present only when migrate.enabled
	if _cfg.minio.migrate.enabled {
		secret_minio1_creds: {
			apiVersion: "v1"
			kind:       "Secret"
			metadata: {
				name:      "minio1-creds"
				namespace: _cfg.minio.namespace
			}
			stringData: {
				rootUser:     _cfg.minio.instance1.rootUser
				rootPassword: _cfg.minio.instance1.rootPassword
			}
		}

		secret_minio2_creds: {
			apiVersion: "v1"
			kind:       "Secret"
			metadata: {
				name:      "minio2-creds"
				namespace: _cfg.minio.namespace
			}
			stringData: {
				rootUser:     _cfg.minio.instance2.rootUser
				rootPassword: _cfg.minio.instance2.rootPassword
			}
		}

		_mirrorCmds: [ for pair in _cfg.minio.migrate.bucketPairs {
			"mc mirror --preserve src/\(pair[0]) dst/\(pair[1])"
		}]

		_migrateScript: """
			mc alias set src http://\(_cfg.minio.instance1.name).\(_cfg.minio.namespace).svc.cluster.local:\(_cfg.minio.instance1.apiPort) $SRC_USER $SRC_PASS
			mc alias set dst http://\(_cfg.minio.instance2.name).\(_cfg.minio.namespace).svc.cluster.local:\(_cfg.minio.instance2.apiPort) $DST_USER $DST_PASS
			""" + strings.Join(_mirrorCmds, "\n") + "\necho done"

		job_minio_migrate: {
			apiVersion: "batch/v1"
			kind:       "Job"
			metadata: {
				name:      "minio-migrate"
				namespace: _cfg.minio.namespace
				labels: app: "minio-migrate"
			}
			spec: {
				ttlSecondsAfterFinished: 600
				template: {
					metadata: labels: app: "minio-migrate"
					spec: {
						restartPolicy: "OnFailure"
						tolerations: [{
							key:      _cfg.toleration.key
							operator: _cfg.toleration.operator
							value:    _cfg.toleration.value
							effect:   _cfg.toleration.effect
						}]
						containers: [{
							name:  "mc-mirror"
							image: _cfg.minio.migrate.image
							command: ["sh", "-c", _migrateScript]
							env: [
								{name: "SRC_USER", valueFrom: secretKeyRef: {name: "minio1-creds", key: "rootUser"}},
								{name: "SRC_PASS", valueFrom: secretKeyRef: {name: "minio1-creds", key: "rootPassword"}},
								{name: "DST_USER", valueFrom: secretKeyRef: {name: "minio2-creds", key: "rootUser"}},
								{name: "DST_PASS", valueFrom: secretKeyRef: {name: "minio2-creds", key: "rootPassword"}},
							]
						}]
					}
				}
			}
		}
	}
}
