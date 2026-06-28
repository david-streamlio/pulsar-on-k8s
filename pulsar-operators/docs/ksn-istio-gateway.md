# KSN (Kafka) external access via Istio ingress gateway — operator gap + working configuration

**Status:** Reproduced + worked around. End-to-end Kafka produce/consume through the Istio
ingress gateway is **working** with the workaround below.

## TL;DR (the bug)

`PulsarBroker.spec.advertisedListeners[].istioGateway` generates the per-pod **Gateway** and
**VirtualService**, but **does not generate the per-pod `ServiceEntry`**. The VirtualServices route
to per-pod headless DNS (`<broker>-N.<broker>-headless.<ns>.svc.cluster.local:<containerPort>`),
which Istio does not register as a routable host on its own — so the ingress gateway ends up with an
**empty cluster / `0 chains`** and external Kafka clients cannot reach individual brokers.

The older `spec.istio.gateways[]` code path **does** generate per-pod ServiceEntries
(`MakeDesiredIstioServiceEntryForPod`, `controllers/pulsar/spec/istio.go:177-375`, wired via
`serviceEntryReconciler` in the broker `IstioReconciler`). The newer advertised-listener path
(`controllers/pulsar/spec/istio_advertised_listeners.go`) only wires
`makeAdvListenerGatewayReconciler` + `makeAdvListenerVirtualServiceReconciler` — **no ServiceEntry
reconciler**. That asymmetry is the gap.

**Fix request:** the advertised-listener path should generate per-pod ServiceEntries the same way
`spec.istio.gateways[]` does (and keep them reconciled on scale up/down).

## Environment

| | |
|---|---|
| sn-operator | `v0.18.14` |
| image | `streamnative/private-cloud:4.2.1.4` (KSN 4.2.1.4) |
| Istio | `1.24.3` (`istioctl install --set profile=default`) |
| metadata store | ZooKeeper |
| auth | JWT/token (`AuthenticationProviderToken`), broker TLS via cert-manager |

## Symptoms

With only `spec.advertisedListeners[].istioGateway` configured (PASSTHROUGH), the operator creates
the Gateways + VirtualServices, but:

```
# istiod
gateway pulsar/private-cloud-external-cluster:9093 listener missed network filter
gateway omitting listener "0.0.0.0_9093" due to: must have more than 0 chains in listener "0.0.0.0_9093"

# istioctl analyze -n pulsar
Error [IST0101] (VirtualService private-cloud-external-private-cloud-broker-0)
  Referenced host not found: "private-cloud-broker-0.private-cloud-broker-headless.pulsar.svc.cluster.local"

# istioctl proxy-config endpoints deploy/istio-ingressgateway -n istio-system
# (no endpoints for the per-pod outbound|9095||...broker-0...headless... cluster)
```

Kafka clients bootstrap OK against the cluster address but then fail per-broker with
`Connection ... terminated during authentication` / `SSL handshake failed`, and produce/consume
time out.

## Root cause

`outbound|<port>||<pod>.<headless-svc>...` clusters have **no endpoints** because Istio has no
service-registry entry for the per-pod headless hostname referenced by the VirtualService. The
`spec.istio.gateways[]` path solves this with a per-pod ServiceEntry; the advertised-listener path
omits it.

## Workaround — per-pod ServiceEntry (the missing resource)

One per broker pod (`resolution: DNS` lets Envoy resolve the headless pod DNS to the pod IP, so it
survives pod IP changes; `STATIC` with the pod IP also works, matching what the operator generates):

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: broker-0-kafka-ext
  namespace: pulsar
spec:
  hosts: ["private-cloud-broker-0.private-cloud-broker-headless.pulsar.svc.cluster.local"]
  location: MESH_INTERNAL
  ports:
    - { number: 9095, name: tcp-kafka-ext, protocol: TCP }
  resolution: DNS
