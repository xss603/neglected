package controller

import (
	"context"
	"testing"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"

	backupv1alpha1 "github.com/xss603/neglected/operators/operator-sdk/databasebackup-operator/api/v1alpha1"
)

func TestReconcileCreatesBackupJob(t *testing.T) {
	scheme := runtime.NewScheme()
	mustAddSchemes(t, scheme)

	backup := &backupv1alpha1.DatabaseBackup{
		TypeMeta:   metav1.TypeMeta{APIVersion: backupv1alpha1.GroupVersion.String(), Kind: "DatabaseBackup"},
		ObjectMeta: metav1.ObjectMeta{Name: "daily", Namespace: "default"},
		Spec: backupv1alpha1.DatabaseBackupSpec{
			Database: "appdb",
			Args:     []string{"--full"},
		},
	}

	client := fake.NewClientBuilder().WithScheme(scheme).WithStatusSubresource(&backupv1alpha1.DatabaseBackup{}).WithObjects(backup).Build()
	reconciler := &DatabaseBackupReconciler{Client: client, Scheme: scheme}

	res, err := reconciler.Reconcile(context.Background(), ctrl.Request{NamespacedName: types.NamespacedName{Name: backup.Name, Namespace: backup.Namespace}})
	if err != nil {
		t.Fatalf("Reconcile() error = %v", err)
	}
	if res.RequeueAfter == 0 {
		t.Fatalf("expected reconcile to requeue while job is still running")
	}

	var job batchv1.Job
	if err := client.Get(context.Background(), types.NamespacedName{Name: "daily-backup", Namespace: "default"}, &job); err != nil {
		t.Fatalf("expected job to be created: %v", err)
	}
	if got := job.Spec.Template.Spec.Containers[0].Image; got != backupv1alpha1.BackupJobImage {
		t.Fatalf("job image = %q, want %q", got, backupv1alpha1.BackupJobImage)
	}
	if got := job.Spec.Template.Spec.Containers[0].Env; len(got) != 1 || got[0].Name != "DATABASE_NAME" || got[0].Value != "appdb" {
		t.Fatalf("unexpected env vars: %#v", got)
	}
	if job.OwnerReferences[0].Name != backup.Name {
		t.Fatalf("job owner reference = %#v, want %q", job.OwnerReferences, backup.Name)
	}

	var updated backupv1alpha1.DatabaseBackup
	if err := client.Get(context.Background(), types.NamespacedName{Name: backup.Name, Namespace: backup.Namespace}, &updated); err != nil {
		t.Fatalf("expected backup to exist: %v", err)
	}
	if updated.Status.JobName != "daily-backup" {
		t.Fatalf("status.jobName = %q, want daily-backup", updated.Status.JobName)
	}
}

func TestReconcileUpdatesCompletionStatus(t *testing.T) {
	scheme := runtime.NewScheme()
	mustAddSchemes(t, scheme)

	backup := &backupv1alpha1.DatabaseBackup{
		TypeMeta:   metav1.TypeMeta{APIVersion: backupv1alpha1.GroupVersion.String(), Kind: "DatabaseBackup"},
		ObjectMeta: metav1.ObjectMeta{Name: "daily", Namespace: "default"},
	}
	job := buildBackupJob(backup)
	job.Status.Succeeded = 1
	job.Status.CompletionTime = &metav1.Time{Time: metav1.Now().Time}

	client := fake.NewClientBuilder().WithScheme(scheme).WithStatusSubresource(&backupv1alpha1.DatabaseBackup{}).WithObjects(backup, job).Build()
	reconciler := &DatabaseBackupReconciler{Client: client, Scheme: scheme}

	res, err := reconciler.Reconcile(context.Background(), ctrl.Request{NamespacedName: types.NamespacedName{Name: backup.Name, Namespace: backup.Namespace}})
	if err != nil {
		t.Fatalf("Reconcile() error = %v", err)
	}
	if res.RequeueAfter != 0 {
		t.Fatalf("expected no requeue after successful job, got %s", res.RequeueAfter)
	}

	var updated backupv1alpha1.DatabaseBackup
	if err := client.Get(context.Background(), types.NamespacedName{Name: backup.Name, Namespace: backup.Namespace}, &updated); err != nil {
		t.Fatalf("expected backup to exist: %v", err)
	}
	if updated.Status.Succeeded != 1 {
		t.Fatalf("status.succeeded = %d, want 1", updated.Status.Succeeded)
	}
	if len(updated.Status.Conditions) != 1 || updated.Status.Conditions[0].Reason != "JobSucceeded" {
		t.Fatalf("unexpected status conditions: %#v", updated.Status.Conditions)
	}
}

func TestBuildBackupJobUsesConfiguredFields(t *testing.T) {
	backoff := int32(3)
	ttl := int32(600)
	backup := &backupv1alpha1.DatabaseBackup{
		ObjectMeta: metav1.ObjectMeta{Name: "weekly", Namespace: "ops"},
		Spec: backupv1alpha1.DatabaseBackupSpec{
			Database:                "customers",
			Command:                 []string{"/backup"},
			Args:                    []string{"--incremental"},
			BackoffLimit:            &backoff,
			TTLSecondsAfterFinished: &ttl,
			ServiceAccountName:      "backup-runner",
			Env: []corev1.EnvVar{{
				Name:  "DESTINATION",
				Value: "s3://bucket/path",
			}},
		},
	}

	job := buildBackupJob(backup)
	container := job.Spec.Template.Spec.Containers[0]

	if job.Spec.BackoffLimit == nil || *job.Spec.BackoffLimit != backoff {
		t.Fatalf("backoffLimit = %v, want %d", job.Spec.BackoffLimit, backoff)
	}
	if job.Spec.TTLSecondsAfterFinished == nil || *job.Spec.TTLSecondsAfterFinished != ttl {
		t.Fatalf("ttlSecondsAfterFinished = %v, want %d", job.Spec.TTLSecondsAfterFinished, ttl)
	}
	if job.Spec.Template.Spec.ServiceAccountName != "backup-runner" {
		t.Fatalf("serviceAccountName = %q, want backup-runner", job.Spec.Template.Spec.ServiceAccountName)
	}
	if len(container.Env) != 2 {
		t.Fatalf("env len = %d, want 2", len(container.Env))
	}
}

func mustAddSchemes(t *testing.T, scheme *runtime.Scheme) {
	t.Helper()
	if err := batchv1.AddToScheme(scheme); err != nil {
		t.Fatalf("batchv1.AddToScheme() error = %v", err)
	}
	if err := corev1.AddToScheme(scheme); err != nil {
		t.Fatalf("corev1.AddToScheme() error = %v", err)
	}
	if err := backupv1alpha1.AddToScheme(scheme); err != nil {
		t.Fatalf("backupv1alpha1.AddToScheme() error = %v", err)
	}
}
