// Minimal CUE definitions mirroring the Argo Workflows CRD.
// These are internal to the python package; data scientists never reference them directly.
package python

#Workflow: {
	apiVersion: "argoproj.io/v1alpha1"
	kind:       "Workflow"
	metadata:   #ObjectMeta
	spec:       #WorkflowSpec
}

#WorkflowTemplate: {
	apiVersion: "argoproj.io/v1alpha1"
	kind:       "WorkflowTemplate"
	metadata:   #ObjectMeta
	spec:       #WorkflowSpec
}

#ObjectMeta: {
	name:         string
	namespace:    string | *"argo"
	labels?:      {[string]: string}
	annotations?: {[string]: string}
}

#WorkflowSpec: {
	entrypoint:          string
	arguments?:          #Arguments
	templates:           [...#Template]
	serviceAccountName?: string
	ttlStrategy?:        #TTLStrategy
	imagePullSecrets?:   [...{name: string}]
	volumes?:            [...#Volume]
}

#Arguments: {
	parameters?: [...#Parameter]
	artifacts?:  [...#Artifact]
}

#Template: {
	name:      string
	inputs?:   #IOSpec
	outputs?:  #IOSpec
	container?: #Container
	script?:   #ScriptTemplate
	dag?:      #DAGTemplate
	steps?:    [...[...#WorkflowStep]]
}

#ScriptTemplate: {
	image:         string
	command:       [...string]
	source:        string
	env?:          [...#EnvVar]
	resources?:    #ResourceRequirements
	volumeMounts?: [...#VolumeMount]
	workingDir?:   string
}

#Container: {
	image:         string
	command?:      [...string]
	args?:         [...string]
	env?:          [...#EnvVar]
	resources?:    #ResourceRequirements
	volumeMounts?: [...#VolumeMount]
	workingDir?:   string
}

#DAGTemplate: {
	tasks: [...#DAGTask]
}

#DAGTask: {
	name:         string
	template?:    string
	templateRef?: #TemplateRef
	depends?:     string
	arguments?:   #Arguments
}

#WorkflowStep: {
	name:         string
	template?:    string
	templateRef?: #TemplateRef
	arguments?:   #Arguments
	when?:        string
}

#TemplateRef: {
	name:     string
	template: string
}

#Parameter: {
	name:         string
	value?:       string
	default?:     string
	description?: string
}

#Artifact: {
	name:  string
	path?: string
	s3?:   {[string]: _}
	git?:  {[string]: _}
}

#IOSpec: {
	parameters?: [...#Parameter]
	artifacts?:  [...#Artifact]
}

#EnvVar: {
	name:   string
	value?: string
	valueFrom?: {
		secretKeyRef?:    {name: string, key: string}
		fieldRef?:        {fieldPath: string}
		configMapKeyRef?: {name: string, key: string}
	}
}

#ResourceRequirements: {
	requests?: {[string]: string}
	limits?:   {[string]: string}
}

#VolumeMount: {
	name:      string
	mountPath: string
	subPath?:  string
	readOnly?: bool
}

#Volume: {
	name:                   string
	configMap?:             {name: string}
	secret?:                {secretName: string}
	emptyDir?:              {}
	persistentVolumeClaim?: {claimName: string}
}

#TTLStrategy: {
	secondsAfterCompletion?: int
	secondsAfterSuccess?:    int
	secondsAfterFailure?:    int
}
