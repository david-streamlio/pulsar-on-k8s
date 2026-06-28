# LAN endpoints & DNS naming

Single source of truth for the lab's externally-reachable IPs and the DNS names that
front them. The names are served by the in-cluster dnsmasq edge resolver
(`configs/05-kafka-dns.yaml`, LoadBalancer `192.168.0.206`); point a client's resolver
at that IP to use them.

## DNS naming scheme

`<service>.<cluster>.internal`

- **Root `.internal`** — the ICANN-reserved private-use TLD (the DNS analogue of RFC 1918
  private IPs). Never delegated publicly, so no collision risk; certs must come from a
  private CA (we use `pulsar-ca`), which is what we do anyway.
- **`<service>` leftmost** — required by Kafka: KSN advertises per-broker names, so the
  Kafka zone must be independently wildcardable (`*.kafka.<cluster>.internal`).
- **`<cluster>`** = the Pulsar cluster name (`private-cloud`). Multi-cluster later is free:
  `kafka.cluster-b.internal`.

Wildcards only where membership is dynamic (Kafka brokers under HPA). Everything stable is
an explicit record (safer — typos NXDOMAIN instead of silently resolving; gives reverse PTR).

## Service endpoints

| Name | IP | Ports | Backed by | Notes |
|------|----|-------|-----------|-------|
| `kafka.private-cloud.internal` (+ `*.`) | 192.168.0.205 | 9093 | `istio-ingressgateway` (istio-system) | KSN, SASL_SSL + `token:<jwt>`. Wildcard = per-broker SNI passthrough; tracks HPA scale-up. |
| `pulsar.private-cloud.internal` | 192.168.0.200 | 6650 (binary), 8080 (admin) | `private-cloud-proxy-external` | Pulsar protocol, **plaintext + token** (proxy TLS not exposed externally — see follow-up #9). |
| `mqtt.private-cloud.internal` | 192.168.0.207 | 1883 → 5682 | `private-cloud-mqtt-external` | MQTT (MoP). LB forwards to the brokers' MoP routing proxy (5682). **Token auth** (JWT as the MQTT CONNECT password); single record (proxy routes across brokers). |
| (snmcp) | 192.168.0.203 | 9090 | `snmcp` | StreamNative MCP server (`/mcp`); Bearer pulsar token passthrough. No DNS name yet. |
| (dnsmasq) | 192.168.0.206 | 53 | `kafka-dnsmasq` | This resolver itself. |

## Node / infra records (mirror of each node's `/etc/hosts`)

| Names | IP |
|-------|----|
| `k8s-node00.kubernetes.net`, `k8s-node00`, `etcd-node00` | 192.168.0.80 |
| `k8s-node01.kubernetes.net`, `k8s-node01`, `etcd-node01` | 192.168.0.81 |
| `k8s-node02.kubernetes.net`, `k8s-node02`, `etcd-node02` | 192.168.0.82 |

## Connection strings

- **Kafka:** `kafka.private-cloud.internal:9093` — `security.protocol=SASL_SSL`,
  `sasl.mechanism=PLAIN`, `password="token:<jwt>"`, PEM truststore = `pulsar-ca` `ca.crt`.
- **Pulsar:** `pulsar://pulsar.private-cloud.internal:6650`, admin
  `http://pulsar.private-cloud.internal:8080` — `AuthenticationToken` `<jwt>`.
- **MQTT:** `mqtt.private-cloud.internal:1883` — MQTT CONNECT with any username and the
  JWT as the **password** (MoP token auth). e.g.
  `mosquitto_pub -h mqtt.private-cloud.internal -p 1883 -u user -P "<jwt>" -t mqtt-e2e -m hi`.
  A plain MQTT topic (`mqtt-e2e`) maps to `persistent://public/default/mqtt-e2e`.

## Adding a future service (e.g. Flink, Spark)

1. Expose it via a LoadBalancer (MetalLB) or an Istio gateway route; note the IP.
2. Add a record to `configs/05-kafka-dns.yaml`: `host-record=flink.private-cloud.internal,<ip>`
   (use `address=/.../` only if it needs a wildcard).
3. Add a row to the **Service endpoints** table above.
4. If it serves TLS, add its name to the relevant cert's SANs (private CA).
