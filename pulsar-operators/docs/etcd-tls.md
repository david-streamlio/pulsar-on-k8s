# etcd mutual-TLS runbook

The microk8s control plane is backed by an **external 3-node etcd** (members
`etcd-node00/01/02` on `192.168.0.80/81/82`; client `:2379`, peer `:2380`; etcd 3.4.x). As of
2026-06-28 it runs **full mutual TLS** on both the client API and peer traffic, with a **dedicated
etcd CA** (isolated from the k8s CA). This documents the layout, how the migration was done, and
how to operate/rollback/renew. No private keys are stored in git.

## Cluster topology (heterogeneous — important)

| Node | etcd packaging | config | cert dir | restart |
|------|----------------|--------|----------|---------|
| node00 (.80) | **upstream binary** under systemd (its CPU lacks AVX2, which the snap build needs) | `/etc/etcd/etcd.conf.yml` | `/etc/etcd/tls/` | `sudo systemctl restart etcd` |
| node01 (.81) | snap | `/var/snap/etcd/common/etcd.conf.yml` | `/var/snap/etcd/common/tls/` | `sudo snap restart etcd` |
| node02 (.82) | snap | `/var/snap/etcd/common/etcd.conf.yml` | `/var/snap/etcd/common/tls/` | `sudo snap restart etcd` |

All three nodes run `microk8s` (`kubelite`), so the apiserver→etcd config must be updated on **all
three**. The microk8s snap is strictly confined — its apiserver can only read etcd client certs
under `/var/snap/microk8s/current/certs/`.

Member IDs: node00 `50b8d51335ebf512`, node01 `666724d0e31eb17`, node02 `146b6ccebdf8d52a`.

## PKI

Dedicated **etcd CA**. Certs (all signed by it, 10-year validity):
- `etcd-server` — SANs: `etcd-node00/01/02`, `localhost`, `192.168.0.80/81/82`, `127.0.0.1`;
  EKU serverAuth+clientAuth. Used for the **client listener** and **reused for peer** (SANs +
  clientAuth cover the peer client role).
- `etcd-client` — CN `kube-apiserver-etcd-client`, EKU clientAuth. Used by the apiserver and admin
  etcdctl.

**Durable store (the only copy of the CA key):** `/etc/etcd/pki/` on node01, root-only —
`etcd-ca.{crt,key}`, `etcd-server.{crt,key}`, `etcd-client.{crt,key}`. **Back up `etcd-ca.key`**;
it's needed to mint new certs.

Generate (openssl 3.x), if ever rebuilding the PKI:
```bash
openssl genrsa -out etcd-ca.key 4096
openssl req -x509 -new -nodes -key etcd-ca.key -sha256 -days 3650 -out etcd-ca.crt -subj "/CN=etcd-ca"
# server (also used for peer)
openssl genrsa -out etcd-server.key 4096
openssl req -new -key etcd-server.key -out etcd-server.csr -subj "/CN=etcd-server"
openssl x509 -req -in etcd-server.csr -CA etcd-ca.crt -CAkey etcd-ca.key -CAcreateserial -days 3650 -sha256 \
  -out etcd-server.crt -extfile <(printf "subjectAltName=DNS:etcd-node00,DNS:etcd-node01,DNS:etcd-node02,DNS:localhost,IP:192.168.0.80,IP:192.168.0.81,IP:192.168.0.82,IP:127.0.0.1\nextendedKeyUsage=serverAuth,clientAuth\nkeyUsage=critical,digitalSignature,keyEncipherment")
# client (apiserver + etcdctl)
openssl genrsa -out etcd-client.key 4096
openssl req -new -key etcd-client.key -out etcd-client.csr -subj "/CN=kube-apiserver-etcd-client"
openssl x509 -req -in etcd-client.csr -CA etcd-ca.crt -CAkey etcd-ca.key -CAcreateserial -days 3650 -sha256 \
  -out etcd-client.crt -extfile <(printf "extendedKeyUsage=clientAuth\nkeyUsage=critical,digitalSignature,keyEncipherment")
```

## etcd config (final state, per node)

