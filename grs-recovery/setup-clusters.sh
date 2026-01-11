#!/bin/bash
set -e

# Setup AKS Clusters and Network Infrastructure
# This is the slow part - only run once

# Variables
RESOURCE_GROUP="rg-aks-grsdemo"
LOCATION_PRIMARY="centralus"
LOCATION_SECONDARY="eastus2"

# VNet and Subnet Configuration
VNET_PRIMARY="vnet-aks-${LOCATION_PRIMARY}"
VNET_SECONDARY="vnet-aks-${LOCATION_SECONDARY}"
VNET_ADDRESS_PRIMARY="10.1.0.0/16"
VNET_ADDRESS_SECONDARY="10.2.0.0/16"

SUBNET_AKS_PRIMARY="subnet-aks-${LOCATION_PRIMARY}"
SUBNET_AKS_SECONDARY="subnet-aks-${LOCATION_SECONDARY}"
SUBNET_AKS_ADDRESS_PRIMARY="10.1.0.0/22"
SUBNET_AKS_ADDRESS_SECONDARY="10.2.0.0/22"

SUBNET_PE_PRIMARY="subnet-pe-${LOCATION_PRIMARY}"
SUBNET_PE_SECONDARY="subnet-pe-${LOCATION_SECONDARY}"
SUBNET_PE_ADDRESS_PRIMARY="10.1.4.0/24"
SUBNET_PE_ADDRESS_SECONDARY="10.2.4.0/24"

# AKS Configuration
AKS_PRIMARY="aks-${LOCATION_PRIMARY}"
AKS_SECONDARY="aks-${LOCATION_SECONDARY}"
AKS_NODE_COUNT=2
AKS_NODE_SIZE="Standard_DS2_v2"

echo "=================================================="
echo "GRS Demo - Cluster Setup"
echo "=================================================="
echo ""
echo "Resource Group: ${RESOURCE_GROUP}"
echo "Primary Location: ${LOCATION_PRIMARY}"
echo "Secondary Location: ${LOCATION_SECONDARY}"
echo ""
echo "This script creates:"
echo "  - Resource Group"
echo "  - VNets and Subnets (AKS + Private Endpoint)"
echo "  - AKS Clusters with OIDC and Workload Identity"
echo ""
echo "Duration: ~15-20 minutes"
echo ""

# Step 1: Create Resource Group
echo "Step 1: Creating resource group..."
az group create \
  --name "${RESOURCE_GROUP}" \
  --location "${LOCATION_PRIMARY}"

# Step 2: Create VNets and Subnets in Primary Region (centralus)
echo ""
echo "Step 2: Creating VNet and subnets in ${LOCATION_PRIMARY}..."

az network vnet create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${VNET_PRIMARY}" \
  --location "${LOCATION_PRIMARY}" \
  --address-prefix "${VNET_ADDRESS_PRIMARY}"

az network vnet subnet create \
  --resource-group "${RESOURCE_GROUP}" \
  --vnet-name "${VNET_PRIMARY}" \
  --name "${SUBNET_AKS_PRIMARY}" \
  --address-prefix "${SUBNET_AKS_ADDRESS_PRIMARY}"

az network vnet subnet create \
  --resource-group "${RESOURCE_GROUP}" \
  --vnet-name "${VNET_PRIMARY}" \
  --name "${SUBNET_PE_PRIMARY}" \
  --address-prefix "${SUBNET_PE_ADDRESS_PRIMARY}" \
  --disable-private-endpoint-network-policies true

# Step 3: Create VNets and Subnets in Secondary Region (eastus2)
echo ""
echo "Step 3: Creating VNet and subnets in ${LOCATION_SECONDARY}..."

az network vnet create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${VNET_SECONDARY}" \
  --location "${LOCATION_SECONDARY}" \
  --address-prefix "${VNET_ADDRESS_SECONDARY}"

az network vnet subnet create \
  --resource-group "${RESOURCE_GROUP}" \
  --vnet-name "${VNET_SECONDARY}" \
  --name "${SUBNET_AKS_SECONDARY}" \
  --address-prefix "${SUBNET_AKS_ADDRESS_SECONDARY}"

