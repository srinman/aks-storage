#!/bin/bash
set -e

# Load variables
source /tmp/grs-demo-vars.sh

echo "=================================================="
echo "Deploying workload in primary cluster (centralus)"
echo "=================================================="
echo ""

kubectl config use-context aks-primary

# Step 1: Create namespace
echo "Step 1: Creating namespace..."
kubectl create namespace blob-demo --dry-run=client -o yaml | kubectl apply -f -

# Step 2: Create StorageClass
echo ""
echo "Step 2: Creating StorageClass with MSI authentication..."

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
  AzureStorageIdentityClientID: "${IDENTITY_CLIENT_ID_PRIMARY}"
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

# Step 3: Create PersistentVolume and PersistentVolumeClaim
echo ""
echo "Step 3: Creating PersistentVolume and PersistentVolumeClaim..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-blob-grs
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
    volumeHandle: "${RESOURCE_GROUP}-${STORAGE_ACCOUNT}-${CONTAINER_NAME}"
    volumeAttributes:
      protocol: fuse
      resourceGroup: ${RESOURCE_GROUP}
      storageAccount: ${STORAGE_ACCOUNT}
      containerName: ${CONTAINER_NAME}
      AzureStorageAuthType: MSI
      AzureStorageIdentityClientID: "${IDENTITY_CLIENT_ID_PRIMARY}"
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
  volumeName: pv-blob-grs
  storageClassName: blob-fuse-grs
EOF

echo "Waiting for PVC to be bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/pvc-blob-grs -n blob-demo --timeout=60s

# Step 4: Deploy writer deployment
echo ""
echo "Step 4: Deploying writer deployment..."

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: blob-writer
  namespace: blob-demo
  labels:
    app: blob-writer
spec:
  replicas: 1
  selector:
    matchLabels:
      app: blob-writer
  template:
    metadata:
      labels:
        app: blob-writer
      name: blob-writer
    spec:
      nodeSelector:
        "kubernetes.io/os": linux
      containers:
        - name: writer
          image: mcr.microsoft.com/mirror/docker/library/nginx:1.23
          command:
            - "/bin/sh"
            - "-c"
            - |
              echo "==================================================="
              echo "Blob Writer Pod - Writing sample content"
              echo "==================================================="
              echo ""
              echo "Current time: \$(date)"
              echo "Hostname: \$(hostname)"
              echo "Location: Central US (Primary)"
              echo ""
              
              # Write main data file
              cat > /mnt/blob/data.txt <<DATAEOF
              =================================================
              GRS Storage Failover Demo
              =================================================
              
              This file was created in the PRIMARY region (Central US)
              
              Created at: \$(date)
              Hostname: \$(hostname)
              Region: Central US
              Storage Account: ${STORAGE_ACCOUNT}
              Container: ${CONTAINER_NAME}
              
              Sample data:
              - Line 1: Hello from Central US!
              - Line 2: This is a GRS storage demo
              - Line 3: Testing geo-redundant storage
              - Line 4: Random value: \$(od -An -N4 -tu4 < /dev/urandom | tr -d ' ')
              
              This content will be replicated to East US 2 via GRS.
              After failover, it should be readable from the secondary region.
              =================================================
              DATAEOF
              
              echo "Content written successfully!"
              echo ""
              echo "File contents:"
              cat /mnt/blob/data.txt
              echo ""
              
              # Continuous writing to demonstrate live replication
              echo "Starting continuous writes..."
              while true; do 
                echo "\$(date) - Write from Central US (Primary)" >> /mnt/blob/outfile
                sleep 1
              done
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
echo "Waiting for writer deployment to be ready..."
kubectl wait --for=condition=Available deployment/blob-writer -n blob-demo --timeout=120s

# Save deployment time for failover timing
date +%s > /tmp/grs-demo-deployment-time

echo ""
echo "Checking deployment status..."
kubectl get deployment,pod -n blob-demo

echo ""
echo "=================================================="
echo "Workload deployed in primary cluster!"
echo "=================================================="
echo ""
echo "To view logs:"
echo "  kubectl config use-context aks-primary"
echo "  kubectl logs -n blob-demo deployment/blob-writer -f"
echo ""
echo "To verify data in storage:"
echo "  kubectl exec -it -n blob-demo deployment/blob-writer -- cat /mnt/blob/data.txt"
echo ""
echo "Next steps:"
echo "  1. Wait for GRS replication (15 minutes recommended)"
echo "  2. Run: ./initiate-failover.sh"
echo "  3. Run: ./deploy-secondary-workload.sh"
echo ""
