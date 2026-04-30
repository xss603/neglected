SHELL   := /usr/bin/env bash
CUE     := cue
ARGO    := argo
KUBECTL := kubectl
NS      := argo

.PHONY: generate validate submit-% clean deps help

help:
	@echo "Targets:"
	@echo "  generate       Export all jobs in cue/jobs/ → generated/*.yaml"
	@echo "  validate       Dry-run kubectl apply on generated YAMLs"
	@echo "  submit-<name>  Submit generated/<name>.yaml to Argo (e.g. make submit-feature-engineering)"
	@echo "  clean          Remove generated/*.yaml"
	@echo "  deps           Check required tools are installed"

deps:
	@command -v $(CUE) >/dev/null 2>&1 || \
		{ echo "cue not found — install from https://cuelang.org/docs/install/"; exit 1; }
	@command -v $(ARGO) >/dev/null 2>&1 || echo "warn: argo CLI not found — submit targets unavailable"
	@command -v $(KUBECTL) >/dev/null 2>&1 || echo "warn: kubectl not found — validate target unavailable"

generate: deps
	@bash generate.sh

validate: generate
	@echo "Dry-run validating generated workflows..."
	@for f in generated/*.yaml; do \
		echo "  checking $$f"; \
		$(KUBECTL) apply --dry-run=client -n $(NS) -f "$$f"; \
	done

# Usage: make submit-feature-engineering
submit-%: generate
	$(ARGO) submit generated/$*.yaml --namespace $(NS) --watch --log

clean:
	rm -f generated/*.yaml
