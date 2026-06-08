# Homelab Capacity Reclaim

A safe, idempotent utility for **single-node OpenShift labs** that removes
operators which are pure overhead on one node, so heavier workloads (like the
AAP automation controller) can schedule.

> Context: on a single 64 GB SNO running RHOAI/Granite, OpenShift Lightspeed,
> AAP, and a service mesh, the node becomes **request-saturated** — pods can't
> schedule even though actual memory use is lower, because the scheduler honors
> resource *requests*. Removing unused operators returns that reserved capacity.

## What it removes (by default)

| Stack | Why it's safe to remove on a lab |
|-------|----------------------------------|
| Advanced Cluster Management (ACM) + MultiCluster Engine (MCE) | Multi-cluster fleet manager — pointless on one node; largest reclaim |
| Red Hat OpenShift Service Mesh 3 (Istio) | Not needed unless a meshed app demo must stay live |
| Kiali | Mesh observability UI; goes with Service Mesh |

It does **not** touch AAP, RHOAI/Granite, OpenShift Lightspeed, core OpenShift,
or monitoring. The operator name-match logic is exact and was verified not to
select those — keeping your AI-assistant demo (OLS + Granite) intact.

## Safety design

- **Idempotent** — re-running skips anything already gone.
- **Finalizer-safe order** — deletes operands (custom resources) first, waits
  for their pods to drain, *then* removes the Subscription and CSV. This is what
  prevents stuck `Terminating` namespaces.
- **Missing-CRD tolerant** — if a stack was never installed, its steps no-op.
- **Selective** — skip any stack with a flag.

## Prerequisites

- `oc` logged in as **cluster-admin** (uses your kubeconfig).
- `kubernetes.core` collection + the `kubernetes` Python package.

## Run

```bash
ansible-galaxy collection install -r requirements.yml
pip install kubernetes

# Remove all three stacks (default):
ansible-playbook reclaim_capacity.yml

# Keep Service Mesh + Kiali (e.g. an OpenEMR-on-mesh demo must stay live),
# remove only ACM:
ansible-playbook reclaim_capacity.yml -e remove_service_mesh=false -e remove_kiali=false
```

The play prints the node's allocated-resources summary at the end so you can see
the reclaim. Then check the controller:

```bash
oc get pods -n aap | grep aap-controller
oc describe node | grep -A5 "Allocated resources"
```

Target memory **requests** comfortably under ~80% so the controller's task
(4 containers) and web (3 containers) pods can land.

## If a namespace gets stuck Terminating

Almost always an orphaned operand CR holding a finalizer. Use the helper:

```bash
# First, find leftover CRs in the namespace:
oc api-resources --verbs=list --namespaced -o name \
  | xargs -n1 oc get -n <ns> --ignore-not-found 2>/dev/null | grep -v '^$'
# Remove any leftovers, then if still stuck:
ansible-playbook tasks/clear_stuck_namespace.yml -e ns=<namespace>
```

## Reversibility

This removes operators, not your data/config for *other* workloads. To get any
stack back, reinstall its operator from OperatorHub and recreate its operand CR.
Don't run this against a cluster where these stacks are in real use.
