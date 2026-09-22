package v1alpha1

import (
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

const BackupJobImage = "apps/backup:va"

// DatabaseBackupSpec describes the backup job request.
type DatabaseBackupSpec struct {
	Database string          `json:"database,omitempty"`
	Command  []string        `json:"command,omitempty"`
	Args     []string        `json:"args,omitempty"`
	Env      []corev1.EnvVar `json:"env,omitempty"`
	// +kubebuilder:default:=1
	BackoffLimit            *int32 `json:"backoffLimit,omitempty"`
	TTLSecondsAfterFinished *int32 `json:"ttlSecondsAfterFinished,omitempty"`
	ServiceAccountName      string `json:"serviceAccountName,omitempty"`
}

// DatabaseBackupStatus reflects the launched job state.
type DatabaseBackupStatus struct {
	ObservedGeneration int64              `json:"observedGeneration,omitempty"`
	JobName            string             `json:"jobName,omitempty"`
	Active             int32              `json:"active,omitempty"`
	Succeeded          int32              `json:"succeeded,omitempty"`
	Failed             int32              `json:"failed,omitempty"`
	StartTime          *metav1.Time       `json:"startTime,omitempty"`
	CompletionTime     *metav1.Time       `json:"completionTime,omitempty"`
	Conditions         []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,shortName=dbb
// DatabaseBackup requests a one-shot backup job.
type DatabaseBackup struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   DatabaseBackupSpec   `json:"spec,omitempty"`
	Status DatabaseBackupStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true
// DatabaseBackupList contains a list of DatabaseBackup.
type DatabaseBackupList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []DatabaseBackup `json:"items"`
}

func init() {
	SchemeBuilder.Register(&DatabaseBackup{}, &DatabaseBackupList{})
}

func (in *DatabaseBackup) DeepCopyInto(out *DatabaseBackup) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	in.Spec.DeepCopyInto(&out.Spec)
	in.Status.DeepCopyInto(&out.Status)
}

func (in *DatabaseBackup) DeepCopy() *DatabaseBackup {
	if in == nil {
		return nil
	}
	out := new(DatabaseBackup)
	in.DeepCopyInto(out)
	return out
}

func (in *DatabaseBackup) DeepCopyObject() runtime.Object {
	return in.DeepCopy()
}

func (in *DatabaseBackupList) DeepCopyInto(out *DatabaseBackupList) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ListMeta.DeepCopyInto(&out.ListMeta)
	if in.Items != nil {
		out.Items = make([]DatabaseBackup, len(in.Items))
		for i := range in.Items {
			in.Items[i].DeepCopyInto(&out.Items[i])
		}
	}
}

func (in *DatabaseBackupList) DeepCopy() *DatabaseBackupList {
	if in == nil {
		return nil
	}
	out := new(DatabaseBackupList)
	in.DeepCopyInto(out)
	return out
}

func (in *DatabaseBackupList) DeepCopyObject() runtime.Object {
	return in.DeepCopy()
}

func (in *DatabaseBackupSpec) DeepCopyInto(out *DatabaseBackupSpec) {
	*out = *in
	if in.Command != nil {
		out.Command = append([]string(nil), in.Command...)
	}
	if in.Args != nil {
		out.Args = append([]string(nil), in.Args...)
	}
	if in.Env != nil {
		out.Env = make([]corev1.EnvVar, len(in.Env))
		for i := range in.Env {
			in.Env[i].DeepCopyInto(&out.Env[i])
		}
	}
	if in.BackoffLimit != nil {
		v := *in.BackoffLimit
		out.BackoffLimit = &v
	}
	if in.TTLSecondsAfterFinished != nil {
		v := *in.TTLSecondsAfterFinished
		out.TTLSecondsAfterFinished = &v
	}
}

func (in *DatabaseBackupStatus) DeepCopyInto(out *DatabaseBackupStatus) {
	*out = *in
	if in.StartTime != nil {
		out.StartTime = in.StartTime.DeepCopy()
	}
	if in.CompletionTime != nil {
		out.CompletionTime = in.CompletionTime.DeepCopy()
	}
	if in.Conditions != nil {
		out.Conditions = make([]metav1.Condition, len(in.Conditions))
		for i := range in.Conditions {
			in.Conditions[i].DeepCopyInto(&out.Conditions[i])
		}
	}
}
