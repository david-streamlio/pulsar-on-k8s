# How To Deploy a Mesh using the Function Mesh Operator

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

5️⃣ Deploy a Pulsar Function Mesh consisting of two instances of the Exclamation Pulsar Functions that use the `pulsar` 
ConfigMap you just created to connect to the Pulsar cluster.  

```bash
kubectl apply -n $FUNCTION_NAMESPACE -f ./function-mesh-operator/configs/00-functionmesh-getting-started.yaml 
functionmesh.compute.functionmesh.io/functionmesh-sample created
```

6️⃣ Check that a pod was created for the both of the Pulsar Functions.

```bash
kubectl -n $FUNCTION_NAMESPACE get pods

NAME                                 READY   STATUS    RESTARTS   AGE
functionmesh-sample-ex1-function-0   1/1     Running   0          34s
functionmesh-sample-ex2-function-0   1/1     Running   0          34s
```

7️⃣ Send some data to the Function Mesh to confirm that it is working as expected. The first function is configured to 
consume data from `persistent://public/default/functionmesh-input-topic` , append an `!` to each message and output the 
resulting value to `persistent://public/default/mid-topic`. The second function then consumes from the `mid-topic`, 
appends another `!` to each message and out the resulting value to `persistent://public/default/functionmesh-output-topic`

Let's start by opening a terminal window and sending messages to the input topic using the`pulsar-client` inside the 
broker pod. The following command will send the same text `Hello` to the topic 100 times at a rate of one message a second.

```bash
kubectl exec -n pulsar -c pulsar-broker brokers-broker-0 -- ./bin/pulsar-client produce -m "Hello Function Mesh" -n 100 -r 1 persistent://public/default/functionmesh-input-topic

...
023-07-18T04:02:53,243+0000 [pulsar-client-io-1-1] INFO  org.apache.pulsar.client.impl.ClientCnx - [id: 0x9b8bafd4, L:/10.1.192.68:36632 ! R:brokers-broker-1.brokers-broker-headless.pulsar.svc.cluster.local/10.1.192.123:6650] Disconnected
2023-07-18T04:02:55,268+0000 [main] INFO  org.apache.pulsar.client.cli.PulsarClientTool - 100 messages successfully produced
```

Next, open a new terminal window you can use consume messages from the output topic using the `pulsar-client`, and run 
the following command to start consuming the messages and confirm that two exclamation points have been appended to the 
original messages.

```bash
kubectl exec -n pulsar -c pulsar-broker  brokers-broker-0 -- ./bin/pulsar-client consume -s my-sub -n 0 -p Earliest persistent://public/default/functionmesh-output-topic

# You should see 100 messages similar to these.
----- got message -----
key:[null], properties:[__pfn_input_msg_id__=CB0QxAEYACAAMAE=, __pfn_input_topic__=persistent://public/default/mid-topic-partition-0], content:Hello Function Mesh!!
----- got message -----
key:[null], properties:[__pfn_input_msg_id__=CB0QxQEYACAAMAE=, __pfn_input_topic__=persistent://public/default/mid-topic-partition-0], content:Hello Function Mesh!!
----- got message -----
key:[null], properties:[__pfn_input_msg_id__=CB0QxgEYACAAMAE=, __pfn_input_topic__=persistent://public/default/mid-topic-partition-0], content:Hello Function Mesh!!
...
```

References
------------
- https://streamnative.io/blog/using-pulsar-functions-in-a-cloud-native-way-with-function-mesh