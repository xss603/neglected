// Feature engineering job — example of an inline Python workflow.
//
// To regenerate the Argo Workflow YAML:
//   cue export --out yaml -e workflow ./jobs/feature-engineering/
//   # or: make generate
package featureengineering

import python "github.com/xss603/neglected/argo-workflows/python"

_job: python.#InlinePythonJob & {
	name:  "feature-engineering"
	image: "python:3.12-slim"

	requirements: [
		"pandas==2.2.2",
		"scikit-learn==1.4.2",
		"pyarrow==16.0.0",
	]

	env: {
		INPUT_PATH:  "/data/raw"
		OUTPUT_PATH: "/data/processed"
		LOG_LEVEL:   "INFO"
	}

	envSecrets: [{
		envVar: "S3_ACCESS_KEY"
		secret: "s3-credentials"
		key:    "access-key"
	}, {
		envVar: "S3_SECRET_KEY"
		secret: "s3-credentials"
		key:    "secret-key"
	}]

	resources: {
		cpu:    "2"
		memory: "4Gi"
	}

	parameters: {
		"n-features": {
			default:     "50"
			description: "Maximum number of numeric features to keep"
		}
		"input-date": {
			description: "Partition date to process, e.g. 2024-01-15"
		}
	}

	// Python source — data scientists write plain Python here.
	// Argo parameters are referenced via {{inputs.parameters.<name>}}.
	source: """
		import os
		import pandas as pd
		from sklearn.preprocessing import StandardScaler

		n_features  = int(os.environ.get("N_FEATURES", "{{inputs.parameters.n-features}}"))
		input_date  = "{{inputs.parameters.input-date}}"
		input_path  = os.environ["INPUT_PATH"]
		output_path = os.environ["OUTPUT_PATH"]

		print(f"Loading partition {input_date} from {input_path}")
		df = pd.read_parquet(f"{input_path}/{input_date}.parquet")

		numeric_cols = df.select_dtypes(include="number").columns[:n_features]
		scaler = StandardScaler()
		df[numeric_cols] = scaler.fit_transform(df[numeric_cols])

		os.makedirs(output_path, exist_ok=True)
		out_file = f"{output_path}/{input_date}.parquet"
		df.to_parquet(out_file)
		print(f"Wrote {len(df):,} rows → {out_file}")
		"""
}

// workflow is exported as YAML by `cue export -e workflow`.
workflow: (python.#InlineWorkflow & {job: _job}).out
