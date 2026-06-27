StreamNative Private Cloud on Kubernetes (v2)
-----------

This follows the StreamNative Private Cloud **v2 quick start**:
https://docs.streamnative.io/private-cloud/v2/quick-start/private-cloud-quickstart

A single `sn-operator` reconciles a `PulsarCoordinator` plus the component CRs
(`ZooKeeperCluster`/`OxiaCluster`, `BookKeeperCluster`, `PulsarBroker`,
`PulsarProxy`, `Console`). Pick **one** metadata store:

| Manifest | Metadata store | Notes |
| --- | --- | --- |
| `configs/01-pulsar-cluster.yaml` | ZooKeeper | minimal/basic ZK (no auth/TLS) |
| `configs/02-pulsar-oxia.yaml` | Oxia (no ZooKeeper) | full-featured (JWT auth, TLS, HPA); **no package management** (see below) |
| `configs/03-pulsar-zookeeper.yaml` | ZooKeeper | full-featured **+ package management / jar functions** |

> **Oxia vs ZooKeeper — package management:** Oxia-backed v2 clusters **do not support
> function package management** (the BookKeeper package store needs a ZooKeeper
> DistributedLog namespace; enabling it crashes the broker on Oxia). If you want to
> upload **jar/nar packages** and run **Function-Mesh jar functions** (no MinIO, no
> per-function images), use the **ZooKeeper** manifest (`03-pulsar-zookeeper.yaml`).
> Oxia remains the choice for a ZK-free architecture where packages aren't needed.

### One-command deploy

`deploy.sh` brings up the whole MCP-enhanced stack end to end — operator → license →
JWT auth secrets → cert-manager/TLS → Oxia cluster → the snmcp MCP server:

```bash
# provide a license first (see step 2️⃣), then:
./pulsar-operators/deploy.sh
# microk8s:
KUBECTL="microk8s kubectl" HELM="microk8s helm3" ./pulsar-operators/deploy.sh
```

It's idempotent (re-runnable) and prints the MCP endpoint at the end. Toggle TLS with
`ENABLE_TLS=false`. The sections below document each step if you'd rather run them by hand.

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

### MCP server (snmcp)

The StreamNative MCP server runs **in the `pulsar` namespace** (via `snmcp-values.yaml`)
so it reaches the cluster over in-cluster DNS:

```bash
helm install snmcp streamnative/snmcp -n pulsar -f ./pulsar-operators/configs/snmcp-values.yaml
```

- **Pulsar URL** is pinned to the in-cluster proxy (`…proxy.pulsar.svc.cluster.local:8080/6650`).
- **Auth = multi-session passthrough:** no token is stored on the server — each caller
  sends `Authorization: Bearer <pulsar-token>`, which snmcp forwards to Pulsar (so the
  MCP session inherits exactly what that token authorizes). Use the `client` token for
  scoped access or a superuser token for admin.
- Exposed on a **LoadBalancer** (`:9090`) for a LAN MCP client (e.g. Claude Desktop):

```
MCP endpoint : http://<snmcp-LB-ip>:9090/mcp
Auth header  : Authorization: Bearer <pulsar token>
```

### Functions: `functions create --jar` via Orca (Function Mesh Worker Service)

`03-pulsar-zookeeper.yaml` enables **Orca / FMWS** on the broker — the bundled
`mesh-worker-service.nar` turns the functions-worker into a translator, so the familiar
CLI workflow creates **Function Mesh `Function` CRDs** (jar in package management, stock
runner image, no hand-written CRDs). The operator's `function.mesh` field alone doesn't
wire the NAR — it's injected via `config.function.customWorkerConfig` (`functionsWorkerServiceNarPackage`
+ `functionsWorkerServiceCustomConfigs` with `functionRunnerImages`).

```bash
# (token required since auth is on; the broker's bundled examples jar):
kubectl exec -n pulsar -c pulsar-broker private-cloud-broker-0 -- \
  ./bin/pulsar-admin --auth-plugin org.apache.pulsar.client.impl.auth.AuthenticationToken \
  --auth-params "token:$ADMIN" functions create \
  --tenant public --namespace default --name myfn \
  --className org.apache.pulsar.functions.api.examples.ExclamationFunction \
  --inputs persistent://public/default/in --output persistent://public/default/out \
  --jar /pulsar/examples/api-examples.jar
# -> a `Function` CRD appears (kubectl get function -n pulsar); FMWS auto-propagates the
#    caller's token into the function and uses the configured runner image.
```

For full control you can still apply a `Function` CRD directly — see
`function-mesh-operator/configs/01-package-url-function.yaml` (with its gotchas).

### Cleanup

```bash
helm uninstall snmcp -n pulsar                                         # MCP server
kubectl delete -f ./pulsar-operators/configs/01-pulsar-cluster.yaml   # or 02-pulsar-oxia.yaml
kubectl delete pvc --all -n pulsar                                     # removes data volumes
helm uninstall sn-operator -n operators
```

References
------------
- https://docs.streamnative.io/private-cloud/v2/quick-start/private-cloud-quickstart
