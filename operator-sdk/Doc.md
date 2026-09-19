Here is a comprehensive, production-grade reference guide structured as a Markdown document (`controller-runtime-patterns.md`) that you can commit directly to your repository's `docs/` folder. It consolidates the core patterns, failure modes, the internal mechanics of the `ControllerManager`, and a step-by-step blueprint for writing custom controllers from scratch.

```markdown
# Kubernetes Custom Controller Engineering Guide (`controller-runtime`)

This document outlines the architectural patterns, failure modes, manager lifecycle mechanics, and implementation blueprints for writing production-grade Kubernetes operators using `controller-runtime`.

---

## 1. Core Design Patterns

### Level-Triggered Reconciliation
Kubernetes controllers are **level-triggered**, not edge-triggered. An event (create, update, delete) wakes up the reconciler, but the `Reconcile` loop must inspect the *current actual state* of the cluster and external systems, comparing it against the *desired state* defined in the Custom Resource (CR) spec, and driving them toward convergence regardless of how many events were missed or coalesced.

### The Finalizer Deletion Flow
To safely handle resource teardown (e.g., deleting a remote API object or database entry before the K8s object vanishes):
1. Check if `DeletionTimestamp.IsZero()` is true. If false, the resource is being deleted.
2. Execute cleanup logic against external systems.
3. Once successful, explicitly remove the finalizer string from `ObjectMeta.Finalizers`.
4. Update the object. The API server will then garbage-collect the resource.

### Optimistic Concurrency Control
Because multiple workers or controllers can touch a resource simultaneously, never update status or conditions blindly. Always wrap status writes in a retry-on-conflict loop (`retry.RetryOnConflict`) that fetches the latest resource generation and applies updates cleanly.

---

## 2. Critical Failure Modes & How to Avoid Them

| Failure Mode | Root Cause | Prevention Strategy |
| :--- | :--- | :--- |
| **Infinite Reconcile Loops** | Returning an error or `Requeue: true` without altering state or spec generation. | Only requeue on transient errors with a backoff, or rely on state changes to trigger natural watch events. |
| **The Watch Blindspot** | Filtering watches strictly via `GenerationChangedPredicate` while performing metadata-only updates (like adding finalizers). | Handle metadata updates explicitly, or use composite predicates (`predicate.Or`) that catch annotation/finalizer changes when required. |
| **Cache Staleness / GVK Miss** | Reading directly from a local client cache without an active informer registered for that GroupVersionKind. | Ensure every resource type read or owned by the controller is registered in the scheme and mapped in `SetupWithManager`. |

---

## 3. The `ControllerManager` & Reconciler Lifecycle Algorithm

Understanding how `controller-runtime` orchestrates the control plane helps demystify *when* and *how* your code runs.

### The Manager Startup Algorithm
1. **Scheme Registration:** All API types (core K8s types and your custom CRDs) are registered into a centralized runtime `runtime.Scheme`.
2. **Client & Cache Initialization:** The Manager sets up a shared cache (`client.Reader`), which maintains an in-memory watch cache of objects to reduce load on the API server, paired with a direct writer (`client.Writer`) for mutations.
3. **Runnable & Controller Registration:** Controllers register their reconcilers with the manager via builders (`ctrl.NewControllerManagedBy(mgr)`).
4. **Cache Synchronization (`mgr.Start`):** When `mgr.Start()` is invoked, the manager starts all informers and blocks until all caches are fully synced (`cache.WaitForCacheSync`).
5. **WorkQueue & Worker Pool Dispatch:** 
   - Watch events trigger event handlers (e.g., `enqueueRequestsFromMapFunc`), which place namespaced names into a rate-limiting workqueue.
   - Worker goroutines pull items from the workqueue concurrently and invoke your `Reconcile(ctx, req)` method.

### The Reconcile Loop Execution Flow

```

[Event Trigger / Watch]
│
▼
[WorkQueue Ingestion]
│
▼
[Worker Goroutine Pop] ──► Fetch CR via Cache Client
│
├─► Is DeletionTimestamp set? ──► Run reconcileDelete() ──► Strip Finalizer
│
└─► Normal State? ────────────► Run reconcileNormal() ──► Update Status / Conditions

```

---

## 4. Step-by-Step Blueprint for Writing a Controller

### Step 1: Define Your CRD Spec and Status Structs (`api/v1/types.go`)
Define clear specs for desired state and status structures for conditions, internal IDs, and sync states.

```go
type MyResourceSpec struct {
    TargetName string `json:"targetName"`
    Realm      string `json:"realm"`
}

type MyResourceStatus struct {
    Synced             bool               `json:"synced"`
    ExternalReference  string             `json:"externalReference,omitempty"`
    Conditions         []metav1.Condition `json:"conditions,omitempty"`
}

```

### Step 2: Structure the Reconciler Struct & RBAC Markers

Include the client, scheme, and any external SDK clients or factories. Add kubebuilder RBAC permission markers above your struct.

```go
// +kubebuilder:rbac:groups=example.com,resources=myresources,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=example.com,resources=myresources/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=example.com,resources=myresources/finalizers,verbs=update

type MyResourceReconciler struct {
    client.Client
    Scheme *runtime.Scheme
    ClientFactory ExternalSDKFactory
}

```

### Step 3: Implement the Core Reconcile Logic

Structure your loop to handle fetching, finalizer attachment, normal reconciliation, and error/status reporting:

```go
func (r *MyResourceReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    log := logf.FromContext(ctx)

    var cr examplev1.MyResource
    if err := r.Get(ctx, req.NamespacedName, &cr); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    // 1. Handle Deletion & Finalizers
    if !cr.DeletionTimestamp.IsZero() {
        return r.reconcileDelete(ctx, &cr)
    }
    if !controllerutil.ContainsFinalizer(&cr, "[example.com/finalizer](https://example.com/finalizer)") {
        controllerutil.AddFinalizer(&cr, "[example.com/finalizer](https://example.com/finalizer)")
        if err := r.Update(ctx, &cr); err != nil {
            return ctrl.Result{}, err
        }
        return ctrl.Result{RequeueAfter: 2 * time.Second}, nil
    }

    // 2. Normal Reconciliation (Drive state to target)
    if err := r.reconcileNormal(ctx, &cr); err != nil {
        _ = r.setCondition(ctx, &cr, metav1.ConditionFalse, "Failed", err.Error(), false)
        return ctrl.Result{RequeueAfter: 10 * time.Second}, err
    }

    // 3. Success Status Update
    if err := r.setCondition(ctx, &cr, metav1.ConditionTrue, "Synced", "Resource reconciled", true); err != nil {
        return ctrl.Result{}, err
    }

    return ctrl.Result{}, nil
}

```

### Step 4: Wire Up the Manager (`SetupWithManager`)

Connect your controller to the manager, configure watches, predicates, and owned child resources:

```go
func (r *MyResourceReconciler) SetupWithManager(mgr ctrl.Manager) error {
    return ctrl.NewControllerManagedBy(mgr).
        For(&examplev1.MyResource{}, builder.WithPredicates(
            predicate.Or(
                predicate.GenerationChangedPredicate{},
                predicate.AnnotationChangedPredicate{},
            ),
        )).
        Owns(&corev1.Secret{}). // Optional: if you manage child secrets
        Named("myresource").
        Complete(r)
}

```

```

<FollowUp label="Want to add admission webhook validation logic to this controller guide?" query="Show me how to append webhook validation and mutation code patterns to this controller guide."/>

```
