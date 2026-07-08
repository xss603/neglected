package templates

// #ResourceList is a Kubernetes resource quantity map (cpu / memory).
#ResourceList: [string]: string

// #Resources describes requests and optional limits for a container.
#Resources: {
	requests?: #ResourceList
	limits?:   #ResourceList
}

// #TLS groups TLS settings shared by ingress objects.
#TLS: {
	// Enable TLS on this ingress (adds tls[] block).
	enabled: bool | *false
	// Name of the existing Secret that holds tls.crt / tls.key.
	// Required when enabled=true.
	secretName: string | *""
}

// #IngressHost combines the virtual hostname with the backend service port.
#IngressHost: {
	host: string
	port: int
}

// #MinioInstance holds every tuneable for one MinIO StatefulSet.
#MinioInstance: {
	// Set to false to skip this instance entirely.
	enabled: bool | *true
	name:    string

	// Credentials — store these in a Vault/ExternalSecret in production.
	rootUser:     string
	rootPassword: string

	// Image configuration.
	image:           string | *"quay.io/minio/minio:latest"
	imagePullPolicy: string | *"IfNotPresent"

	// Persistent storage.
	storage:      string | *"2Gi"
	storageClass: string | *""  // empty = cluster default

	// Service ports.
	apiPort:     int | *9000
	consolePort: int | *9001

	// Number of pods (set >1 for distributed mode — requires matching storage).
	replicas: int | *1

	// Service type exposed for API and console.
	serviceType: string | *"ClusterIP"

	// Resource requests / limits for the minio container.
	resources: #Resources | *{
		requests: {cpu: "100m", memory: "256Mi"}
	}

	// Arbitrary extra environment variables injected into the container.
	extraEnv: [string]: string

	// Bucket names to pre-create via a Job.
	// Each entry is the bucket name (string).
	buckets: [...string] | *["logs", "configs", "backups"]

	// Readiness probe settings.
	readinessProbe: {
		enabled:             bool | *true
		initialDelaySeconds: int | *10
		periodSeconds:       int | *5
	}
}

// #Config is the full schema for user-provided values.
// All fields carry defaults so the module is usable without any --values override.
#Config: {

	// ── Toleration applied to every managed workload ──────────────────────────
	toleration: {
		key:      string | *"zone"
		operator: string | *"Equal"
		value:    string | *"local"
		effect:   string | *"NoSchedule"
	}

	// ── Monitoring (kube-prometheus-stack) ────────────────────────────────────
	monitoring: {
		// Set to false to skip the entire monitoring section.
		enabled:     bool | *true
		namespace:   string | *"monitoring"
		helmRelease: string | *"kube-prom"

		// ── Ingress ───────────────────────────────────────────────────────────
		ingress: {
			enabled:   bool | *true
			className: string | *"nginx"
			// Extra annotations merged into every Ingress object.
			annotations: [string]: string

			// TLS — shared across all three monitoring ingresses when enabled.
			tls: #TLS

			grafana:      #IngressHost | *{host: "grafana.local",      port: 80}
			prometheus:   #IngressHost | *{host: "prometheus.local",   port: 9090}
			alertmanager: #IngressHost | *{host: "alertmanager.local", port: 9093}
		}

		// ── Grafana dashboard sidecar ─────────────────────────────────────────
		dashboards: {
			enabled:      bool | *true
			sidecarLabel: string | *"grafana_dashboard"
			sidecarValue: string | *"1"
		}

		// ── Helm values forwarded verbatim to kube-prometheus-stack ──────────
		// These are emitted to a ConfigMap / Secret and used by install.sh.
		helm: {
			// Grafana
			grafanaAdminPassword: string | *"admin"
			grafanaReplicas:      int | *1
			grafanaResources:     #Resources | *{}
			grafanaPersistence: {
				enabled:      bool | *false
				size:         string | *"1Gi"
				storageClass: string | *""
			}
			grafanaPlugins: [...string] | *[]

			// Prometheus
			prometheusReplicas: int | *1
			prometheusRetention: string | *"30d"
			prometheusResources: #Resources | *{
				requests: {cpu: "200m", memory: "400Mi"}
			}
			prometheusStorage: {
				enabled:      bool | *false
				size:         string | *"10Gi"
				storageClass: string | *""
			}

			// Alertmanager
			alertmanagerReplicas:  int | *1
			alertmanagerResources: #Resources | *{}

			// Selector settings — false = scrape all ServiceMonitors / PodMonitors.
			serviceMonitorSelectorNilUsesHelmValues: bool | *false
			podMonitorSelectorNilUsesHelmValues:     bool | *false
		}
	}

	// ── MinIO (dual instance + optional migration) ────────────────────────────
	minio: {
		// Set to false to skip all MinIO resources.
		enabled:   bool | *true
		namespace: string | *"minio"

		instance1: #MinioInstance | *{
			enabled:      true
			name:         "minio1"
			rootUser:     "minio1admin"
			rootPassword: "minio1secret"
		}

		instance2: #MinioInstance | *{
			enabled:      true
			name:         "minio2"
			rootUser:     "minio2admin"
			rootPassword: "minio2secret"
		}

		// ── Optional ingress for MinIO consoles ───────────────────────────────
		ingress: {
			enabled:   bool | *false
			className: string | *"nginx"
			annotations: [string]: string
			tls: #TLS
			instance1: #IngressHost | *{host: "minio1.local", port: 9001}
			instance2: #IngressHost | *{host: "minio2.local", port: 9001}
		}

		// ── Data migration (mc mirror instance1 → instance2) ─────────────────
		migrate: {
			// Flip to true to emit the migration Job.
			enabled: bool | *false
			image:   string | *"minio/mc:latest"
			resources: #Resources | *{}
			// Each entry: [source-bucket, destination-bucket]
			bucketPairs: [...] | *[
				["logs",    "logs"],
				["configs", "configs"],
				["backups", "backups"],
			]
			// Run mc diff after mirroring to verify data integrity.
			verify: bool | *true
		}
	}

	// ── Argo Workflows ─────────────────────────────────────────────────────────
	// The controller/server + CRDs are installed separately via the argo-helm
	// chart (see install.sh); Timoni only manages the namespace, ingress, and
	// any Workflow/CronWorkflow custom resources layered on top.
	argoWorkflows: {
		// Set to false to skip all Argo Workflows resources.
		enabled:     bool | *true
		namespace:   string | *"argo"
		helmRelease: string | *"argo-workflows"

		// ── Ingress for the argo-server UI/API ────────────────────────────────
		ingress: {
			enabled:   bool | *true
			className: string | *"nginx"
			annotations: [string]: string
			tls:    #TLS
			server: #IngressHost | *{host: "argo.local", port: 2746}
		}

		// ── Sample workflows layered on top of the controller ─────────────────
		workflows: {
			// A Workflow that mirrors buckets from minio.instance1 to
			// minio.instance2 using mc, exercising the same data path as
			// minio.migrate but as a native Argo DAG instead of a single Job.
			minioPipeline: {
				enabled: bool | *true
				name:    string | *"minio-artifact-pipeline"
				mcImage: string | *"minio/mc:latest"
				// Each entry: [source-bucket, destination-bucket]
				bucketPairs: [...] | *[
					["logs",    "logs"],
					["configs", "configs"],
					["backups", "backups"],
				]
			}
		}
	}
}
