// Synthesis: converts #PythonJob variants into concrete Argo Workflow values.
// Data scientists reference #InlineWorkflow, #GitWorkflow, or #DAGWorkflow.
package python

import "strings"

// ── Internal helpers ──────────────────────────────────────────────────────────

// _env builds the Argo env list from a job's env map and envSecrets list.
#_Env: {
	_job: #PythonJob
	out: [
		for k, v in _job.env {{name: k, value: v}},
	] + [
		for s in _job.envSecrets {{
			name: s.envVar
			valueFrom: secretKeyRef: {name: s.secret, key: s.key}
		}},
	]
}

// _params builds the Argo parameter list from a job's parameters map.
#_Params: {
	_job: #PythonJob
	out: [
		for k, v in _job.parameters {
			name: k
			if v.default != _|_     {default: v.default}
			if v.description != _|_ {description: v.description}
		},
	]
}

// _pipPrefix prepends a runtime pip install to inline Python source.
// When requirements is empty the prefix is an empty string.
#_PipPrefix: {
	_requirements: [...string]
	_text:         *"" | string
	if len(_requirements) > 0 {
		_text: "import subprocess, sys\nsubprocess.check_call([sys.executable, '-m', 'pip', 'install', " +
			strings.Join([for r in _requirements {"'\(r)'"}], ", ") +
			"])\n\n"
	}
	out: _text
}

// _resources builds the Argo ResourceRequirements block.
#_Resources: {
	_r: #Resources
	out: #ResourceRequirements & {
		requests: {
			if _r.cpu != _|_    {cpu:    _r.cpu}
			if _r.memory != _|_ {memory: _r.memory}
		}
		limits: {
			if _r.cpu != _|_    {cpu:    _r.cpu}
			if _r.memory != _|_ {memory: _r.memory}
			if _r.gpu != _|_    {"nvidia.com/gpu": "\(_r.gpu)"}
		}
	}
}

// _scriptTemplate builds a #ScriptTemplate for a given job and source string.
#_ScriptTemplate: {
	_job:    #PythonJob
	_cmd:    [...string]
	_source: string

	_env:    (#_Env & {_job: _job}).out
	_params: (#_Params & {_job: _job}).out

	out: #ScriptTemplate & {
		image:   _job.image
		command: _cmd
		source:  _source
		if len(_env) > 0 {env: _env}
		if _job.resources != _|_ {
			resources: (#_Resources & {_r: _job.resources}).out
		}
	}
}

// ── Public synthesis templates ────────────────────────────────────────────────

// #InlineWorkflow generates an Argo Workflow that runs inline Python source.
//
// Usage in job.cue:
//   workflow: (python.#InlineWorkflow & {job: _myJob}).out
#InlineWorkflow: {
	job: #InlinePythonJob

	_pip:    (#_PipPrefix & {_requirements: job.requirements}).out
	_source: _pip + job.source
	_params: (#_Params & {_job: job}).out
	_tmpl:   (#_ScriptTemplate & {_job: job, _cmd: ["python"], _source: _source}).out

	out: #Workflow & {
		metadata: {
			name:      job.name
			namespace: job.namespace
			labels: "app.kubernetes.io/managed-by": "cue"
		}
		spec: {
			entrypoint: job.name
			if len(_params) > 0 {
				arguments: parameters: _params
			}
			ttlStrategy: {
				secondsAfterCompletion: 86400   // 1 day
				secondsAfterFailure:    604800  // 7 days
			}
			templates: [{
				name: job.name
				if len(_params) > 0 {
					inputs: parameters: [for p in _params {name: p.name}]
				}
				script: _tmpl
			}]
		}
	}
}

// #GitWorkflow generates an Argo Workflow that clones a git repo then runs a script.
// The job.image must include git (e.g. "python:3.12" not "python:3.12-slim").
//
// Usage in job.cue:
//   workflow: (python.#GitWorkflow & {job: _myJob}).out
#GitWorkflow: {
	job: #GitPythonJob

	_pipShell: *"" | string
	if len(job.requirements) > 0 {
		_pipShell: "pip install " + strings.Join(job.requirements, " ") + "\n"
	}

	_source: "#!/bin/sh\nset -e\n" +
		"git clone --depth \(job.git.depth) -b \(job.git.branch) \(job.git.repo) /workspace\n" +
		"cd /workspace\n" +
		_pipShell +
		"python \(job.git.script)\n"

	_params: (#_Params & {_job: job}).out
	_tmpl:   (#_ScriptTemplate & {_job: job, _cmd: ["sh"], _source: _source}).out

	out: #Workflow & {
		metadata: {
			name:      job.name
			namespace: job.namespace
			labels: "app.kubernetes.io/managed-by": "cue"
		}
		spec: {
			entrypoint: job.name
			if len(_params) > 0 {
				arguments: parameters: _params
			}
			ttlStrategy: {
				secondsAfterCompletion: 86400
				secondsAfterFailure:    604800
			}
			templates: [{
				name: job.name
				if len(_params) > 0 {
					inputs: parameters: [for p in _params {name: p.name}]
				}
				script: _tmpl
			}]
		}
	}
}

// #DAGWorkflow generates a multi-step Argo Workflow from a list of #DAGStep values.
// Each step is an independent #InlinePythonJob or #GitPythonJob with an optional
// `depends` expression that wires the DAG edges.
//
// Usage in job.cue:
//   workflow: (python.#DAGWorkflow & {
//     name:      "my-pipeline"
//     namespace: "argo"
//     steps: [step1, step2, ...]
//   }).out
#DAGWorkflow: {
	name:      =~"^[a-z][a-z0-9-]{0,62}$"
	namespace: string | *"argo"
	steps:     [...#DAGStep]

	// Build one script template per step
	_stepTemplates: [
		for s in steps {
			_pip: (#_PipPrefix & {_requirements: s.requirements}).out
			_src: {
				if s.source != _|_ {_pip + s.source}
				if s.git != _|_ {
					_sh: *"" | string
					if len(s.requirements) > 0 {
						_sh: "pip install " + strings.Join(s.requirements, " ") + "\n"
					}
					"#!/bin/sh\nset -e\ngit clone --depth \(s.git.depth) -b \(s.git.branch) \(s.git.repo) /workspace\ncd /workspace\n" + _sh + "python \(s.git.script)\n"
				}
			}
			_cmd: {
				if s.source != _|_ {["python"]}
				if s.git != _|_    {["sh"]}
			}
			(#Template) & {
				name: s.name
				script: (#_ScriptTemplate & {_job: s, _cmd: _cmd, _source: _src}).out
			}
		},
	]

	// Build the DAG task list
	_dagTasks: [
		for s in steps {
			(#DAGTask) & {
				name:     s.name
				template: s.name
				if s.depends != _|_ {depends: s.depends}
			}
		},
	]

	out: #Workflow & {
		metadata: {
			name:      name
			namespace: namespace
			labels: "app.kubernetes.io/managed-by": "cue"
		}
		spec: {
			entrypoint: name
			ttlStrategy: {
				secondsAfterCompletion: 86400
				secondsAfterFailure:    604800
			}
			templates: [
				{
					name: name
					dag: #DAGTemplate & {tasks: _dagTasks}
				},
			] + _stepTemplates
		}
	}
}
