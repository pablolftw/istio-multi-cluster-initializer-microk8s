---------------------------------------
#!/bin/bash

set -xe

export TOTAL_CLUSTERS=$1

mkdir -p tmp

for ((CLUSTER_INDEX=1;CLUSTER_INDEX<=${TOTAL_CLUSTERS};CLUSTER_INDEX++)); do

    export CLUSTER_INDEX

    for ((i=1;i<=${TOTAL_CLUSTERS};i++)); do
        CLUSTER_INDEX=$i envsubst < namespace.yaml > tmp/namespace-${i}.yaml
        kubectl --context="ctx-${i}" apply -f tmp/namespace-${i}.yaml
    done

    kubectl create secret generic cacerts -n istio-system \
        --from-file=./gen-certs/certs/cluster-${CLUSTER_INDEX}/ca-cert.pem \
        --from-file=./gen-certs/certs/cluster-${CLUSTER_INDEX}/ca-key.pem \
        --from-file=./gen-certs/certs/root-cert.pem \
        --from-file=./gen-certs/certs/cluster-${CLUSTER_INDEX}/cert-chain.pem --dry-run -o yaml > tmp/certs.yaml
    kubectl --context="ctx-${CLUSTER_INDEX}" -n istio-system apply -f tmp/certs.yaml

    envsubst < controlplane.yaml > tmp/controlplane-${CLUSTER_INDEX}.yaml
    istioctl --context="ctx-${CLUSTER_INDEX}" install -y -f tmp/controlplane-${CLUSTER_INDEX}.yaml

    envsubst < eastwest-gateway.yaml > tmp/eastwest-gateway-${CLUSTER_INDEX}.yaml
    istioctl --context="ctx-${CLUSTER_INDEX}" install -y -f tmp/eastwest-gateway-${CLUSTER_INDEX}.yaml

    kubectl --context="ctx-${CLUSTER_INDEX}" apply -n istio-system -f ./expose-services.yaml

    #The commented original line makes you able to get the hostname of your microk8s nodes, thats not what we want since we need
    #the local ips of the nodes, thats what the uncommented line does.
    #kubectl --context="ctx-${CLUSTER_INDEX}" get nodes -o json | jq '.items[].metadata.name' > tmp/nodes.txt
    kubectl --context="ctx-${CLUSTER_INDEX}" get nodes -o json | jq '.items[].status.addresses[] | select(.type == "InternalIP") | .address' > tmp/nodes_ips.txt
    
    #This line is only to give the appropiate new format to nodes_ips.txt
    #NODES=`sed -z 's/\n/,/g;s/,$/\n/' tmp/nodes.txt`
    NODES=$(tr '\n' ',' < tmp/nodes_ips.txt | sed 's/,$//')
    
    kubectl --context="ctx-${CLUSTER_INDEX}" patch service istio-eastwestgateway --patch "{\"spec\": {\"externalIPs\": [${NODES}]}}" -n istio-system

    for ((i=1;i<=${TOTAL_CLUSTERS};i++)); do
        if [ ${i} != ${CLUSTER_INDEX} ]; then
            istioctl --context="ctx-${i}" x create-remote-secret --name="cluster-${i}" > tmp/cluster-secret-${i}.yaml
            kubectl --context="ctx-${CLUSTER_INDEX}" apply -f tmp/cluster-secret-${i}.yaml
        fi
    done

done
