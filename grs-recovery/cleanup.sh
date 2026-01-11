#!/bin/bash
set -e

# Load variables
source /tmp/grs-demo-vars.sh

echo "=================================================="
echo "Cleaning up GRS Demo Resources"
echo "=================================================="
echo ""

echo "This will delete the following resources:"
echo "  - Resource Group: ${RESOURCE_GROUP}"
echo "  - All AKS clusters, VNets, Storage Account, etc."
echo ""

read -p "Are you sure you want to delete all resources? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo ""
echo "Deleting resource group and all resources..."
echo "This may take several minutes..."

az group delete \
  --name "${RESOURCE_GROUP}" \
  --yes \
  --no-wait

echo ""
echo "Deletion initiated. Check status with:"
echo "  az group show --name ${RESOURCE_GROUP}"
echo ""
echo "Cleaning up local kubeconfig contexts..."

kubectl config delete-context aks-primary 2>/dev/null || true
kubectl config delete-context aks-secondary 2>/dev/null || true

echo ""
echo "Removing temporary variables file..."
rm -f /tmp/grs-demo-vars.sh

echo ""
echo "=================================================="
echo "Cleanup complete!"
echo "=================================================="
echo ""