`<CERTDIR>` = `/etc/etcd/tls` (node00) or `/var/snap/etcd/common/tls` (node01/02); `<IP>` = node IP.
```yaml
listen-client-urls: https://<IP>:2379,https://127.0.0.1:2379
advertise-client-urls: https://<IP>:2379
listen-peer-urls: https://<IP>:2380
initial-advertise-peer-urls: https://<IP>:2380
initial-cluster: etcd-node00=https://etcd-node00:2380,etcd-node01=https://etcd-node01:2380,etcd-node02=https://etcd-node02:2380
client-transport-security:
  cert-file: <CERTDIR>/etcd-server.crt
  key-file: <CERTDIR>/etcd-server.key
  trusted-ca-file: <CERTDIR>/etcd-ca.crt
  client-cert-auth: true
peer-transport-security:
  cert-file: <CERTDIR>/etcd-server.crt
  key-file: <CERTDIR>/etcd-server.key
  trusted-ca-file: <CERTDIR>/etcd-ca.crt
  client-cert-auth: true
```

## apiserver config (all 3 nodes)

`/var/snap/microk8s/current/args/kube-apiserver` — certs in `/var/snap/microk8s/current/certs/`:
```
--etcd-servers=https://etcd-node00:2379,https://etcd-node01:2379,https://etcd-node02:2379
--etcd-cafile=/var/snap/microk8s/current/certs/etcd-ca.crt
--etcd-certfile=/var/snap/microk8s/current/certs/etcd-client.crt
--etcd-keyfile=/var/snap/microk8s/current/certs/etcd-client.key
```
Apply: `sudo snap restart microk8s.daemon-kubelite`.

## Migration procedure (how it was done — phased, quorum-safe)

> Pre-flight: full etcd snapshot + back up every `etcd.conf.yml` and `kube-apiserver` to
> `*.pre-tls.bak`. Distribute certs to each node's `<CERTDIR>` (server+CA) and to every
> `/var/snap/microk8s/current/certs/` (CA+client).

**Phase 1 — client TLS (`:2379`):** on each node fill `client-transport-security` +
`client-cert-auth: true`, switch client URLs to `https`; restart etcd (rolling — client TLS doesn't
touch peer/membership). Then repoint all 3 apiservers (above) and restart kubelite. Verify
`/readyz/etcd=ok`.

**Phase 2 — peer TLS (`:2380`):** peer URLs live in cluster membership and peer TLS can't
half-exist, so:
1. **Prime** — add `peer-transport-security` to all configs but **keep `listen-peer-urls` http**;
   rolling-restart all three. No behavior change; just loads the cert so each member can TLS-dial
   peers. (Required before any member goes https, else others can't reach it.)
2. **Cutover, one member at a time** — flip that node's peer URLs to `https`, then
   `etcdctl member update <id> --peer-urls=https://etcd-nodeNN:2380`, then restart it. Quorum stays
   3/3 (only one member down at a time). Repeat for the other two.

A transient burst of `tls: first record does not look like a TLS handshake` rejected-connection
log lines during each cutover is normal (a not-yet-switched apiserver/peer hitting a now-TLS
listener); it stops once everything is switched.

## Operate

```bash
sudo etcdctl-tls member list -w table        # /usr/local/bin/etcdctl-tls wraps endpoints + client certs
sudo etcdctl-tls endpoint status -w table    # leader / db size / raft
sudo etcdctl-tls endpoint health --cluster
microk8s kubectl get --raw=/readyz/etcd      # apiserver's view of etcd -> "ok"
```
Bare `etcdctl` now hangs — TLS + client cert are required.

## Rollback

1. apiserver (all nodes): restore `kube-apiserver.pre-tls.bak`, `sudo snap restart microk8s.daemon-kubelite`.
2. etcd (all nodes): restore `etcd.conf.yml.pre-tls.bak`, restart etcd (systemctl/snap per node).
   If peer URLs were already updated in membership, also `member update <id> --peer-urls=http://…`.
3. Last resort: restore data from the `etcd-pre-tls.db` snapshot.

## Renewal

Certs expire 2026-06-28 + 10y. To renew: re-issue `etcd-server`/`etcd-client` from the CA (same
SANs/EKU), replace files in each `<CERTDIR>` and `/var/snap/microk8s/current/certs/`, restart etcd
then kubelite. CA renewal (new `etcd-ca`) requires re-issuing all leaf certs and a coordinated
restart — same shape as the original migration.
