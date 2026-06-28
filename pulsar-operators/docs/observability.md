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

## node02 ssd-raid I/O fault — Prometheus worked around 2026-06-28 (array repair still TODO)

The `ssd-raid` array (`/dev/md0`) on **node02** returns **write I/O errors** despite being ~0%
full (`touch` fails; reads partially work) — a **failing/degraded RAID array or bad blocks**, not
disk-full. Prometheus scraped fine but couldn't persist (`write /data/wal/...: input/output
error`), and it also hits **bookie bk-2** on node02 (I/O errors in its log). Any `ssd-raid` PVC
landing on node02 is affected.

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

⚠️ The `nodeSelector` and `--storage.tsdb.retention.size` are **live patches** on the Helm-managed
deployment. Fold them into the Helm values so a `helm upgrade` doesn't revert them:
```bash
helm upgrade prometheus prometheus-community/prometheus -n monitor --reuse-values \
  --set-string server.nodeSelector."kubernetes\.io/hostname"=k8s-node01.kubernetes.net \
  --set server.retention=15d --set server.retentionSize=15GB \
  --set server.persistentVolume.size=20Gi
```
Drop the `nodeSelector` once node02's array is repaired.

**Still TODO — repair node02's array** (it also endangers bk-2's ledger data). On node02 (sudo):
1. Diagnose (read-only): `dmesg -T | grep -iE 'I/O error|md0|EXT4-fs error|read-only'`,
   `cat /proc/mdstat`, `sudo mdadm --detail /dev/md0`, `findmnt /dev/md0`, `smartctl -a` on members.
2. If degraded → re-add/replace the failed member, resync. If FS remounted read-only/corrupt →
   drain node02's stateful pods (bk-2, broker), `umount`, `fsck.ext4 -f -y /dev/md0`, remount.
   If a disk is physically dying (SMART pending/reallocated) → replace it.
