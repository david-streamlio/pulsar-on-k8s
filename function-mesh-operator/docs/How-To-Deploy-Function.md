# How To Deploy a Function using the Function Mesh Operator

After installing the Function Mesh Operator and deploying a Pulsar cluster, you can submit a sample CRD to create Pulsar
Functions, source, sink, or Function Mesh.

1️⃣ The first thing you need to do is to link the Pulsar Function you are going to deploy to a Pulsar cluster. Assuming that
your Pulsar cluster is running inside the `pulsar` namespace, you can run the following command to get the IP address 
you will need.

```bash
kubectl get svc -n pulsar | grep broker
brokers-broker                      ClusterIP   10.152.183.218   <none>        6650/TCP,8080/TCP                              3h6m
brokers-broker-headless             ClusterIP   None             <none>        6650/TCP,8080/TCP                              3h6m
```

2️⃣ Next, you will modify the `./function-mesh-operator/configs/00-config-maps.yaml` file and change the `<BROKER-URL>`
field to the IP address for your Broker. In this case, it would be `10.152.183.218`

```bash
# Inside ./function-mesh-operator/configs/00-config-maps.yaml

apiVersion: v1
kind: ConfigMap
metadata:
  name: pulsar
data:
  webServiceURL: http://<BROKER-URL>:8080
  brokerServiceURL: pulsar://<BROKER-URL>:6650
```

3️⃣ Once you have updated the ConfigMap with the correct IP address, you should `apply` the change to the K8s namespace 
that you want your Pulsar Function to run in.

```bash
export FUNCTION_NAMESPACE=pulsar-function-ns
kubectl create namespace $FUNCTION_NAMESPACE
kubectl apply -n $FUNCTION_NAMESPACE -f ./function-mesh-operator/configs/00-config-maps.yaml 

configmap/pulsar created
secret/test-secret created
```

4️⃣ Verify that it was deployed with the correct values.

```bash
kubectl describe cm -n $FUNCTION_NAMESPACE pulsar

Name:         pulsar
Namespace:    pulsar-function-ns
Labels:       <none>
Annotations:  <none>

Data
====
webServiceURL:
----
http://<BROKER-URL>:8080
brokerServiceURL:
----
pulsar://<BROKER-URL>:6650

BinaryData
====
```

5️⃣ Deploy a simple Pulsar Function that uses the `pulsar` ConfigMap you just created to connect to the Pulsar cluster.

```bash
kubectl apply -n $FUNCTION_NAMESPACE -f ./function-mesh-operator/configs/00-exclamation-function.yaml 
function.compute.functionmesh.io/java-function-sample created
```

6️⃣ Check that a pod was created for the Pulsar Function, and that the container started successfully.

```bash
kubectl describe pod -n $FUNCTION_NAMESPACE java-function-sample-function-0

Events:
  Type    Reason     Age   From               Message
  ----    ------     ----  ----               -------
  Normal  Scheduled  47s   default-scheduler  Successfully assigned pulsar-function-ns/java-function-sample-function-0 to kubernetes
  Normal  Pulled     47s   kubelet            Container image "busybox:1.28" already present on machine
  Normal  Created    47s   kubelet            Created container init-function
  Normal  Started    47s   kubelet            Started container init-function
  Normal  Pulled     16s   kubelet            Container image "busybox:1.28" already present on machine
  Normal  Created    16s   kubelet            Created container sidecar-function
  Normal  Started    16s   kubelet            Started container sidecar-function
  Normal  Pulled     16s   kubelet            Container image "streamnative/pulsar-functions-java-sample:2.9.2.23" already present on machine
  Normal  Created    16s   kubelet            Created container pulsar-function
  Normal  Started    16s   kubelet            Started container pulsar-function
```

7️⃣ Send some data to the Pulsar Function to confirm that it is working as expected. The function is configured to consume 
data from `persistent://public/default/java-function-input-topic` , append an `!` to each message and output the 
resulting value to `persistent://public/default/java-function-output-topic`

Let's start by opening a terminal window and sending messages to the input topic using the`pulsar-client` inside the 
broker pod. The following command will send the same text `Hello` to the topic 100 times at a rate of one message a second.

```bash
kubectl exec -n pulsar -c pulsar-broker brokers-broker-0 -- ./bin/pulsar-client produce -m "Hello" -n 100 -r 1 persistent://public/default/java-function-input-topic

...
023-07-18T04:02:53,243+0000 [pulsar-client-io-1-1] INFO  org.apache.pulsar.client.impl.ClientCnx - [id: 0x9b8bafd4, L:/10.1.192.68:36632 ! R:brokers-broker-1.brokers-broker-headless.pulsar.svc.cluster.local/10.1.192.123:6650] Disconnected
2023-07-18T04:02:55,268+0000 [main] INFO  org.apache.pulsar.client.cli.PulsarClientTool - 100 messages successfully produced
```

Next, open a new terminal window you can use consume messages from the output topic using the `pulsar-client`, and run 
the following command to start consuming the messages and confirm that an exclamation point has been appended to the 
original messages.

```bash
kubectl exec -n pulsar -c pulsar-broker  brokers-broker-0 -- ./bin/pulsar-client consume -s my-sub -n 0 -p Earliest persistent://public/default/java-function-output-topic

# You should see 100 messages similar to these.
----- got message -----
key:[null], properties:[__pfn_input_msg_id__=CAIQtQEgADAB, __pfn_input_topic__=persistent://public/default/java-function-input-topic], content:Hello!
----- got message -----
key:[null], properties:[__pfn_input_msg_id__=CAIQyAEgADAB, __pfn_input_topic__=persistent://public/default/java-function-input-topic], content:Hello!
----- got message -----
key:[null], properties:[__pfn_input_msg_id__=CAIQyQEgADAB, __pfn_input_topic__=persistent://public/default/java-function-input-topic], content:Hello!
...
```

References
------------
- https://streamnative.io/blog/using-pulsar-functions-in-a-cloud-native-way-with-function-mesh