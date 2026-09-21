Operator SDK's Go plugin is built on kubebuilder. The project layout, markers and reconcile code are the same as before, and the SDK adds bundle, OLM and scorecard tooling on top.

**1. Install and check prerequisites**
You need `operator-sdk`, Go, Docker (or podman), and `kubectl` access to a cluster (kind or minikube works for testing).

**2. Initialize the project**
```bash
mkdir db-operator && cd db-operator
operator-sdk init --domain example.com --repo github.com/me/db-operator
```
Add `--plugins=helm` or `--plugins=ansible` instead if you'd rather drive reconciliation from a Helm chart or Ansible roles. The rest of these steps assume Go.

**3. Create the API and controller**
```bash
operator-sdk create api --group apps --version v1 --kind Database --resource --controller
```
This generates `api/v1/database_types.go` and `internal/controller/database_controller.go`. Older SDK versions put the controller under `controllers/`.

**4. Define the spec and status**
In `database_types.go`, add fields and validation markers:
```go
type DatabaseSpec struct {
    // +kubebuilder:validation:Minimum=1
    Replicas int32  `json:"replicas"`
    Version  string `json:"version"`
}
type DatabaseStatus struct {
    ReadyReplicas int32              `json:"readyReplicas,omitempty"`
    Conditions    []metav1.Condition `json:"conditions,omitempty"`
}
```
Keep the `+kubebuilder:subresource:status` marker on the type so `status` updates go through the status subresource. Then regenerate:
```bash
make generate manifests
```

**5. Write the reconcile loop**
In the controller, add RBAC markers, then implement `Reconcile`:
```go
// +kubebuilder:rbac:groups=apps.example.com,resources=databases,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=apps.example.com,resources=databases/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=apps,resources=statefulsets,verbs=get;list;watch;create;update;patch;delete

func (r *DatabaseReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
    var db appsv1.Database
    if err := r.Get(ctx, req.NamespacedName, &db); err != nil {
        return ctrl.Result{}, client.IgnoreNotFound(err)
    }

    sts := &kappsv1.StatefulSet{ObjectMeta: metav1.ObjectMeta{Name: db.Name, Namespace: db.Namespace}}
    _, err := controllerutil.CreateOrUpdate(ctx, r.Client, sts, func() error {
        sts.Spec.Replicas = &db.Spec.Replicas
        // ...selector, template, image from db.Spec.Version
        return controllerutil.SetControllerReference(&db, sts, r.Scheme)
    })
    if err != nil {
        return ctrl.Result{}, err
    }

    db.Status.ReadyReplicas = sts.Status.ReadyReplicas
    meta.SetStatusCondition(&db.Status.Conditions, metav1.Condition{
        Type: "Ready", Reason: "Reconciled",
        Status: boolToStatus(sts.Status.ReadyReplicas == db.Spec.Replicas),
    })
    return ctrl.Result{}, r.Status().Update(ctx, &db)
}
```
Two pieces are placeholders: the elided StatefulSet template, and `boolToStatus`, a small helper you write to return `metav1.ConditionTrue` or `metav1.ConditionFalse`.

Register the watches in `SetupWithManager`:
```go
return ctrl.NewControllerManagedBy(mgr).
    For(&appsv1.Database{}).
    Owns(&kappsv1.StatefulSet{}).
    Complete(r)
```

The loop rules are unchanged:
- The loop must be idempotent and level-based.
- Set owner references on children.
- Return an error to retry with backoff, and use `RequeueAfter` to poll.
- Use `controllerutil.AddFinalizer` only if you own external resources that need cleanup.

**6. Run it locally**
```bash
make install run      # installs the CRD, runs the controller from your machine
kubectl apply -f config/samples/apps_v1_database.yaml
kubectl get database,sts,pods -w
```
Watch the controller log while you edit the sample. Change `replicas` and confirm the StatefulSet follows. Delete a child and confirm it is recreated.

**7. Test**
`make test` runs the `envtest` suite, which uses a real API server and etcd with no full cluster. Put reconcile assertions there.

**8. Build and deploy**
```bash
make docker-build docker-push IMG=registry.example.com/db-operator:v0.1.0
make deploy IMG=registry.example.com/db-operator:v0.1.0
```

**9. Package for OLM, which is the SDK-specific part**
```bash
make bundle IMG=registry.example.com/db-operator:v0.1.0
operator-sdk bundle validate ./bundle
make bundle-build bundle-push BUNDLE_IMG=registry.example.com/db-operator-bundle:v0.1.0
operator-sdk olm install                     # once per cluster
operator-sdk run bundle registry.example.com/db-operator-bundle:v0.1.0
operator-sdk scorecard ./bundle              # basic and OLM conformance tests
operator-sdk cleanup db-operator             # uninstall
```
Edit `config/manifests/bases/*.clusterserviceversion.yaml` first to set the display name, description, icon and install modes. Without that, `make bundle` produces a bare CSV.

**Pitfalls**
- Forgetting `make manifests` after changing types or RBAC markers leaves stale CRDs and 403 errors.
- Namespace-scoped versus cluster-scoped is set at `create api` time (`--namespaced=false`) and in the CSV install modes. Decide it early.
- Editing generated files such as `zz_generated.deepcopy.go` or `config/crd/bases` gets overwritten. Change the types and markers instead.
- A `Watch` on external objects needs matching RBAC and a mapper.

I can go deeper on finalizers, webhooks (`operator-sdk create webhook`) or the Helm or Ansible variants if you want.