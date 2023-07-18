# Getting started with the Function Mesh Operator

Function Mesh is a Kubernetes operator that enables users to run Pulsar Functions and connectors natively on Kubernetes,
unlocking the full power of Kubernetes’ application deployment, scaling, and management.


### Installing the Function Mesh Operators

1️⃣ Add the Function Mesh chart repository.

```bash
helm repo add function-mesh http://charts.functionmesh.io/
helm repo update
```

2️⃣ Create a Kubernetes namespace where the Function Mesh Operator will be installed.

```bash
export K8S_NAMESPACE=sn-operators
kubectl create namespace $K8S_NAMESPACE
```

3️⃣ Deploy the Function Mesh Operator using the function-mesh-operator Helm chart into the created Kubernetes namespace.


```bash
export RELEASE_NAME=my-function-mesh-operator
helm install $RELEASE_NAME -n $K8S_NAMESPACE function-mesh/function-mesh-operator
```

### Verify the Installation of the Function Mesh Operator


1️⃣ Check the Helm deployments with the following command:
```bash
helm list -n $K8S_NAMESPACE
NAME                        	NAMESPACE   	REVISION	UPDATED                                	STATUS  	CHART                           	APP VERSION
my-function-mesh-operator   	sn-operators	1       	2023-07-17 19:55:29.704109702 -0700 PDT	deployed	function-mesh-operator-0.2.17   	0.14.0     
```

2️⃣ Confirm that the Custom Resource Definitions (CRDs) have been installed

```bash
kubectl get crd  | grep functionmesh

functionmeshes.compute.functionmesh.io                2023-07-18T02:55:32Z
connectorcatalogs.compute.functionmesh.io             2023-07-18T02:55:32Z
sinks.compute.functionmesh.io                         2023-07-18T02:55:32Z
functions.compute.functionmesh.io                     2023-07-18T02:55:32Z
sources.compute.functionmesh.io                       2023-07-18T02:55:32Z
```

How To Guides
---
- [Deploy a Function using the Function Mesh](docs/How-To-Deploy-Function.md)
- [Deploy a Mesh using the Function Mesh](docs/How-To-Deploy-FunctionMesh.md)

References
------------
- https://docs.streamnative.io/docs/functionmesh-concepts
- https://github.com/streamnative/function-mesh
- https://functionmesh.io/docs/install-function-mesh/#install-function-mesh-through-helm
- https://streamnative.io/blog/using-pulsar-functions-in-a-cloud-native-way-with-function-mesh