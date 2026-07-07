package main

import (
	templates "timoni.sh/grafana-stack/templates"
)

// Declare tags required by timoni's strict tag injection.
_instanceName:      string | *"grafana-stack" @tag(name)
_instanceNamespace: string | *"default"       @tag(namespace)
_moduleVersion:     string | *"0.1.0"         @tag(mv, var=moduleVersion)

// _config merges user overrides (values) with module defaults (#Config).
// Because timoni REPLACES the values field with the --values file content,
// defaults must not live in values.cue — they come from #Config's | *default fields.
_config: templates.#Config & values

timoni: {
	apiVersion: "v1alpha1"

	instance: templates.#Instance & {
		config: _config
	}

	apply: app: timoni.instance.objects
}
