#!/bin/bash
set -e

# Cleanup Dependent Resources Only (keeps AKS clusters)
# This allows quick cleanup and recreation for testing

# Load variables
if [ -f /tmp/grs-demo-vars.sh ]; then
  source /tmp/grs-demo-vars.sh
else
  echo "ERROR: Variables not found. Cannot determine resources to delete."
  exit 1
fi

echo "=================================================="
echo "Cleanup Dependent Resources"
echo "=================================================="
echo ""
echo "This will delete:"
echo "  - Storage Account: ${STORAGE_ACCOUNT}"
echo "  - Private Endpoints: ${PE_PRIMARY}, ${PE_SECONDARY}"
echo "  - Private DNS Zone: privatelink.blob.core.windows.net"
echo ""
echo "This will KEEP:"
echo "  - AKS Clusters: ${AKS_PRIMARY}, ${AKS_SECONDARY}"
echo "  - VNets and Subnets"
echo "  - Resource Group: ${RESOURCE_GROUP}"
echo ""

read -p "Are you sure you want to delete dependent resources? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo ""
echo "Step 1: Deleting private endpoints..."

# Delete primary private endpoint
PE_EXISTS=$(az network private-endpoint show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${PE_PRIMARY}" \
  --query id -o tsv 2>/dev/null || echo "")

if [ -n "$PE_EXISTS" ]; then
  echo "Deleting primary private endpoint: ${PE_PRIMARY}"
  az network private-endpoint delete \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${PE_PRIMARY}" \
    --yes \
    --no-wait
else
  echo "Primary private endpoint not found (already deleted or doesn't exist)"
fi

# Delete secondary private endpoint
PE_EXISTS=$(az network private-endpoint show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${PE_SECONDARY}" \
  --query id -o tsv 2>/dev/null || echo "")

if [ -n "$PE_EXISTS" ]; then
  echo "Deleting secondary private endpoint: ${PE_SECONDARY}"
  az network private-endpoint delete \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${PE_SECONDARY}" \
    --yes \
    --no-wait
else
  echo "Secondary private endpoint not found (already deleted or doesn't exist)"
fi

echo ""
echo "Step 2: Deleting Private DNS Zone..."

DNS_ZONE_EXISTS=$(az network private-dns zone show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "privatelink.blob.core.windows.net" \
  --query id -o tsv 2>/dev/null || echo "")

if [ -n "$DNS_ZONE_EXISTS" ]; then
  echo "Deleting Private DNS zone and all links..."
  az network private-dns zone delete \
    --resource-group "${RESOURCE_GROUP}" \
    --name "privatelink.blob.core.windows.net" \
    --yes
else
  echo "Private DNS zone not found (already deleted or doesn't exist)"
fi

echo ""
echo "Step 3: Deleting storage account..."

STORAGE_EXISTS=$(az storage account show \
  --name "${STORAGE_ACCOUNT}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query id -o tsv 2>/dev/null || echo "")

if [ -n "$STORAGE_EXISTS" ]; then
  echo "Deleting storage account: ${STORAGE_ACCOUNT}"
  az storage account delete \
    --name "${STORAGE_ACCOUNT}" \
    --resource-group "${RESOURCE_GROUP}" \
    --yes
else
  echo "Storage account not found (already deleted or doesn't exist)"
fi

echo ""
echo "Step 4: Waiting for resource deletion to complete..."
echo "Checking private endpoints deletion status..."

for i in {1..30}; do
  PE_PRIMARY_EXISTS=$(az network private-endpoint show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${PE_PRIMARY}" \
    --query id -o tsv 2>/dev/null || echo "")
  
  PE_SECONDARY_EXISTS=$(az network private-endpoint show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${PE_SECONDARY}" \
    --query id -o tsv 2>/dev/null || echo "")
  
  if [ -z "$PE_PRIMARY_EXISTS" ] && [ -z "$PE_SECONDARY_EXISTS" ]; then
    echo "Private endpoints deleted successfully"
    break
  fi
  
  if [ $i -eq 30 ]; then
    echo "Warning: Some private endpoints may still be deleting"
  else
    echo "  Waiting... ($i/30)"
    sleep 5
  fi
done

echo ""
echo "Step 5: Cleaning up Kubernetes resources..."

# Delete namespaces from both clusters (if they exist)
kubectl delete namespace blob-demo --context aks-primary --ignore-not-found=true 2>/dev/null || true
kubectl delete namespace blob-demo --context aks-secondary --ignore-not-found=true 2>/dev/null || true

echo ""
echo "=================================================="
echo "Dependent resources cleanup complete!"
echo "=================================================="
echo ""
echo "Deleted:"
echo "  ✓ Storage account and container"
echo "  ✓ Private endpoints (both regions)"
echo "  ✓ Private DNS zone"
echo "  ✓ Kubernetes namespaces"
echo ""
echo "Preserved:"
echo "  ✓ AKS clusters: ${AKS_PRIMARY}, ${AKS_SECONDARY}"
echo "  ✓ VNets and subnets"
echo "  ✓ Resource group: ${RESOURCE_GROUP}"
echo ""
echo "To recreate dependent resources:"
echo "  ./setup-dependent-resources.sh"
echo ""
echo "To delete everything including clusters:"
echo "  ./cleanup.sh"
echo ""
