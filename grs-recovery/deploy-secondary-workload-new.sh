#!/bin/bash
set -e

# Load variables
source /tmp/grs-demo-vars.sh

echo "======================================================="
echo "Deploying workload in secondary cluster (eastus2)"
echo "======================================================="
echo ""

kubectl config use-context aks-secondary

# Step 1: Create secondary private endpoint NOW (after failover)
echo "Step 1: Creating private endpoint in ${LOCATION_SECONDARY}..."
echo "NOTE: Creating this AFTER failover to ensure DNS points to correct region."
echo ""

# Check if PE already exists
PE_EXISTS=$(az network private-endpoint show \
  --name "${PE_SECONDARY}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query id -o tsv 2>/dev/null || echo "")

if [ -z "$PE_EXISTS" ]; then
  SUBNET_PE_ID_SECONDARY=$(az network vnet subnet show \
    --resource-group "${RESOURCE_GROUP}" \
    --vnet-name "${VNET_SECONDARY}" \
    --name "${SUBNET_PE_SECONDARY}" \
    --query id -o tsv)

  STORAGE_ID=$(az storage account show \
    --name "${STORAGE_ACCOUNT}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query id -o tsv)

  az network private-endpoint create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${PE_SECONDARY}" \
    --location "${LOCATION_SECONDARY}" \
    --subnet "${SUBNET_PE_ID_SECONDARY}" \
    --private-connection-resource-id "${STORAGE_ID}" \
    --group-id blob \
    --connection-name "${PE_SECONDARY}-connection"

  # Create DNS zone group for automatic DNS registration
  az network private-endpoint dns-zone-group create \
    --resource-group "${RESOURCE_GROUP}" \
    --endpoint-name "${PE_SECONDARY}" \
    --name "blob-dns-zone-group" \
    --private-dns-zone "privatelink.blob.core.windows.net" \
    --zone-name blob

  # Get the private endpoint IP
  PE_IP_SECONDARY=$(az network private-endpoint show \
    --name "${PE_SECONDARY}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query 'customDnsConfigs[0].ipAddresses[0]' -o tsv 2>/dev/null || \
    az network nic show --ids $(az network private-endpoint show \
      --name "${PE_SECONDARY}" \
      --resource-group "${RESOURCE_GROUP}" \
      --query 'networkInterfaces[0].id' -o tsv) \
    --query 'ipConfigurations[0].privateIPAddress' -o tsv)

  echo "Secondary private endpoint created successfully!"
  echo "IP Address: ${PE_IP_SECONDARY}"
  
  # Verify DNS has been updated
  echo ""
  echo "Verifying DNS records..."
  az network private-dns record-set a show \
    --resource-group "${RESOURCE_GROUP}" \
    --zone-name privatelink.blob.core.windows.net \
    --name "${STORAGE_ACCOUNT}" \
    --query 'aRecords[].ipv4Address' -o tsv
  
  echo ""
  echo "Waiting 30 seconds for DNS propagation..."
  sleep 30
else
  echo "Private endpoint ${PE_SECONDARY} already exists."
  PE_IP_SECONDARY=$(az network nic show --ids $(az network private-endpoint show \
    --name "${PE_SECONDARY}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query 'networkInterfaces[0].id' -o tsv) \
    --query 'ipConfigurations[0].privateIPAddress' -o tsv)
  echo "IP Address: ${PE_IP_SECONDARY}"
fi

# Step 2: Create namespace
echo ""
echo "Step 2: Creating namespace..."
kubectl create namespace blob-demo --dry-run=client -o yaml | kubectl apply -f -

# Step 3: Create StorageClass
echo ""
echo "Step 3: Creating StorageClass with MSI authentication..."

cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: blob-fuse-grs
provisioner: blob.csi.azure.com
parameters:
  skuName: Standard_GRS
  protocol: fuse
  resourceGroup: ${RESOURCE_GROUP}
  storageAccount: ${STORAGE_ACCOUNT}
  AzureStorageAuthType: MSI
  AzureStorageIdentityClientID: "${IDENTITY_CLIENT_ID_SECONDARY}"
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
mountOptions:
  - -o allow_other
  - --file-cache-timeout-in-seconds=120
  - --use-attr-cache=true
  - --cancel-list-on-mount-seconds=10
  - -o attr_timeout=120
  - -o entry_timeout=120
  - -o negative_timeout=120
  - --log-level=LOG_WARNING
  - --cache-size-mb=1000
EOF

# Step 4: Create PersistentVolume and PersistentVolumeClaim
echo ""
echo "Step 4: Creating PersistentVolume and PersistentVolumeClaim..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-blob-grs-secondary
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: blob-fuse-grs
  mountOptions:
    - -o allow_other
    - --file-cache-timeout-in-seconds=120
  csi:
    driver: blob.csi.azure.com
    volumeHandle: "${RESOURCE_GROUP}-${STORAGE_ACCOUNT}-${CONTAINER_NAME}-secondary"
    volumeAttributes:
      protocol: fuse
      resourceGroup: ${RESOURCE_GROUP}
      storageAccount: ${STORAGE_ACCOUNT}
      containerName: ${CONTAINER_NAME}
      AzureStorageAuthType: MSI
      AzureStorageIdentityClientID: "${IDENTITY_CLIENT_ID_SECONDARY}"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-blob-grs
  namespace: blob-demo
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
  volumeName: pv-blob-grs-secondary
  storageClassName: blob-fuse-grs
EOF

echo "Waiting for PVC to be bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/pvc-blob-grs -n blob-demo --timeout=60s

# Step 5: Deploy reader deployment
echo ""
echo "Step 5: Deploying reader deployment..."

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: blob-reader
  namespace: blob-demo
  labels:
    app: blob-reader
spec:
  replicas: 1
  selector:
    matchLabels:
      app: blob-reader
  template:
    metadata:
      labels:
        app: blob-reader
      name: blob-reader
    spec:
      nodeSelector:
        "kubernetes.io/os": linux
      containers:
        - name: reader
          image: mcr.microsoft.com/mirror/docker/library/nginx:1.23
          command:
            - "/bin/sh"
            - "-c"
            - |
              echo "==================================================="
              echo "Blob Reader Pod - Reading content after failover"
              echo "==================================================="
              echo ""
              echo "Current time: \$(date)"
              echo "Hostname: \$(hostname)"
              echo "Location: East US 2 (Secondary - now Primary after failover)"
              echo ""
              
              echo "Reading data.txt created in primary region..."
              echo ""
              cat /mnt/blob/data.txt
              echo ""
              
              echo "Reading continuous writes from primary (before failover)..."
              echo "Last 20 lines:"
              tail -20 /mnt/blob/outfile || echo "No outfile found"
              echo ""
              
              echo "All files in storage:"
              ls -lah /mnt/blob/
              echo ""
              
              echo "==================================================="
              echo "SUCCESS! Data accessible after GRS failover!"
              echo "==================================================="
              echo ""
              
              # Keep running
              echo "Keeping pod running..."
              tail -f /dev/null
          volumeMounts:
            - name: blob
              mountPath: "/mnt/blob"
              readOnly: false
      volumes:
        - name: blob
          persistentVolumeClaim:
            claimName: pvc-blob-grs
  strategy:
    rollingUpdate:
      maxSurge: 0
      maxUnavailable: 1
EOF

echo ""
echo "Waiting for reader deployment to be ready..."
kubectl wait --for=condition=Available deployment/blob-reader -n blob-demo --timeout=120s

echo ""
echo "Checking deployment status..."
kubectl get deployment,pod -n blob-demo

echo ""
echo "Reading data from storage..."
sleep 5
kubectl logs -n blob-demo deployment/blob-reader --tail=50

echo ""
echo "======================================================="
echo "Secondary workload deployed successfully!"
echo "======================================================="
echo ""
echo "Summary:"
echo "--------"
echo "✓ Private endpoint created in ${LOCATION_SECONDARY}"
echo "✓ Reader deployment running"
echo "✓ Data accessible from failed-over storage account"
echo ""
echo "To view logs:"
echo "  kubectl config use-context aks-secondary"
echo "  kubectl logs -n blob-demo deployment/blob-reader -f"
echo ""
echo "GRS Failover Demo Complete!"
echo ""
