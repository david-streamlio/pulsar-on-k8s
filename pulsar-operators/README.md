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

### JWT authentication (token auth)

`02-pulsar-oxia.yaml` is wired for JWT/token authentication
(`AuthenticationProviderToken`) per the
[StreamNative private-cloud JWT auth guide](https://docs.streamnative.io/private-cloud/v2/configure-private-cloud/security/authentication/private-cloud-jwt-auth).
The manifest references four secrets that you generate locally (keys/tokens are
**never** committed — see `.gitignore`):

```bash
# 1) RS256 key pair (snctl == pulsarctl token tooling)
snctl pulsar admin token create-key-pair \
  --output-private-key token-private.key --output-public-key token-public.key

# 2) Mint subject tokens (stdout is on stderr; capture both)
for s in broker-admin proxy-admin client; do
  snctl pulsar admin token create --private-key-file token-private.key --subject "$s" 2>&1 \
    | grep -oE 'eyJ[A-Za-z0-9_.-]+' > "$s.token"
done

# 3) Create the secrets the manifest expects (pulsar namespace)
kubectl create secret generic token-public-key -n pulsar --from-file=my-public.key=token-public.key
kubectl create secret generic broker-admin -n pulsar --from-file=token=broker-admin.token
kubectl create secret generic proxy-admin  -n pulsar --from-file=token=proxy-admin.token
kubectl create secret generic client       -n pulsar --from-file=token=client.token
```

Key points in the manifest:

- Keys live under `config.custom` as `PULSAR_PREFIX_*` (this cluster sets
  `enable-config-prefix: false`, so custom keys pass through verbatim).
- `superUserRoles: broker-admin,proxy-admin`; **`proxyRoles: proxy-admin`** is
  required so the broker trusts the proxy to forward the original client identity.
- `config.clientAuth.jwt.secret` + `pod.vars` provide each component's own client token;
  `pod.secretRefs` mounts the public key at `/mnt/secrets/my-public.key`.

Point `snctl` at the cluster with a superuser token:

```bash
snctl context update-external private-cloud --token "$(cat broker-admin.token)"
snctl pulsar admin tenants list      # works with token; 401 without
```

### TLS (encryption in transit)

`03-pulsar-tls.yaml` provisions the certs with **cert-manager** (self-signed CA →
CA issuer → server cert with broker/proxy SANs + the LB IP). Install cert-manager
first (`kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml`),
then `kubectl apply -f ./pulsar-operators/configs/03-pulsar-tls.yaml`.

The **broker** uses the operator-native `spec.tls` (`certSecretName: pulsar-server-tls`),
which mounts the cert at `/etc/tls/pulsar-broker/` and enables both the web TLS port
(8443) and the binary TLS listener (`pulsar+ssl://…:6651` via `advertisedListeners`).
Do **not** also set `PULSAR_PREFIX_brokerServicePortTls` — it double-binds 6651 and
crashloops the broker. Verify (from a broker pod):

```bash
# binary TLS
./bin/pulsar-client --url pulsar+ssl://localhost:6651 \
  --auth-plugin org.apache.pulsar.client.impl.auth.AuthenticationToken \
  --auth-params "token:$(cat broker-admin.token)" \
  --tlsTrustCertsFilePath /etc/tls/pulsar-broker/ca.crt \
  produce public/default/t -m hi -n 1
# admin/web TLS
curl --cacert /etc/tls/pulsar-broker/ca.crt -H "Authorization: Bearer <token>" \
  https://localhost:8443/admin/v2/clusters
```

> **Known limitation (follow-up):** proxy / external **LoadBalancer** TLS is not
> enabled. In operator v0.18.14 the proxy Service/LoadBalancer doesn't publish the
> TLS ports (6651/8443) — neither `certSecretName` nor `config.custom` gets them
> exposed — so external clients still use plaintext + token via the LB.

### Cleanup

```bash
kubectl delete -f ./pulsar-operators/configs/01-pulsar-cluster.yaml   # or 02-pulsar-oxia.yaml
kubectl delete pvc --all -n pulsar                                     # removes data volumes
helm uninstall sn-operator -n operators
```

References
------------
- https://docs.streamnative.io/private-cloud/v2/quick-start/private-cloud-quickstart
