StreamNative Operators for Apache Pulsar
-----------

### Installing the Pulsar Operators

1️⃣ Add the StreamNative chart repository.

```bash
helm repo add streamnative https://charts.streamnative.io
helm repo update
```

2️⃣ Create a Kubernetes namespace where the Pulsar Operators will be installed.

```bash
export K8S_NAMESPACE=sn-operators
kubectl create namespace $K8S_NAMESPACE
```

3️⃣ Deploy the Pulsar Operators using the pulsar-operator Helm chart into the created Kubernetes namespace.


```bash
export RELEASE_NAME=my-pulsar-operators
helm install $RELEASE_NAME -n $K8S_NAMESPACE streamnative/pulsar-operator
```

### Verify the Installation of the Pulsar Operators

1️⃣ Verify that the Pulsar Operators are installed successfully, by checking that the helm release exists in the specified K8s namespace.

```bash
helm list -n $K8S_NAMESPACE
NAME               	NAMESPACE   	REVISION	UPDATED                               	STATUS  	CHART                 	APP VERSION
my-pulsar-operators	sn-operators	1       	2023-07-15 12:13:00.10625632 -0700 PDT	deployed	pulsar-operator-0.17.0	0.17.0     
```

Next, confirm that all the components specified in the Helm chart are deployed and in a RUNNING state.

```bash
kubectl get all -n $K8S_NAMESPACE

NAME                                                                  READY   STATUS    RESTARTS   AGE
pod/my-pulsar-operators-pulsar-controller-manager-67cb694d79-696g2    1/1     Running   0          116s
pod/my-pulsar-operators-bookkeeper-controller-manager-6bcc7975rsrll   1/1     Running   0          116s
pod/my-pulsar-operators-zookeeper-controller-manager-7b966498ffbpht   1/1     Running   0          116s

NAME                                                                READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/my-pulsar-operators-pulsar-controller-manager       1/1     1            1           117s
deployment.apps/my-pulsar-operators-bookkeeper-controller-manager   1/1     1            1           117s
deployment.apps/my-pulsar-operators-zookeeper-controller-manager    1/1     1            1           117s

NAME                                                                           DESIRED   CURRENT   READY   AGE
replicaset.apps/my-pulsar-operators-pulsar-controller-manager-67cb694d79       1         1         1       116s
replicaset.apps/my-pulsar-operators-bookkeeper-controller-manager-6bcc7975f9   1         1         1       116s
replicaset.apps/my-pulsar-operators-zookeeper-controller-manager-7b966498f9    1         1         1       116s
```


2️⃣ Verify the custom resource definitions (CRDs) are installed. These CRDs are used by the Pulsar operators to deploy
a Pulsar cluster based on higher level terms like `PulsarCluster`, and `BookKeeperCluster` instead of K8s terms such as `pod`, `service`, etc.

```bash
kubectl get crds | grep streamnative

bookkeeperclusters.bookkeeper.streamnative.io         2023-07-15T19:12:56Z
pulsarbrokers.pulsar.streamnative.io                  2023-07-15T19:12:56Z
pulsarproxies.pulsar.streamnative.io                  2023-07-15T19:12:57Z
zookeeperclusters.zookeeper.streamnative.io           2023-07-15T19:12:57Z
```

### Deploy a Pulsar Cluster using the Operators
The Pulsar Operators provide full lifecycle management for all the components within a Pulsar cluster. You can use it 
to create, upgrade, and scale a cluster. This section covers how to deploy a Pulsar cluster on Kubernetes using the 
Pulsar Operators by applying a single YAML file that contains the Custom Resources (CRs) of all required components, you can easily create a Pulsar cluster.

1️⃣ Create a Kubernetes namespace to deploy the Pulsar cluster into

```bash
export PULSAR_K8S_NAMESPACE=pulsar
kubectl create namespace $PULSAR_K8S_NAMESPACE
```

2️⃣ Install Pulsar

```bash
kubectl apply -f ./examples/pulsar-operators/00-quick-start.yaml --wait --namespace $PULSAR_K8S_NAMESPACE

zookeepercluster.zookeeper.streamnative.io/zookeepers created
bookkeepercluster.bookkeeper.streamnative.io/bookies created
pulsarbroker.pulsar.streamnative.io/brokers created
```

3️⃣ Verify that all components of the Pulsar cluster are up and running.