az network vnet subnet create \
  --resource-group "${RESOURCE_GROUP}" \
  --vnet-name "${VNET_SECONDARY}" \
  --name "${SUBNET_PE_SECONDARY}" \
  --address-prefix "${SUBNET_PE_ADDRESS_SECONDARY}" \
  --disable-private-endpoint-network-policies true

# Step 4: Create AKS Cluster in Primary Region (centralus)
echo ""
echo "Step 4: Creating AKS cluster in ${LOCATION_PRIMARY}..."
echo "This may take 5-10 minutes..."

SUBNET_ID_PRIMARY=$(az network vnet subnet show \
  --resource-group "${RESOURCE_GROUP}" \
  --vnet-name "${VNET_PRIMARY}" \
  --name "${SUBNET_AKS_PRIMARY}" \
  --query id -o tsv)

az aks create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${AKS_PRIMARY}" \
  --location "${LOCATION_PRIMARY}" \
  --node-count ${AKS_NODE_COUNT} \
  --node-vm-size ${AKS_NODE_SIZE} \
  --network-plugin azure \
  --vnet-subnet-id "${SUBNET_ID_PRIMARY}" \
  --enable-managed-identity \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --generate-ssh-keys

# Step 5: Create AKS Cluster in Secondary Region (eastus2)
echo ""
echo "Step 5: Creating AKS cluster in ${LOCATION_SECONDARY}..."
echo "This may take 5-10 minutes..."

SUBNET_ID_SECONDARY=$(az network vnet subnet show \
  --resource-group "${RESOURCE_GROUP}" \
  --vnet-name "${VNET_SECONDARY}" \
  --name "${SUBNET_AKS_SECONDARY}" \
  --query id -o tsv)

az aks create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${AKS_SECONDARY}" \
  --location "${LOCATION_SECONDARY}" \
  --node-count ${AKS_NODE_COUNT} \
  --node-vm-size ${AKS_NODE_SIZE} \
  --network-plugin azure \
  --vnet-subnet-id "${SUBNET_ID_SECONDARY}" \
  --enable-managed-identity \
  --enable-oidc-issuer \
  --enable-workload-identity \
  --generate-ssh-keys

# Step 6: Get AKS Credentials
echo ""
echo "Step 6: Getting AKS credentials..."

az aks get-credentials \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${AKS_PRIMARY}" \
  --context "aks-primary" \
  --overwrite-existing

az aks get-credentials \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${AKS_SECONDARY}" \
  --context "aks-secondary" \
  --overwrite-existing

echo ""
echo "=================================================="
echo "Cluster setup complete!"
echo "=================================================="
echo ""
echo "Summary:"
echo "--------"
echo "Resource Group: ${RESOURCE_GROUP}"
echo "Primary AKS: ${AKS_PRIMARY} (${LOCATION_PRIMARY})"
echo "Secondary AKS: ${AKS_SECONDARY} (${LOCATION_SECONDARY})"
echo ""
echo "Contexts:"
echo "  Primary: aks-primary"
echo "  Secondary: aks-secondary"
echo ""
echo "Next: Run setup-dependent-resources.sh"
echo ""

# Save base variables
cat > /tmp/grs-demo-base-vars.sh <<EOF
export RESOURCE_GROUP="${RESOURCE_GROUP}"
export LOCATION_PRIMARY="${LOCATION_PRIMARY}"
export LOCATION_SECONDARY="${LOCATION_SECONDARY}"
export AKS_PRIMARY="${AKS_PRIMARY}"
export AKS_SECONDARY="${AKS_SECONDARY}"
export VNET_PRIMARY="${VNET_PRIMARY}"
export VNET_SECONDARY="${VNET_SECONDARY}"
export SUBNET_PE_PRIMARY="${SUBNET_PE_PRIMARY}"
export SUBNET_PE_SECONDARY="${SUBNET_PE_SECONDARY}"
EOF

echo "Base variables saved to /tmp/grs-demo-base-vars.sh"