```

After applying, the per-pod cluster reports `HEALTHY` endpoints and the `9093` listener is
programmed.

> **Do NOT enable `spec.istio` (mesh/sidecars) to "fix" this.** Meshing the brokers creates
> `ISTIO_MUTUAL` DestinationRules, so the gateway attempts Istio-mTLS to the broker instead of TLS
> **PASSTHROUGH** → `SSL handshake failed`. The ServiceEntry does not require the brokers to be on
> the mesh.

## Full working configuration

1. **Istio 1.24.3** (operator emits `networking.istio.io/v1`; older Istio that only serves
   `v1beta1`/`v1alpha3` rejects it). Add the Kafka port to the ingress Service:
   ```bash
   kubectl patch svc istio-ingressgateway -n istio-system --type=json \
     -p '[{"op":"add","path":"/spec/ports/-","value":{"name":"kafka-tls","port":9093,"targetPort":9093,"protocol":"TCP"}}]'
   ```

2. **TLS for the broker's external KSN listener** — KSN needs a **JKS keystore** at
   `/etc/tls/pulsar-kop/keystore.jks` (a PEM-only secret yields `KeyStore Path not accessible`).
   cert-manager can emit one:
   ```yaml
   apiVersion: cert-manager.io/v1
   kind: Certificate
   metadata: { name: kafka-broker-tls, namespace: pulsar }
   spec:
     secretName: kafka-broker-tls
     issuerRef: { name: pulsar-ca-issuer, kind: Issuer }
     commonName: kafka.private-cloud.internal
     dnsNames: ["kafka.private-cloud.internal", "*.kafka.private-cloud.internal"]
     keystores:
       jks:
         create: true
         passwordSecretRef: { name: kafka-keystore-pass, key: password }
   ```

3. **PulsarBroker** (TLS PASSTHROUGH; broker terminates TLS):
   ```yaml
   spec:
     config:
       protocolHandlers:
         kop:
           enabled: true
           saslAllowedMechanisms: [PLAIN]
           tls:
             enabled: true
             certSecretName: kafka-broker-tls
             trustCertsEnabled: true
             clientAuth: none
             passwordSecretRef: { name: kafka-keystore-pass, key: password }
     advertisedListeners:
       - name: external
         hostTemplate: "$(POD_NAME).kafka.private-cloud.internal"        # $(POD_ID) is NOT a broker env var
         protocols:
           pulsar: { enabled: false }                 # else an external pulsar listener double-binds 6651
           kafka:  { enabled: true, scheme: SASL_SSL, advertisedPort: 9093, containerPort: 9095 }
         istioGateway:
           clusterAddress: kafka.private-cloud.internal
           selector: { istio: ingressgateway }
           tls: { mode: PASSTHROUGH }
   ```

4. **Per-pod ServiceEntries** (the workaround above), one per replica.

5. **Client DNS:** `kafka.private-cloud.internal` and `*.kafka.private-cloud.internal` → ingress gateway LB IP. Kafka client config:
   ```properties
   security.protocol=SASL_SSL
   sasl.mechanism=PLAIN
   sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="public/default" password="token:<jwt>";
   ssl.truststore.type=PEM
   ssl.truststore.location=/path/to/ca.crt
   ```

## Gotchas encountered (all real)

| Symptom | Cause / fix |
|---|---|
| KSN `Listener '...$(POD_ID)...' is invalid` crash | use `$(POD_NAME)` in `hostTemplate` (POD_ID isn't a broker env var) |
| Broker crashloop, double-bind `:9092` / `:6651` | external Kafka needs a **distinct** containerPort (9095); `protocols.pulsar.enabled: false` |
| No Gateway/VirtualService generated at all | operator cached "Istio not installed"; **restart sn-operator** after installing Istio |
| `listener missed network filter / 0 chains` | `tls.mode: SIMPLE` emits SNI routes that can't match after termination — use **PASSTHROUGH** for TCP/Kafka |
| `KeyStore Path not accessible: .../keystore.jks` | KSN needs JKS; add `keystores.jks` to the cert-manager Certificate + `kop.tls.passwordSecretRef` |
| `Referenced host not found` / empty per-pod endpoints | **the gap** — add per-pod ServiceEntries |
| `SSL handshake failed` per-broker | don't mesh the brokers; `ISTIO_MUTUAL` DestinationRules break PASSTHROUGH |
