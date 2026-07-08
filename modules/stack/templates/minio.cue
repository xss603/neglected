package templates

import (
	"list"
	"strings"
)

// #MinioDeployment generates the PVC + Deployment + Service for one MinIO instance.
#MinioDeployment: {
	_inst: #MinioInstance
	_ns:   string
	_tol:  _

	// ── PVC ──────────────────────────────────────────────────────────────────
	pvc: {
		apiVersion: "v1"
		kind:       "PersistentVolumeClaim"
		metadata: {
			name:      "\(_inst.name)-pvc"
			namespace: _ns
		}
		spec: {
			accessModes: ["ReadWriteOnce"]
			if _inst.storageClass != "" {
				storageClassName: _inst.storageClass
			}
			resources: requests: storage: _inst.storage
		}
	}

	// ── Deployment ────────────────────────────────────────────────────────────
	deployment: {
		apiVersion: "apps/v1"
		kind:       "Deployment"
		metadata: {
			name:      _inst.name
			namespace: _ns
			labels: app: _inst.name
		}
		spec: {
			replicas: _inst.replicas
			selector: matchLabels: app: _inst.name
			template: {
				metadata: labels: app: _inst.name
				spec: {
					tolerations: [{
						key:      _tol.key
						operator: _tol.operator
						value:    _tol.value
						effect:   _tol.effect
					}]
					containers: [{
						name:            "minio"
						image:           _inst.image
						imagePullPolicy: _inst.imagePullPolicy
						args: ["server", "/data", "--console-address", ":\(_inst.consolePort)"]

						// Static credential env vars
						env: [
							{name: "MINIO_ROOT_USER",     value: _inst.rootUser},
							{name: "MINIO_ROOT_PASSWORD", value: _inst.rootPassword},
							// Extra env vars from config
							for k, v in _inst.extraEnv { name: k, value: v },
						]

						ports: [
							{name: "api",     containerPort: _inst.apiPort},
							{name: "console", containerPort: _inst.consolePort},
						]

						volumeMounts: [{name: "data", mountPath: "/data"}]

						resources: _inst.resources

						if _inst.readinessProbe.enabled {
							readinessProbe: {
								httpGet: {path: "/minio/health/ready", port: _inst.apiPort}
								initialDelaySeconds: _inst.readinessProbe.initialDelaySeconds
								periodSeconds:       _inst.readinessProbe.periodSeconds
							}
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

	// ── Service ───────────────────────────────────────────────────────────────
	service: {
		apiVersion: "v1"
		kind:       "Service"
		metadata: {
			name:      _inst.name
			namespace: _ns
		}
		spec: {
			type:     _inst.serviceType
			selector: app: _inst.name
			ports: [
				{name: "api",     port: _inst.apiPort,     targetPort: _inst.apiPort},
				{name: "console", port: _inst.consolePort, targetPort: _inst.consolePort},
			]
		}
	}
}

// #Minio builds all MinIO Kubernetes objects from config.
#Minio: {
	_cfg: #Config

	// ── Namespace ─────────────────────────────────────────────────────────────
	minio_namespace: {
		apiVersion: "v1"
		kind:       "Namespace"
		metadata: name: _cfg.minio.namespace
	}

	// ── Instance 1 (conditional on instance1.enabled) ─────────────────────────
	if _cfg.minio.instance1.enabled {
		_i1: #MinioDeployment & {
			_inst: _cfg.minio.instance1
			_ns:   _cfg.minio.namespace
			_tol:  _cfg.toleration
		}
		pvc_minio1:        _i1.pvc
		deployment_minio1: _i1.deployment
		service_minio1:    _i1.service
	}

	// ── Instance 2 (conditional on instance2.enabled) ─────────────────────────
	if _cfg.minio.instance2.enabled {
		_i2: #MinioDeployment & {
			_inst: _cfg.minio.instance2
			_ns:   _cfg.minio.namespace
			_tol:  _cfg.toleration
		}
		pvc_minio2:        _i2.pvc
		deployment_minio2: _i2.deployment
		service_minio2:    _i2.service
	}

	// ── Ingress for MinIO consoles (conditional on minio.ingress.enabled) ─────
	if _cfg.minio.ingress.enabled {
		_minioIngressAnnotations: _cfg.minio.ingress.annotations

		if _cfg.minio.instance1.enabled {
			ingress_minio1: {
				apiVersion: "networking.k8s.io/v1"
				kind:       "Ingress"
				metadata: {
					name:        "\(_cfg.minio.instance1.name)-console"
					namespace:   _cfg.minio.namespace
					annotations: _minioIngressAnnotations
				}
				spec: {
					ingressClassName: _cfg.minio.ingress.className
					if _cfg.minio.ingress.tls.enabled {
						tls: [{
							hosts:      [_cfg.minio.ingress.instance1.host]
							secretName: _cfg.minio.ingress.tls.secretName
						}]
					}
					rules: [{
						host: _cfg.minio.ingress.instance1.host
						http: paths: [{
							path:     "/"
							pathType: "Prefix"
							backend: service: {
								name: _cfg.minio.instance1.name
								port: number: _cfg.minio.ingress.instance1.port
							}
						}]
					}]
				}
			}
		}

		if _cfg.minio.instance2.enabled {
			ingress_minio2: {
				apiVersion: "networking.k8s.io/v1"
				kind:       "Ingress"
				metadata: {
					name:        "\(_cfg.minio.instance2.name)-console"
					namespace:   _cfg.minio.namespace
					annotations: _minioIngressAnnotations
				}
				spec: {
					ingressClassName: _cfg.minio.ingress.className
					if _cfg.minio.ingress.tls.enabled {
						tls: [{
							hosts:      [_cfg.minio.ingress.instance2.host]
							secretName: _cfg.minio.ingress.tls.secretName
						}]
					}
					rules: [{
						host: _cfg.minio.ingress.instance2.host
						http: paths: [{
							path:     "/"
							pathType: "Prefix"
							backend: service: {
								name: _cfg.minio.instance2.name
								port: number: _cfg.minio.ingress.instance2.port
							}
						}]
					}]
				}
			}
		}
	}

	// ── Migration Job (conditional on migrate.enabled) ────────────────────────
	if _cfg.minio.migrate.enabled {
		secret_minio1_creds: {
			apiVersion: "v1"
			kind:       "Secret"
			metadata: {
				name:      "\(_cfg.minio.instance1.name)-creds"
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
				name:      "\(_cfg.minio.instance2.name)-creds"
				namespace: _cfg.minio.namespace
			}
			stringData: {
				rootUser:     _cfg.minio.instance2.rootUser
				rootPassword: _cfg.minio.instance2.rootPassword
			}
		}

		_src:      "src"
		_dst:      "dst"
		_i1name:   _cfg.minio.instance1.name
		_i2name:   _cfg.minio.instance2.name
		_ns:       _cfg.minio.namespace
		_apiPort1: _cfg.minio.instance1.apiPort
		_apiPort2: _cfg.minio.instance2.apiPort

		_aliasSetup: """
			mc alias set \(_src) http://\(_i1name).\(_ns).svc.cluster.local:\(_apiPort1) $SRC_USER $SRC_PASS
			mc alias set \(_dst) http://\(_i2name).\(_ns).svc.cluster.local:\(_apiPort2) $DST_USER $DST_PASS
			"""

		_mirrorCmds: [ for pair in _cfg.minio.migrate.bucketPairs {
			"mc mirror --preserve \(_src)/\(pair[0]) \(_dst)/\(pair[1])"
		}]

		_verifyCmds: [ for pair in _cfg.minio.migrate.bucketPairs if _cfg.minio.migrate.verify {
			"mc diff \(_src)/\(pair[0]) \(_dst)/\(pair[1])"
		}]

		_script: _aliasSetup + "\n" + strings.Join(list.Concat([_mirrorCmds, _verifyCmds]), "\n") + "\necho migration complete"

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
							name:      "mc-mirror"
							image:     _cfg.minio.migrate.image
							resources: _cfg.minio.migrate.resources
							command:   ["sh", "-c", _script]
							env: [
								{name: "SRC_USER", valueFrom: secretKeyRef: {name: "\(_i1name)-creds", key: "rootUser"}},
								{name: "SRC_PASS", valueFrom: secretKeyRef: {name: "\(_i1name)-creds", key: "rootPassword"}},
								{name: "DST_USER", valueFrom: secretKeyRef: {name: "\(_i2name)-creds", key: "rootUser"}},
								{name: "DST_PASS", valueFrom: secretKeyRef: {name: "\(_i2name)-creds", key: "rootPassword"}},
							]
						}]
					}
				}
			}
		}
	}
}
