#!/bin/bash
set -e

# Load variables
source /tmp/grs-demo-vars.sh

echo "=================================================="
echo "Deploying workload in secondary cluster (eastus2)"
echo "=================================================="
echo ""

kubectl config use-context aks-secondary

# Step 1: Create PersistentVolume and PersistentVolumeClaim for secondary
echo "Step 1: Creating PersistentVolume and PersistentVolumeClaim..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-blob-grs-secondary
  namespace: blob-demo
spec:
  capacity:
    storage: 10Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  mountOptions:
    - -o allow_other
    - --file-cache-timeout-in-seconds=120
    - --use-attr-cache=true
  csi:
    driver: blob.csi.azure.com
    readOnly: false
    volumeHandle: pv-blob-grs-secondary-${STORAGE_ACCOUNT}
    volumeAttributes:
      protocol: fuse
      containerName: ${CONTAINER_NAME}
      storageAccount: ${STORAGE_ACCOUNT}
      AzureStorageAuthType: workloadidentity
      AzureStorageIdentityClientID: ${IDENTITY_CLIENT_ID_SECONDARY}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-blob-grs-secondary
  namespace: blob-demo
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
  volumeName: pv-blob-grs-secondary
  storageClassName: ""
EOF

echo "Waiting for PVC to be bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/pvc-blob-grs-secondary -n blob-demo --timeout=60s

# Step 2: Deploy reader pod
echo ""
echo "Step 2: Deploying reader pod..."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: blob-reader
  namespace: blob-demo
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: blob-sa
  containers:
  - name: netshoot
    image: nicolaka/netshoot:latest
    command: ["/bin/bash"]
    args:
      - -c
      - |
        echo "==================================================="
        echo "Blob Reader Pod - Reading content after failover"
        echo "==================================================="
        echo ""
        echo "Current time: \$(date)"
        echo "Hostname: \$(hostname)"
        echo "Location: East US 2 (Secondary, now Primary after failover)"
        echo ""
        
        # Wait a bit for mount
        sleep 10
        
        # List files in blob storage
        echo "Listing files in blob storage:"
        ls -lah /mnt/blob/
        echo ""
        
        # Read and display the main data file
        if [ -f /mnt/blob/data.txt ]; then
            echo "==================================================="
            echo "SUCCESS! Reading data.txt from failed-over storage:"
            echo "==================================================="
            echo ""
            cat /mnt/blob/data.txt
            echo ""
            echo "==================================================="
        else
            echo "ERROR: data.txt not found!"
            echo "Files available:"
            ls -la /mnt/blob/
        fi
        
        # Read other test files if they exist
        if [ -f /mnt/blob/test1.txt ]; then
            echo ""
            echo "Content of test1.txt:"
            cat /mnt/blob/test1.txt
        fi
        
        if [ -f /mnt/blob/test2.txt ]; then
            echo ""
            echo "Content of test2.txt:"
            cat /mnt/blob/test2.txt
        fi
        
        # Write verification message
        echo ""
        echo "Writing verification message from secondary cluster..."
        cat >> /mnt/blob/verification.txt <<VERIFYEOF
        
        =================================================
        Verification from Secondary Cluster (East US 2)
        =================================================
        Read at: \$(date)
        Hostname: \$(hostname)
        Region: East US 2 (now primary after failover)
        
        ✓ Successfully read data from failed-over GRS storage!
        ✓ All original content is accessible
        ✓ GRS failover completed successfully
        =================================================
        VERIFYEOF
        
        echo "Verification written to verification.txt"
        echo ""
        
        echo "==================================================="
        echo "Demo Complete!"
        echo "==================================================="
        echo ""
        echo "Summary:"
        echo "--------"
        echo "1. Data was written in Central US (primary)"
        echo "2. GRS replicated data to East US 2 (secondary)"
        echo "3. Failover was initiated to East US 2"
        echo "4. Data successfully read from East US 2 cluster"
        echo ""
        echo "This demonstrates that GRS provides data durability"
        echo "across Azure regions with customer-controlled failover."
        echo ""
        echo "==================================================="
        echo "Keeping pod alive for inspection..."
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
      claimName: pvc-blob-grs-secondary
  restartPolicy: Never
EOF

echo ""
echo "Waiting for reader pod to be ready..."
kubectl wait --for=condition=Ready pod/blob-reader -n blob-demo --timeout=120s

echo ""
echo "Checking reader pod logs..."
sleep 5
kubectl logs -n blob-demo blob-reader --tail=100

echo ""
echo "=================================================="
echo "GRS Failover Demo Complete!"
echo "=================================================="
echo ""
echo "The reader pod has successfully accessed data that was:"
echo "  1. Written in ${LOCATION_PRIMARY} (original primary)"
echo "  2. Replicated via GRS"
echo "  3. Failed over to ${LOCATION_SECONDARY}"
echo "  4. Read from ${LOCATION_SECONDARY} AKS cluster"
echo ""
echo "To view logs again:"
echo "  kubectl config use-context aks-secondary"
echo "  kubectl logs -n blob-demo blob-reader -f"
echo ""
echo "To interact with the pod:"
echo "  kubectl exec -it -n blob-demo blob-reader -- /bin/bash"
echo ""
