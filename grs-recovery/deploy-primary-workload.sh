#!/bin/bash
set -e

# Load variables
source /tmp/grs-demo-vars.sh

echo "=================================================="
echo "Deploying workload in primary cluster (centralus)"
echo "=================================================="
echo ""

kubectl config use-context aks-primary

# Step 1: Create PersistentVolume and PersistentVolumeClaim
echo "Step 1: Creating PersistentVolume and PersistentVolumeClaim..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  annotations:
    pv.kubernetes.io/provisioned-by: blob.csi.azure.com
  name: pv-blob-grs
spec:
  capacity:
    storage: 1Pi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: azureblob-fuse-premium
  mountOptions:
    - -o allow_other
    - --file-cache-timeout-in-seconds=120
    - --use-attr-cache=true
  csi:
    driver: blob.csi.azure.com
    readOnly: false
    volumeHandle: ${STORAGE_ACCOUNT}_${CONTAINER_NAME}_grs
    nodeStageSecretRef:
      name: azure-storage-account-${STORAGE_ACCOUNT}-secret
      namespace: blob-demo
    volumeAttributes:
      resourceGroup: ${RESOURCE_GROUP}
      storageAccount: ${STORAGE_ACCOUNT}
      containerName: ${CONTAINER_NAME}
      protocol: fuse
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
  storageClassName: azureblob-fuse-premium
EOF

echo "Waiting for PVC to be bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/pvc-blob-grs -n blob-demo --timeout=60s

# Step 2: Deploy writer pod
echo ""
echo "Step 2: Deploying writer pod..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: blob-writer
  namespace: blob-demo
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: blob-sa
  nodeSelector:
    kubernetes.io/hostname: aks-nodepool1-58701815-vmss000001
  containers:
  - name: netshoot
    image: nicolaka/netshoot:latest
    command: ["/bin/bash"]
    args:
      - -c
      - |
        echo "==================================================="
        echo "Blob Writer Pod - Writing sample content"
        echo "==================================================="
        echo ""
        echo "Current time: \$(date)"
        echo "Hostname: \$(hostname)"
        echo "Location: Central US (Primary)"
        echo ""
        
        # Write sample data
        echo "Writing sample content to /mnt/blob/data.txt..."
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
        
        # Create additional test files
        echo "Creating additional test files..."
        echo "Test file 1 created at \$(date)" > /mnt/blob/test1.txt
        echo "Test file 2 created at \$(date)" > /mnt/blob/test2.txt
        
        # List all files
        echo "Files in blob storage:"
        ls -lah /mnt/blob/
        echo ""
        
        echo "==================================================="
        echo "Writer pod completed. Keeping pod alive..."
        echo "==================================================="
        
        # Keep container running
        tail -f /dev/null
    volumeMounts:
    - name: blob-storage
      mountPath: /mnt/blob
      readOnly: false
  volumes:
  - name: blob-storage
    persistentVolumeClaim:
      claimName: pvc-blob-grs
  restartPolicy: Never
EOF

echo ""
echo "Waiting for writer pod to be ready..."
kubectl wait --for=condition=Ready pod/blob-writer -n blob-demo --timeout=120s

echo ""
echo "Checking writer pod logs..."
sleep 5
kubectl logs -n blob-demo blob-writer --tail=50

echo ""
echo "=================================================="
echo "Workload deployed in primary cluster!"
echo "=================================================="
echo ""
echo "To view logs:"
echo "  kubectl config use-context aks-primary"
echo "  kubectl logs -n blob-demo blob-writer -f"
echo ""
echo "To verify data in storage:"
echo "  kubectl exec -it -n blob-demo blob-writer -- cat /mnt/blob/data.txt"
echo ""
echo "Next: Wait for GRS replication, then run initiate-failover.sh"
echo ""
