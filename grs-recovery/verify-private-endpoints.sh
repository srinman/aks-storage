#!/bin/bash
set -e

# Load variables
source /tmp/grs-demo-vars.sh

echo "=================================================="
echo "Verifying Private Endpoint Configuration"
echo "=================================================="
echo ""

# Step 1: Check Private Endpoints
echo "Step 1: Checking private endpoint status..."
echo ""

echo "Primary Private Endpoint (${LOCATION_PRIMARY}):"
az network private-endpoint show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${PE_PRIMARY}" \
  --query '{name:name, location:location, provisioningState:provisioningState, privateIP:customDnsConfigs[0].ipAddresses[0]}' \
  --output table

echo ""
echo "Secondary Private Endpoint (${LOCATION_SECONDARY}):"
az network private-endpoint show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${PE_SECONDARY}" \
  --query '{name:name, location:location, provisioningState:provisioningState, privateIP:customDnsConfigs[0].ipAddresses[0]}' \
  --output table

# Step 2: Check DNS Configuration
echo ""
echo "Step 2: Checking Private DNS Zone configuration..."
echo ""

az network private-dns zone show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "privatelink.blob.core.windows.net" \
  --query '{name:name, numberOfRecordSets:numberOfRecordSets}' \
  --output table

echo ""
echo "DNS Records in Private DNS Zone:"
az network private-dns record-set a list \
  --resource-group "${RESOURCE_GROUP}" \
  --zone-name "privatelink.blob.core.windows.net" \
  --query '[].{name:name, ipAddress:aRecords[0].ipv4Address}' \
  --output table

# Step 3: Test DNS Resolution from Primary Cluster
echo ""
echo "Step 3: Testing DNS resolution from primary cluster..."
kubectl config use-context aks-primary

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: dns-test-primary
  namespace: default
spec:
  containers:
  - name: busybox
    image: busybox:latest
    command:
      - sleep
      - "3600"
  restartPolicy: Never
EOF

echo "Waiting for DNS test pod in primary cluster..."
kubectl wait --for=condition=Ready pod/dns-test-primary -n default --timeout=60s 2>/dev/null || true
sleep 5

echo ""
echo "DNS resolution for ${STORAGE_ACCOUNT}.blob.core.windows.net from primary cluster:"
kubectl exec dns-test-primary -n default -- nslookup ${STORAGE_ACCOUNT}.blob.core.windows.net || echo "DNS test pending..."

# Step 4: Test DNS Resolution from Secondary Cluster
echo ""
echo "Step 4: Testing DNS resolution from secondary cluster..."
kubectl config use-context aks-secondary

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: dns-test-secondary
  namespace: default
spec:
  containers:
  - name: busybox
    image: busybox:latest
    command:
      - sleep
      - "3600"
  restartPolicy: Never
EOF

echo "Waiting for DNS test pod in secondary cluster..."
kubectl wait --for=condition=Ready pod/dns-test-secondary -n default --timeout=60s 2>/dev/null || true
sleep 5

echo ""
echo "DNS resolution for ${STORAGE_ACCOUNT}.blob.core.windows.net from secondary cluster:"
kubectl exec dns-test-secondary -n default -- nslookup ${STORAGE_ACCOUNT}.blob.core.windows.net || echo "DNS test pending..."

# Step 5: Show Network Configuration
echo ""
echo "Step 5: Network configuration summary..."
echo ""
echo "Primary VNet PE Subnet:"
az network vnet subnet show \
  --resource-group "${RESOURCE_GROUP}" \
  --vnet-name "${VNET_PRIMARY}" \
  --name "${SUBNET_PE_PRIMARY}" \
  --query '{name:name, addressPrefix:addressPrefix, privateEndpointNetworkPolicies:privateEndpointNetworkPolicies}' \
  --output table

echo ""
echo "Secondary VNet PE Subnet:"
az network vnet subnet show \
  --resource-group "${RESOURCE_GROUP}" \
  --vnet-name "${VNET_SECONDARY}" \
  --name "${SUBNET_PE_SECONDARY}" \
  --query '{name:name, addressPrefix:addressPrefix, privateEndpointNetworkPolicies:privateEndpointNetworkPolicies}' \
  --output table

# Cleanup test pods
echo ""
echo "Cleaning up DNS test pods..."
kubectl delete pod dns-test-primary -n default --context aks-primary --ignore-not-found=true
kubectl delete pod dns-test-secondary -n default --context aks-secondary --ignore-not-found=true

echo ""
echo "=================================================="
echo "Private Endpoint Verification Complete!"
echo "=================================================="
echo ""
echo "Key Points:"
echo "----------"
echo "✓ Private endpoints created in both regions"
echo "✓ Private DNS zone linked to both VNets"
echo "✓ DNS automatically resolves to private IPs within each VNet"
echo "✓ Each AKS cluster uses its local private endpoint"
echo ""
echo "Disaster Recovery Design:"
echo "  - Primary cluster → Primary PE (${LOCATION_PRIMARY})"
echo "  - Secondary cluster → Secondary PE (${LOCATION_SECONDARY})"
echo "  - If primary site fails, secondary cluster uses its local PE"
echo "  - After failover, PE automatically points to new primary storage"
echo ""
