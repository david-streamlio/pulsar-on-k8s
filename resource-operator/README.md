
Resource Operator
-----------

The Pulsar Resources Operator is a controller that manages the Pulsar resources automatically using the manifest on 
Kubernetes. Therefore, you can manage the Pulsar resources without the help of pulsar-admin or pulsarctl CLI tool. It is
useful for initializing basic resources when creating a new Pulsar cluster.

The Pulsar Resources Operator is an independent controller, it doesn’t need to be installed with the pulsar operator.
Currently, the Pulsar Resources Operator provides full lifecycle management for the following Pulsar resources, including creation, update, and deletion.

- Tenants
- Namespaces
- Topics
- Permissions


### Installing the Resource Operator

1️⃣ If you haven't already, add the StreamNative chart repository.

```bash
helm repo add streamnative https://charts.streamnative.io
helm repo update
```


2️⃣ Create a Kubernetes namespace where the Resource Operator will be installed.

```bash
export K8S_NAMESPACE=sn-operators
kubectl create namespace $K8S_NAMESPACE
```

3️⃣ Deploy the Resource Operator using the pulsar-resources-operator Helm chart into the created Kubernetes namespace.

```bash
export RELEASE_NAME=my-pulsar-resource-operators
helm install $RELEASE_NAME -n $K8S_NAMESPACE streamnative/pulsar-resources-operator
```

### Verify the Installation of the Resource Operator

1️⃣ Verify that the Resource Operator is installed successfully, by checking that the helm release exists in the specified K8s namespace.

```bash
helm list -n $K8S_NAMESPACE
NAME                        	NAMESPACE   	REVISION	UPDATED                                	STATUS  	CHART                           	APP VERSION
my-pulsar-resource-operators	sn-operators	1       	2023-07-17 07:27:42.942297972 -0700 PDT	deployed	pulsar-resources-operator-v0.3.4	v0.3.4  
```


2️⃣ Verify that the Custom Resource Definitions (CRDs) for the Resource Operator have been installed

```bash
kubectl get crd | grep streamnative

pulsarconnections.resource.streamnative.io            2023-07-17T14:27:42Z
pulsargeoreplications.resource.streamnative.io        2023-07-17T14:27:42Z
pulsarnamespaces.resource.streamnative.io             2023-07-17T14:27:42Z
pulsarpermissions.resource.streamnative.io            2023-07-17T14:27:42Z
pulsartenants.resource.streamnative.io                2023-07-17T14:27:42Z
pulsartopics.resource.streamnative.io                 2023-07-17T14:27:42Z
```

### Deploy Pulsar Cluster Resources using the Resource Operator

The first thing you need to do is create a Pulsar connection object that will be used to connect to a Pulsar cluster and
issue administrative commands. Therefore, you need to use the URL of the Pulsar broker/proxy that you wish to administer.
Assuming that your Pulsar cluster is running inside the `pulsar` namespace, you can run the following command to get the
IP address you will need.

```bash
kubectl get svc -n pulsar | grep broker
brokers-broker                      ClusterIP   10.152.183.218   <none>        6650/TCP,8080/TCP                              3h6m
brokers-broker-headless             ClusterIP   None             <none>        6650/TCP,8080/TCP                              3h6m
```

Next, you will modify the `./resource-operator/configs/00-resources-quick-start.yaml` file and change the `<BROKER-URL>` 
field to the IP address for your Broker. In this case, it would be `10.152.183.218`

```bash

# Inside ./resource-operator/configs/00-resources-quick-start.yaml

apiVersion: resource.streamnative.io/v1alpha1
kind: PulsarConnection
metadata:
  name: pulsar-connection
spec:
  adminServiceURL: http://<BROKER-URL>:8080
  brokerServiceURL: pulsar://<BROKER-URL>:6650
  clusterName: brokers
```

1️⃣ Once this is done, you can then use the following command to create a connection.

```bash
kubectl apply -f ./resource-operator/configs/00-resources-quick-start.yaml -n pulsar

pulsarconnection.resource.streamnative.io/pulsar-connection created
```

2️⃣ Check the connection resource status

```bash
kubectl -n pulsar get pulsarconnection.resource.streamnative.io

NAME                ADMIN_SERVICE_URL            BROKER_SERVICE_URL             READY
pulsar-connection   http://10.152.183.218:8080   pulsar://10.152.183.218:6650   
```


3️⃣ Add a tenant, namespace, and topic

```bash
kubectl apply -f ./resource-operator/configs/01-resources-quick-start.yaml -n pulsar

pulsarconnection.resource.streamnative.io/pulsar-connection created
pulsartenant.resource.streamnative.io/pulsar-tenant-foo created
pulsarnamespace.resource.streamnative.io/pulsar-namespace-bar created
pulsartopic.resource.streamnative.io/foo-bar-topic created
```

4️⃣ Use kubectl to verify that the Pulsar resources have been created

```bash
kubectl get -n pulsar pulsartenant.resource.streamnative.io

NAME                 RESOURCE_NAME   GENERATION   OBSERVED_GENERATION   READY
test-pulsar-tenant   test-tenant     1            1                     True

kubectl get -n pulsar pulsarnamespace.resource.streamnative.io
NAME                    RESOURCE_NAME        GENERATION   OBSERVED_GENERATION   READY
test-pulsar-namespace   test-tenant/testns   1            1                     True

kubectl get -n pulsar pulsartopic.resource.streamnative.io
NAME                   RESOURCE_NAME                              GENERATION   OBSERVED_GENERATION   READY
test-pulsar-topic123   persistent://test-tenant/testns/topic123   1            1                     True
```

5️⃣ Use the `pulsar-admin` tool to verify that the topic has been created.

```bash
kubectl exec -it -c pulsar-broker -n pulsar pod/brokers-broker-0 -- /pulsar/bin/pulsar-admin topics list test-tenant/testns

persistent://test-tenant/testns/topic123
```

References
------------
- https://github.com/streamnative/pulsar-resources-operator