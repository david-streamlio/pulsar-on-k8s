# [BUG] advertisedListeners[].istioGateway does not generate per-pod ServiceEntries → external Kafka (KSN) per-broker routing fails

## Summary

When exposing Kafka (KSN) externally via `PulsarBroker.spec.advertisedListeners[].istioGateway`, the
operator generates the per-pod **Gateway** and **VirtualService** resources but **does not generate
the per-pod `ServiceEntry`**. The generated VirtualServices route to per-pod headless DNS
(`<broker>-N.<broker>-headless.<ns>.svc.cluster.local:<containerPort>`), which Istio does not have in
its service registry, so the ingress gateway builds an empty cluster and omits the listener
(`must have more than 0 chains`). Kafka clients can bootstrap against the cluster address but cannot
reach individual brokers (`SSL handshake failed` / `terminated during authentication`), so
produce/consume time out.

The older `spec.istio.gateways[]` code path **does** generate per-pod ServiceEntries
(`MakeDesiredIstioServiceEntryForPod`, `controllers/pulsar/spec/istio.go`, wired via
`serviceEntryReconciler`). The advertised-listener path
(`controllers/pulsar/spec/istio_advertised_listeners.go`) wires only Gateway + VirtualService
reconcilers and omits the ServiceEntry reconciler. This asymmetry is the bug.

## Affected versions

- sn-operator: **v0.18.14**
- image: **streamnative/private-cloud:4.2.1.4** (KSN 4.2.1.4)
- Istio: **1.24.3**
- metadata store: ZooKeeper; auth: JWT/token; broker TLS via cert-manager

## Steps to reproduce

1. Cluster with KSN enabled (`config.protocolHandlers.kop.enabled: true`) and a JKS keystore for the
   external Kafka listener (`config.protocolHandlers.kop.tls`).
2. Install Istio 1.24.x; add port 9093 to the `istio-ingressgateway` Service.
3. Configure an advertised listener with an Istio gateway (TLS PASSTHROUGH):

   ```yaml
   spec:
     advertisedListeners:
       - name: external
         hostTemplate: "$(POD_NAME).kafka.private-cloud.internal"
         protocols:
           pulsar: { enabled: false }
           kafka:  { enabled: true, scheme: SASL_SSL, advertisedPort: 9093, containerPort: 9095 }
         istioGateway:
           clusterAddress: kafka.private-cloud.internal
           selector: { istio: ingressgateway }
           tls: { mode: PASSTHROUGH }
   ```

4. Point `kafka.private-cloud.internal` and `*.kafka.private-cloud.internal` at the ingress gateway LB IP and run a Kafka client
   (`security.protocol=SASL_SSL`, SASL/PLAIN token, PEM truststore of the cluster CA):

   ```bash
   kafka-console-producer.sh --bootstrap-server kafka.private-cloud.internal:9093 --producer.config c.properties --topic t
   ```

## Expected behavior

The operator generates everything needed for external per-broker access (Gateway + VirtualService +
**ServiceEntry**), and Kafka clients can produce/consume against individual brokers — the same way
`spec.istio.gateways[]` works.

## Actual behavior

Per-broker connections fail; produce/consume time out. The ingress gateway never programs the Kafka
listener because the per-pod destination clusters have no endpoints.

## Evidence

istiod:
```
gateway pulsar/private-cloud-external-private-cloud-broker-0:9093 listener missed network filter
gateway omitting listener "0.0.0.0_9093" due to: must have more than 0 chains in listener "0.0.0.0_9093"
```

`istioctl analyze -n pulsar`:
```
Error [IST0101] (VirtualService private-cloud-external-private-cloud-broker-0)
  Referenced host not found: "private-cloud-broker-0.private-cloud-broker-headless.pulsar.svc.cluster.local"
```

`istioctl proxy-config endpoints deploy/istio-ingressgateway -n istio-system` — no endpoints for the
per-pod `outbound|9095||private-cloud-broker-0.private-cloud-broker-headless...` cluster.

Kafka client:
```
Connection to node ... (private-cloud-broker-0.kafka.private-cloud.internal/<gw-ip>:9093) terminated during authentication
... failed authentication due to: SSL handshake failed
TimeoutException: Topic t not present in metadata after 60000 ms
```

## Root cause

The per-pod VirtualService destination (per-pod headless DNS) is not registered in Istio's service
registry, so its cluster has no endpoints and the TLS-PASSTHROUGH listener is dropped. The
`spec.istio.gateways[]` path registers it via a per-pod ServiceEntry; the advertised-listener path
does not.

## Proposed fix

Generate per-pod `ServiceEntry` resources in the advertised-listener Istio path (mirroring
`MakeDesiredIstioServiceEntryForPod`), and reconcile them on broker scale up/down. Each ServiceEntry
should register the per-pod host + the listener's container port, e.g.:

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata: { name: <broker>-<listener>-<pod>, namespace: <ns> }
spec:
  hosts: ["<broker>-N.<broker>-headless.<ns>.svc.cluster.local"]
  location: MESH_INTERNAL
  ports: [{ number: <containerPort>, name: tcp-<listener>, protocol: TCP }]
  resolution: DNS   # or STATIC with the pod IP
```

## Workaround

Manually create one ServiceEntry per broker pod (as above). After applying, the per-pod clusters
report `HEALTHY` endpoints, the 9093 listener is programmed, and produce/consume succeed.

**Note:** Do **not** enable `spec.istio` (sidecar mesh) to work around this — meshing the brokers
creates `ISTIO_MUTUAL` DestinationRules, which make the gateway attempt Istio-mTLS to the broker
instead of TLS PASSTHROUGH, causing `SSL handshake failed`. The ServiceEntry workaround does not
require the brokers to be on the mesh.

## Additional gotchas observed (may warrant doc fixes)

- `hostTemplate` must use `$(POD_NAME)`; `$(POD_ID)` is not a broker env var and yields a literal
  string → KSN `Listener '...' is invalid` crash.
- The external Kafka listener needs a **distinct** containerPort; reusing the internal `9092`
  double-binds and crashes the broker. An external listener with `protocols.pulsar` enabled
  double-binds `6651`.
- The operator caches "Istio not installed" — installing Istio after the operator is running
  requires an operator restart before any Gateway/VirtualService is generated.
- `tls.mode: SIMPLE` emits SNI-match routes that cannot match after TLS termination for a TCP
  service → `listener missed network filter / 0 chains`. PASSTHROUGH is required for Kafka.
- KSN requires a JKS keystore at `/etc/tls/pulsar-kop/keystore.jks`; a PEM-only secret yields
  `KeyStore Path not accessible`.