```bash
kubectl get all -n $PULSAR_K8S_NAMESPACE

NAME                             READY   STATUS    RESTARTS   AGE
pod/zookeepers-zk-0              1/1     Running   0          4m26s
pod/zookeepers-zk-1              1/1     Running   0          4m26s
pod/zookeepers-zk-2              1/1     Running   0          4m26s
pod/brokers-broker-1             1/1     Running   0          3m23s
pod/brokers-broker-0             1/1     Running   0          3m23s
pod/bookies-bk-0                 1/1     Running   0          3m20s
pod/bookies-bk-1                 1/1     Running   0          3m20s
pod/bookies-bk-2                 1/1     Running   0          3m20s
pod/bookies-bk-auto-recovery-0   1/1     Running   0          2m21s

NAME                                        TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)                                        AGE
service/zookeepers-zk                       ClusterIP   10.152.183.159   <none>        2181/TCP,8000/TCP,9990/TCP                     4m27s
service/zookeepers-zk-headless              ClusterIP   None             <none>        2181/TCP,2888/TCP,3888/TCP,8000/TCP,9990/TCP   4m27s
service/brokers-broker                      ClusterIP   10.152.183.217   <none>        6650/TCP,8080/TCP                              4m26s
service/brokers-broker-headless             ClusterIP   None             <none>        6650/TCP,8080/TCP                              4m26s
service/bookies-bk-auto-recovery-headless   ClusterIP   None             <none>        3181/TCP,8000/TCP                              3m20s
service/bookies-bk                          ClusterIP   10.152.183.228   <none>        3181/TCP,8000/TCP                              3m20s
service/bookies-bk-headless                 ClusterIP   None             <none>        3181/TCP,8000/TCP                              3m20s

NAME                                        READY   AGE
statefulset.apps/zookeepers-zk              3/3     4m27s
statefulset.apps/brokers-broker             2/2     3m23s
statefulset.apps/bookies-bk                 3/3     3m20s
statefulset.apps/bookies-bk-auto-recovery   1/1     3m20s
```

4 Run a smoke test to confirm that the Pulsar cluster is functional

```bash
kubectl exec -it -n pulsar pod/brokers-broker-0 /pulsar/bin/pulsar-perf produce persistent://public/default/test

INFO  org.apache.pulsar.client.impl.ProducerImpl - [persistent://public/default/test] [brokers-1-0] Created producer on cnx [id: 0x8aeb8192, L:/10.1.192.100:56566 - R:brokers-broker-0.brokers-broker-headless.pulsar.svc.cluster.local/10.1.192.100:6650]
2023-07-15T21:02:23,950+0000 [pulsar-perf-producer-exec-1-1] INFO  org.apache.pulsar.testclient.PerformanceProducer - Created 1 producers
2023-07-15T21:02:24,005+0000 [pulsar-client-io-2-1] INFO  com.scurrilous.circe.checksum.Crc32cIntChecksum - SSE4.2 CRC32C provider initialized
2023-07-15T21:02:32,316+0000 [main] INFO  org.apache.pulsar.testclient.PerformanceProducer - Throughput produced:     831 msg ---     83.1 msg/s ---      0.6 Mbit/s  --- failure      0.0 msg/s --- Latency: mean:   6.960 ms - med:   6.772 - 95pct:   9.490 - 99pct:  11.210 - 99.9pct:  23.170 - 99.99pct:  29.036 - Max:  29.036
2023-07-15T21:02:42,358+0000 [main] INFO  org.apache.pulsar.testclient.PerformanceProducer - Throughput produced:    1838 msg ---    100.0 msg/s ---      0.8 Mbit/s  --- failure      0.0 msg/s --- Latency: mean:   7.066 ms - med:   6.124 - 95pct:   8.454 - 99pct:  42.647 - 99.9pct:  94.420 - 99.99pct:  95.330 - Max:  95.330
2023-07-15T21:02:52,392+0000 [main] INFO  org.apache.pulsar.testclient.PerformanceProducer - Throughput produced:    2841 msg ---    100.0 msg/s ---      0.8 Mbit/s  --- failure      0.0 msg/s --- Latency: mean:   6.203 ms - med:   5.960 - 95pct:   7.693 - 99pct:   9.641 - 99.9pct:  43.079 - 99.99pct:  48.938 - Max:  48.938
2023-07-15T21:03:02,453+0000 [main] INFO  org.apache.pulsar.testclient.PerformanceProducer - Throughput produced:    3845 msg ---    100.0 msg/s ---      0.8 Mbit/s  --- failure      0.0 msg/s --- Latency: mean:   9.487 ms - med:   5.975 - 95pct:   7.911 - 99pct: 163.274 - 99.9pct: 250.903 - 99.99pct: 259.981 - Max: 259.981
```

References
------------
- https://docs.streamnative.io/operator/understand-pulsar-operator