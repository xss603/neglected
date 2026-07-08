package templates

import (
	"list"
	"strings"
)

// #ArgoWorkflows builds the namespace, ingress, and sample Workflow objects
// layered on top of the argo-helm-installed controller/server.
#ArgoWorkflows: {
	_cfg: #Config
	_ns:  _cfg.argoWorkflows.namespace

	_ingressAnnotations: {
		"nginx.ingress.kubernetes.io/rewrite-target": "/"
	} & _cfg.argoWorkflows.ingress.annotations

	// ── Namespace ────────────────────────────────────────────────────────────
	argo_namespace: {
		apiVersion: "v1"
		kind:       "Namespace"
		metadata: name: _ns
	}

	// ── Ingress for argo-server (conditional on ingress.enabled) ──────────────
	if _cfg.argoWorkflows.ingress.enabled {
		_ingressTLS: [{
			hosts:      [_cfg.argoWorkflows.ingress.server.host]
			secretName: _cfg.argoWorkflows.ingress.tls.secretName
		}]

		ingress_argo: {
			apiVersion: "networking.k8s.io/v1"
			kind:       "Ingress"
			metadata: {
				name:        "argo-server"
				namespace:   _ns
				annotations: _ingressAnnotations
			}
			spec: {
				ingressClassName: _cfg.argoWorkflows.ingress.className
				if _cfg.argoWorkflows.ingress.tls.enabled { tls: _ingressTLS }
				rules: [{
					host: _cfg.argoWorkflows.ingress.server.host
					http: paths: [{
						path:     "/"
						pathType: "Prefix"
						backend: service: {
							name: "\(_cfg.argoWorkflows.helmRelease)-server"
							port: number: _cfg.argoWorkflows.ingress.server.port
						}
					}]
				}]
			}
		}
	}

	// ── Sample workflow: mirror MinIO buckets instance1 → instance2 ───────────
	if _cfg.argoWorkflows.workflows.minioPipeline.enabled {
		_mp:  _cfg.argoWorkflows.workflows.minioPipeline
		_src: _cfg.minio.instance1
		_dst: _cfg.minio.instance2
		_mns: _cfg.minio.namespace

		_aliasSetup: """
			mc alias set src http://\(_src.name).\(_mns).svc.cluster.local:\(_src.apiPort) $SRC_USER $SRC_PASS
			mc alias set dst http://\(_dst.name).\(_mns).svc.cluster.local:\(_dst.apiPort) $DST_USER $DST_PASS
			"""

		_verifyCmds: [ for pair in _mp.bucketPairs {
			"mc diff src/\(pair[0]) dst/\(pair[1])"
		}]

		// Credentials copied into the argo namespace so workflow pods (which
		// run alongside argo-server, not in the minio namespace) can reach
		// both instances without cross-namespace secret references.
		secret_minio_pipeline_creds: {
			apiVersion: "v1"
			kind:       "Secret"
			metadata: {
				name:      "minio-pipeline-creds"
				namespace: _ns
			}
			stringData: {
				SRC_USER: _src.rootUser
				SRC_PASS: _src.rootPassword
				DST_USER: _dst.rootUser
				DST_PASS: _dst.rootPassword
			}
		}

		workflow_minio_pipeline: {
			apiVersion: "argoproj.io/v1alpha1"
			kind:       "Workflow"
			metadata: {
				name:      _mp.name
				namespace: _ns
			}
			spec: {
				entrypoint: "pipeline"
				templates: [
					{
						name: "pipeline"
						dag: tasks: list.Concat([
							[ for pair in _mp.bucketPairs {
								name:     "mirror-\(pair[0])"
								template: "mirror-bucket"
								arguments: parameters: [
									{name: "src-bucket", value: pair[0]},
									{name: "dst-bucket", value: pair[1]},
								]
							}],
							[{
								name:         "verify"
								template:     "verify-buckets"
								dependencies: [ for pair in _mp.bucketPairs {"mirror-\(pair[0])"}]
							}],
						])
					},
					{
						name: "mirror-bucket"
						inputs: parameters: [{name: "src-bucket"}, {name: "dst-bucket"}]
						container: {
							image:     _mp.mcImage
							command: ["sh", "-c"]
							args: [_aliasSetup + "\n" + "mc mirror --preserve src/{{inputs.parameters.src-bucket}} dst/{{inputs.parameters.dst-bucket}}"]
							envFrom: [{secretRef: name: "minio-pipeline-creds"}]
						}
					},
					{
						name: "verify-buckets"
						container: {
							image:   _mp.mcImage
							command: ["sh", "-c"]
							args: [_aliasSetup + "\n" + strings.Join(_verifyCmds, "\n")]
							envFrom: [{secretRef: name: "minio-pipeline-creds"}]
						}
					},
				]
			}
		}
	}
}
