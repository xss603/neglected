package controller

import (
	"context"
	"fmt"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	api_meta "k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/log"

	backupv1alpha1 "github.com/xss603/neglected/operators/operator-sdk/databasebackup-operator/api/v1alpha1"
)

const statusConditionCompleted = "Completed"

// DatabaseBackupReconciler reconciles a DatabaseBackup object.
type DatabaseBackupReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=ops.neglected.io,resources=databasebackups,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=ops.neglected.io,resources=databasebackups/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=ops.neglected.io,resources=databasebackups/finalizers,verbs=update
// +kubebuilder:rbac:groups=batch,resources=jobs,verbs=get;list;watch;create;update;patch;delete

func (r *DatabaseBackupReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	var backup backupv1alpha1.DatabaseBackup
	if err := r.Get(ctx, req.NamespacedName, &backup); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	jobName := backupJobName(&backup)
	var job batchv1.Job
	if err := r.Get(ctx, types.NamespacedName{Name: jobName, Namespace: backup.Namespace}, &job); err != nil {
		if !apierrors.IsNotFound(err) {
			return ctrl.Result{}, err
		}

		job = *buildBackupJob(&backup)
		if err := controllerutil.SetControllerReference(&backup, &job, r.Scheme); err != nil {
			return ctrl.Result{}, err
		}
		if err := r.Create(ctx, &job); err != nil {
			return ctrl.Result{}, err
		}
		logger.Info("created backup job", "job", job.Name)
	}

	if err := r.updateStatus(ctx, &backup, &job); err != nil {
		return ctrl.Result{}, err
	}

	if job.Status.Succeeded > 0 || job.Status.Failed > 0 {
		return ctrl.Result{}, nil
	}

	return ctrl.Result{RequeueAfter: 10 * time.Second}, nil
}

func (r *DatabaseBackupReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&backupv1alpha1.DatabaseBackup{}).
		Owns(&batchv1.Job{}).
		Complete(r)
}

func (r *DatabaseBackupReconciler) updateStatus(ctx context.Context, backup *backupv1alpha1.DatabaseBackup, job *batchv1.Job) error {
	var desired backupv1alpha1.DatabaseBackupStatus
	backup.Status.DeepCopyInto(&desired)
	desired.ObservedGeneration = backup.Generation
	desired.JobName = job.Name
	desired.Active = job.Status.Active
	desired.Succeeded = job.Status.Succeeded
	desired.Failed = job.Status.Failed
	desired.StartTime = copyTime(job.Status.StartTime)
	desired.CompletionTime = copyTime(job.Status.CompletionTime)
	desired.Conditions = buildConditions(backup, job, backup.Status.Conditions)

	if equality.Semantic.DeepEqual(backup.Status, desired) {
		return nil
	}

	updated := backup.DeepCopy()
	updated.Status = desired
	return r.Status().Update(ctx, updated)
}

func buildBackupJob(backup *backupv1alpha1.DatabaseBackup) *batchv1.Job {
	labels := map[string]string{
		"app.kubernetes.io/name":       "databasebackup",
		"app.kubernetes.io/managed-by": "databasebackup-operator",
		"ops.neglected.io/backup":      backup.Name,
	}

	backoffLimit := int32(1)
	if backup.Spec.BackoffLimit != nil {
		backoffLimit = *backup.Spec.BackoffLimit
	}

	env := append([]corev1.EnvVar{}, backup.Spec.Env...)
	if backup.Spec.Database != "" {
		env = append(env, corev1.EnvVar{Name: "DATABASE_NAME", Value: backup.Spec.Database})
	}

	return &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      backupJobName(backup),
			Namespace: backup.Namespace,
			Labels:    labels,
		},
		Spec: batchv1.JobSpec{
			BackoffLimit:            &backoffLimit,
			TTLSecondsAfterFinished: backup.Spec.TTLSecondsAfterFinished,
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: labels},
				Spec: corev1.PodSpec{
					ServiceAccountName: backup.Spec.ServiceAccountName,
					RestartPolicy:      corev1.RestartPolicyNever,
					Containers: []corev1.Container{{
						Name:            "backup",
						Image:           backupv1alpha1.BackupJobImage,
						ImagePullPolicy: corev1.PullIfNotPresent,
						Command:         backup.Spec.Command,
						Args:            backup.Spec.Args,
						Env:             env,
					}},
				},
			},
		},
	}
}

func buildConditions(backup *backupv1alpha1.DatabaseBackup, job *batchv1.Job, previous []metav1.Condition) []metav1.Condition {
	conditions := append([]metav1.Condition(nil), previous...)
	condition := metav1.Condition{
		Type:               statusConditionCompleted,
		ObservedGeneration: backup.Generation,
	}

	switch {
	case job.Status.Succeeded > 0:
		condition.Status = metav1.ConditionTrue
		condition.Reason = "JobSucceeded"
		condition.Message = fmt.Sprintf("Backup job %s completed successfully", job.Name)
	case job.Status.Failed > 0:
		condition.Status = metav1.ConditionFalse
		condition.Reason = "JobFailed"
		condition.Message = fmt.Sprintf("Backup job %s failed", job.Name)
	default:
		condition.Status = metav1.ConditionFalse
		condition.Reason = "JobRunning"
		condition.Message = fmt.Sprintf("Backup job %s is running", job.Name)
	}

	api_meta.SetStatusCondition(&conditions, condition)
	return conditions
}

func backupJobName(backup *backupv1alpha1.DatabaseBackup) string {
	return fmt.Sprintf("%s-backup", backup.Name)
}

func copyTime(in *metav1.Time) *metav1.Time {
	if in == nil {
		return nil
	}
	return in.DeepCopy()
}
