package main

import (
	templates "timoni.sh/grafana-stack/templates"
)

// Declare tags required by timoni's strict tag injection.
_instanceName:      string | *"grafana-stack" @tag(name)
_instanceNamespace: string | *"default"       @tag(namespace)
_moduleVersion:     string | *"0.1.0"         @tag(mv, var=moduleVersion)

timoni: {
	apiVersion: "v1alpha1"

	instance: templates.#Instance & {
		config: values
	}

	// objects is already a list — assign directly without a for-in-struct iteration.
	apply: app: timoni.instance.objects
}
