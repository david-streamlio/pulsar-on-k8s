StreamNative Private Cloud on Kubernetes (v2)
-----------

This follows the StreamNative Private Cloud **v2 quick start**:
https://docs.streamnative.io/private-cloud/v2/quick-start/private-cloud-quickstart

A single `sn-operator` reconciles a `PulsarCoordinator` plus the component CRs
(`ZooKeeperCluster`/`OxiaCluster`, `BookKeeperCluster`, `PulsarBroker`,
`PulsarProxy`, `Console`). Pick **one** metadata store:

| Manifest | Metadata store | Operator required |
| --- | --- | --- |
| `configs/01-pulsar-cluster.yaml` | ZooKeeper (default) | works on older operators |
| `configs/02-pulsar-oxia.yaml` | Oxia (no ZooKeeper) | needs a recent `sn-operator` — see note below |

### Prerequisites

- Kubernetes v1.16+ with `kubectl` (±1 minor of the cluster) and `helm` v3.0.2+
- A StreamNative Private Cloud license token

### 1️⃣ Create the operators namespace

```bash
kubectl create namespace operators
```

### 2️⃣ Install the license

Copy the template to the real (git-ignored) filename, replace
`REPLACE_WITH_YOUR_LICENSE_TOKEN` with your license JWT, then apply it. The
`cloud.streamnative.io/type: "license"` label is **required** — the operator
auto-detects the license by that label.

> ⚠️ `00-license-secret.yaml` is git-ignored so the real token is never committed;
> only `00-license-secret.yaml.template` is tracked. Alternatively, create the
> secret straight from a key file without a YAML at all:
> `kubectl create secret generic sn-license -n operators --from-file=license=./sn-license.key`
> then `kubectl label secret sn-license -n operators cloud.streamnative.io/type=license`.

```bash
cp ./pulsar-operators/configs/00-license-secret.yaml.template \
   ./pulsar-operators/configs/00-license-secret.yaml
# edit the copy, then:
kubectl apply -f ./pulsar-operators/configs/00-license-secret.yaml
```

### 3️⃣ Install the operator

```bash
helm repo add streamnative https://charts.streamnative.io
helm repo update
helm install sn-operator streamnative/sn-operator -n operators
```

To restrict the operator to specific namespaces instead of cluster-wide:

```bash
helm install sn-operator streamnative/sn-operator -n operators \
  --set watchNamespaces="pulsar\,pulsar-staging"
```

Verify:

```bash
kubectl get all -n operators
```

### 4️⃣ Create the pulsar namespace

```bash
kubectl create ns pulsar
```

### 5️⃣ Deploy the Pulsar cluster

**Option A — ZooKeeper (default):**

```bash
kubectl apply -f ./pulsar-operators/configs/01-pulsar-cluster.yaml
```

**Option B — Oxia (no ZooKeeper):**

```bash
kubectl apply -f ./pulsar-operators/configs/02-pulsar-oxia.yaml
```

Watch it come up:

```bash
kubectl get pods -n pulsar -w
```

### Storage classes (this repo's lab)

The BookKeeper (and ZooKeeper/Oxia) volumes in these manifests are pinned to the
local storage classes used in this cluster:

| Component | Volume | StorageClass | Size |
| --- | --- | --- | --- |
| BookKeeper | journal | `nvme-raid` | 30Gi |
| BookKeeper | ledger | `ssd-raid` | 100Gi |
| ZooKeeper | data / dataLog | `nvme-raid` | 8Gi / 2Gi |
| Oxia | server | `nvme-raid` | 4Gi |

Adjust `storageClassName` / `storage` requests for your environment.

### Image versions

`01-pulsar-cluster.yaml` pins `streamnative/private-cloud:3.3.2.7` (matching the
upstream ZK quick-start); `02-pulsar-oxia.yaml` pins `streamnative/private-cloud:4.0.4.1`.
Keep these consistent with the `sn-operator` version you install.

> ⚠️ **Operator compatibility for the Oxia path.** `02-pulsar-oxia.yaml` uses
> `StorageCatalog`, the 5-namespace `OxiaNamespace` layout, and
> `PulsarBroker.spec.config.useStorageCatalog`. These require a recent
> `sn-operator` (chart ≥ `v0.18.x`). Older operators (e.g. chart `v0.2.5` /
> app `v0.8.5`) will reject these fields — `helm upgrade sn-operator
> streamnative/sn-operator -n operators` first. The ZooKeeper manifest
> (`01-pulsar-cluster.yaml`) applies cleanly on older operators.

### Post-installation

Open a client shell on the toolset pod:

```bash
kubectl exec -it private-cloud-toolset-0 -n pulsar -- bash
```

Port-forward the console:

```bash
kubectl port-forward private-cloud-console-0 9527:9527 -n pulsar
```

### Cleanup

```bash
kubectl delete -f ./pulsar-operators/configs/01-pulsar-cluster.yaml   # or 02-pulsar-oxia.yaml
kubectl delete pvc --all -n pulsar                                     # removes data volumes
helm uninstall sn-operator -n operators
```

References
------------
- https://docs.streamnative.io/private-cloud/v2/quick-start/private-cloud-quickstart
