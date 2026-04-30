// #PythonJob is the interface data scientists use to declare a Python workload.
// The tooling synthesises it into an Argo Workflow YAML via cue export.
package python

// #EnvSecret maps a Kubernetes Secret key to a container environment variable.
#EnvSecret: {
	envVar: string // name visible inside the container
	secret: string // k8s Secret name
	key:    string // key within that Secret
}

// #Resources describes compute requirements for one Python step.
#Resources: {
	cpu?:    string   // e.g. "2" or "500m"
	memory?: string   // e.g. "4Gi"
	gpu?:    int & >=1 // nvidia.com/gpu count
}

// #PythonJob is the base schema shared by all job kinds.
// Do not reference this directly — use #InlinePythonJob or #GitPythonJob.
#PythonJob: {
	// Argo Workflow name — must be a valid k8s name
	name:      =~"^[a-z][a-z0-9-]{0,62}$"
	namespace: string | *"argo"

	// Container image — should have Python pre-installed
	image: string | *"python:3.12-slim"

	// pip packages to install at runtime.
	// Prefer pre-built images with dependencies baked in for large dependency sets.
	requirements: [...string] | *[]

	// Plain environment variables
	env: {[string]: string} | *{}

	// Secret-backed environment variables
	envSecrets: [...#EnvSecret] | *[]

	// Compute resources
	resources?: #Resources

	// Argo Workflow parameters exposed as workflow.spec.arguments.
	// Data scientists use {{inputs.parameters.<name>}} in their Python source.
	parameters: {[string]: {
		default?:     string
		description?: string
	}} | *{}
}

// #InlinePythonJob embeds the Python source directly in the CUE definition.
// Best for: experiments, short scripts, notebook-style workloads.
#InlinePythonJob: #PythonJob & {
	source: string
}

// #GitPythonJob clones a git repo at runtime and runs a script from it.
// The image must include git (e.g. python:3.12, not python:3.12-slim).
// Best for: production jobs with a proper code repo.
#GitPythonJob: #PythonJob & {
	git: {
		repo:   string        // full clone URL, e.g. "https://github.com/org/repo.git"
		branch: string | *"main"
		script: string        // path to .py file inside repo, e.g. "src/train.py"
		depth:  int    | *1   // shallow clone depth
	}
}

// #DAGStep is one node in a multi-step DAG workflow.
// `depends` follows Argo's dependency expression syntax, e.g. "step-a && step-b".
#DAGStep: (#InlinePythonJob | #GitPythonJob) & {
	depends?: string
}
