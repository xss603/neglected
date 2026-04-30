// Model training pipeline — example of a multi-step DAG workflow.
//
// DAG topology:
//   validate-data ──┐
//                   ├──▶ train-model ──▶ evaluate-model
//   prep-features ──┘
//
// To regenerate:
//   cue export --out yaml -e workflow ./jobs/model-training-dag/
//   # or: make generate
package modeltrainingdag

import python "github.com/xss603/neglected/argo-workflows/python"

// ── Step definitions ─────────────────────────────────────────────────────────

_validateData: python.#InlinePythonJob & {
	name:  "validate-data"
	image: "python:3.12-slim"
	requirements: ["pandas==2.2.2", "great-expectations==0.18.19"]
	env: DATA_PATH: "/data/raw"
	resources: {cpu: "1", memory: "2Gi"}
	source: """
		import os
		import pandas as pd

		data_path = os.environ["DATA_PATH"]
		df = pd.read_parquet(f"{data_path}/dataset.parquet")

		assert not df.empty,                 "Dataset is empty"
		assert df.isnull().mean().max() < 0.3, "Too many nulls (>30%) in a column"
		print(f"Validation passed: {len(df):,} rows, {df.shape[1]} cols")
		"""
}

_prepFeatures: python.#InlinePythonJob & {
	name:  "prep-features"
	image: "python:3.12-slim"
	requirements: ["pandas==2.2.2", "scikit-learn==1.4.2", "pyarrow==16.0.0"]
	env: {
		DATA_PATH:    "/data/raw"
		FEATURE_PATH: "/data/features"
	}
	resources: {cpu: "2", memory: "4Gi"}
	source: """
		import os
		import pandas as pd
		from sklearn.preprocessing import StandardScaler, LabelEncoder

		df = pd.read_parquet(os.environ["DATA_PATH"] + "/dataset.parquet")

		for col in df.select_dtypes("object").columns:
		    df[col] = LabelEncoder().fit_transform(df[col].astype(str))

		num_cols = df.select_dtypes("number").columns
		df[num_cols] = StandardScaler().fit_transform(df[num_cols])

		os.makedirs(os.environ["FEATURE_PATH"], exist_ok=True)
		df.to_parquet(os.environ["FEATURE_PATH"] + "/features.parquet")
		print(f"Features written: {df.shape}")
		"""
}

_trainModel: python.#InlinePythonJob & {
	name:  "train-model"
	image: "python:3.12-slim"
	requirements: [
		"pandas==2.2.2",
		"scikit-learn==1.4.2",
		"mlflow==2.13.0",
		"pyarrow==16.0.0",
	]
	env: {
		FEATURE_PATH:         "/data/features"
		MODEL_PATH:           "/data/model"
		MLFLOW_TRACKING_URI:  "http://mlflow.mlflow.svc:5000"
		MLFLOW_EXPERIMENT:    "model-training"
	}
	resources: {cpu: "4", memory: "8Gi"}
	parameters: {
		"learning-rate": {default: "0.1",   description: "Gradient boosting learning rate"}
		"n-estimators":  {default: "200",   description: "Number of trees"}
		"max-depth":     {default: "6",     description: "Maximum tree depth"}
	}
	source: """
		import os
		import pandas as pd
		import mlflow
		from sklearn.ensemble import GradientBoostingClassifier
		from sklearn.model_selection import train_test_split
		from sklearn.metrics import roc_auc_score
		import joblib

		lr        = float("{{inputs.parameters.learning-rate}}")
		n_est     = int("{{inputs.parameters.n-estimators}}")
		max_depth = int("{{inputs.parameters.max-depth}}")

		df  = pd.read_parquet(os.environ["FEATURE_PATH"] + "/features.parquet")
		X, y = df.drop("target", axis=1), df["target"]
		X_train, X_val, y_train, y_val = train_test_split(X, y, test_size=0.2, random_state=42)

		mlflow.set_tracking_uri(os.environ["MLFLOW_TRACKING_URI"])
		mlflow.set_experiment(os.environ["MLFLOW_EXPERIMENT"])

		with mlflow.start_run():
		    mlflow.log_params({"lr": lr, "n_estimators": n_est, "max_depth": max_depth})

		    model = GradientBoostingClassifier(
		        learning_rate=lr, n_estimators=n_est, max_depth=max_depth, random_state=42
		    )
		    model.fit(X_train, y_train)

		    auc = roc_auc_score(y_val, model.predict_proba(X_val)[:, 1])
		    mlflow.log_metric("val_auc", auc)
		    print(f"Validation AUC: {auc:.4f}")

		    os.makedirs(os.environ["MODEL_PATH"], exist_ok=True)
		    model_file = os.environ["MODEL_PATH"] + "/model.pkl"
		    joblib.dump(model, model_file)
		    mlflow.log_artifact(model_file)
		"""
}

_evaluateModel: python.#InlinePythonJob & {
	name:  "evaluate-model"
	image: "python:3.12-slim"
	requirements: ["pandas==2.2.2", "scikit-learn==1.4.2", "pyarrow==16.0.0"]
	env: {
		FEATURE_PATH: "/data/features"
		MODEL_PATH:   "/data/model"
	}
	resources: {cpu: "2", memory: "4Gi"}
	source: """
		import os
		import pandas as pd
		import joblib
		from sklearn.metrics import classification_report

		df    = pd.read_parquet(os.environ["FEATURE_PATH"] + "/features.parquet")
		X, y  = df.drop("target", axis=1), df["target"]
		model = joblib.load(os.environ["MODEL_PATH"] + "/model.pkl")

		print(classification_report(y, model.predict(X)))
		"""
}

// ── DAG assembly ──────────────────────────────────────────────────────────────

workflow: (python.#DAGWorkflow & {
	name:      "model-training-pipeline"
	namespace: "argo"
	steps: [
		_validateData & {depends: ""},
		_prepFeatures & {depends: ""},
		_trainModel   & {depends: "validate-data && prep-features"},
		_evaluateModel & {depends: "train-model"},
	]
}).out
