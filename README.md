# Getting Started with Pulsar on Kubernetes

This repository contains a collection of instructions the guide you through the process
of creating a Pulsar cluster using the StreamNative Operators for Apache Pulsar.

These operators provide full lifecycle management of Pulsar deployments on Kubernetes. With the Pulsar Operators, you can easily deploy a Pulsar cluster on Kubernetes, create Pulsar-related resources, and manage them through the Kubernetes API and kubectl.

There are a total of five separate operators provided by StreamNative that make installing,
upgrading, and managing Pulsar clusters easier. 
The first three are installed together and are collective referred to as the "_Pulsar Operators_"

- **Pulsar Operator**: Manages the lifecycle of Pulsar brokers and Pulsar proxies. Broker Pods act as the servers in a 
Pulsar cluster to handle incoming requests from clients. 


- **BookKeeper Operator**: Manages the lifecycle of the BookKeeper cluster. BookKeeper nodes (bookies) store messages sent to the Pulsar cluster.


- **ZooKeeper Operator**: Manages the lifecycle of the ZooKeeper cluster. ZooKeeper stores critical metadata information about the Pulsar cluster and coordinates intra-cluster tasks.


- **Resource Operator**: Allows you to manage Pulsar resources without the help of pulsar-admin or pulsarctl CLI tool.


- **Function Mesh Operator**:



Requirements
------------
- Install kubectl (v1.16 or higher), compatible with your cluster (+/- 1 minor release from your cluster).
- Install Helm (v3.0.2 or higher).
- Prepare a Kubernetes cluster (v1.16 or higher).

Ensure you have allocated enough resources to Kubernetes: at least 8Gb.

Getting Started Guides
---

- [Pulsar Operators](pulsar-operators/README.md)
- [Resource Operator](resource-operator/README.md)
- [Function Mesh Operator](function-mesh-operator/README.md)