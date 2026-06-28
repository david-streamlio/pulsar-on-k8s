# Observability suite (Prometheus + Grafana)

Monitoring for the `private-cloud` cluster, per
https://docs.streamnative.io/private-cloud/v2/operate-private-cloud/observability/private-cloud-monitor.
Deployed via the community Helm charts into the **`monitor`** namespace (Prometheus scrapes
the Pulsar pods by annotation; Grafana uses the StreamNative image with bundled dashboards).

## Install (already deployed in this lab — recorded here for reproducibility)

```bash
kubectl create ns monitor

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Prometheus (alertmanager / kube-state-metrics / pushgateway disabled per the SN doc)
helm install prometheus prometheus-community/prometheus -n monitor \
  --set alertmanager.enabled=false \
  --set kube-state-metrics.enabled=false \
  --set prometheus-pushgateway.enabled=false

# Grafana (StreamNative image carries the Pulsar dashboards)
helm install grafana grafana/grafana -n monitor \
  --set image.repository=streamnative/private-cloud-grafana \
  --set image.tag=0.1.1
```

Live versions: prometheus chart `27.5.0` (app v3.2.0), grafana chart `8.10.1`
(`streamnative/private-cloud-grafana:0.1.1`). Prometheus scrapes Pulsar via the
`prometheus.io/scrape`/`port`/`path` pod annotations the operator sets on brokers/bookies/zk.

## Access

Grafana is exposed by the `grafana-external` LoadBalancer on port 3000:

| Name | IP | Port |
|------|----|------|
| `grafana.private-cloud.internal` | 192.168.0.202 | 3000 |

DNS record is in `configs/05-kafka-dns.yaml`; registry in `lan-endpoints.md`. Prometheus and
node-exporter are ClusterIP-only (not externally exposed).

## node02 ssd-raid I/O fault — RESOLVED 2026-06-28 (array repaired)

> **Resolved:** node02's `ssd-raid` array was repaired and the node uncordoned. Verified — write
> test on bk-2's ledger volume OK, 0 I/O errors since restart, all 3 bookies read-write,
> under-replicated ledger count 0 → full 3-bookie redundancy restored. Prometheus stays on node01
> (healthy there; its PVC is node01-pinned anyway). The `server.nodeSelector` pin may be dropped
> now if desired — cosmetic, since the hostpath PVC pins it to node01 regardless.

What happened (kept for reference): the `ssd-raid` array (`/dev/md0`) on **node02** returned
**write I/O errors** despite being ~0% full (`touch` failed; reads partially worked) — a
**failing/degraded RAID array or bad blocks**, not disk-full. Prometheus scraped fine but couldn't
persist (`write /data/wal/...: input/output error`), and it also hit **bookie bk-2** on node02. Any
`ssd-raid` PVC landing on node02 was affected.

**Worked around (monitoring):** Prometheus moved off node02 — PVC recreated on node01 (the
metrics history was disposable). Done with:
```bash
kubectl scale deploy prometheus-server -n monitor --replicas=0
kubectl patch deploy prometheus-server -n monitor --type=merge \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"k8s-node01.kubernetes.net"}}}}}'
kubectl delete pvc prometheus-server -n monitor
kubectl apply -f <PVC manifest, 20Gi>   # same name/sc, re-binds on node01 (WaitForFirstConsumer)
kubectl scale deploy prometheus-server -n monitor --replicas=1
```

## Retention & sizing (prevents the disk filling over time)

PVC is **20Gi** on `ssd-raid`. Prometheus prunes by whichever limit hits first:
- `--storage.tsdb.retention.time=15d` (chart default)
- `--storage.tsdb.retention.size=15GB` (added — the hard size cap; ~5Gi headroom under the 20Gi
  volume for WAL/compaction, which aren't counted in the limit).

The size cap matters because the `microk8s.io/hostpath` provisioner does **not** enforce the PVC's
nominal capacity — without `retention.size`, Prometheus could grow to fill the whole shared
`/dev/md0` array (and starve the co-located bookie). Verify: `prometheus_tsdb_retention_limit_bytes`
≈ 16106127360 (15 GiB).

These settings are now persisted in the **Helm release** (`prometheus`, revision 2) so a
`helm upgrade --reuse-values` keeps them — applied with:
```bash
helm upgrade prometheus prometheus-community/prometheus -n monitor --version 27.5.0 --reuse-values \
  --set-string server.nodeSelector."kubernetes\.io/hostname"=k8s-node01.kubernetes.net \
  --set-string server.retention=15d --set-string server.retentionSize=15GB \
  --set server.persistentVolume.size=20Gi
```
(The manually-recreated PVC was first adopted into the release via the `meta.helm.sh/release-name`
+ `-namespace` annotations.) With node02 repaired, the `server.nodeSelector` can be dropped on the
next upgrade if you prefer free scheduling.

### node02 array repair (DONE 2026-06-28) — reference runbook
Repaired with sudo on node02: diagnose `dmesg -T | grep -iE 'I/O error|md0|EXT4-fs error|read-only'`,
`cat /proc/mdstat`, `mdadm --detail /dev/md0`, `findmnt /dev/md0`, `smartctl -a` on members; then by
cause — degraded → re-add/replace + resync; FS read-only/corrupt → drain stateful pods, `umount`,
`fsck.ext4 -f -y /dev/md0`, remount; dying disk → replace. After repair: `kubectl uncordon
k8s-node02…`, restart bk-2 if needed, confirm `listbookies -rw` shows 3 and `listunderreplicated` = 0.
