#!/bin/bash
set -e

# GRS Storage Failover Demo with AKS
# This script sets up infrastructure for testing GRS storage failover between regions

# Variables
RESOURCE_GROUP="rg-aks-grs-demo"
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

# Storage Configuration
STORAGE_ACCOUNT="stgrsdemo$(date +%s | tail -c 10)"
CONTAINER_NAME="democontainer"

echo "=================================================="
echo "GRS Storage Failover Demo - Infrastructure Setup"
echo "=================================================="
echo ""
echo "Resource Group: ${RESOURCE_GROUP}"
echo "Primary Location: ${LOCATION_PRIMARY}"
echo "Secondary Location: ${LOCATION_SECONDARY}"
echo "Storage Account: ${STORAGE_ACCOUNT}"
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

# Step 6: Create GRS Storage Account
echo ""
echo "Step 6: Creating GRS storage account..."

az storage account create \
  --name "${STORAGE_ACCOUNT}" \
  --resource-group "${RESOURCE_GROUP}" \
  --location "${LOCATION_PRIMARY}" \
  --sku Standard_GRS \
  --kind StorageV2 \
  --allow-blob-public-access false \
  --public-network-access Enabled \
  --allow-shared-key-access true

echo ""
echo "NOTE: Shared key access is enabled for initial setup."
echo "      After workload identity is configured, you can disable it:"
echo "      az storage account update --name ${STORAGE_ACCOUNT} \\"
echo "        --resource-group ${RESOURCE_GROUP} \\"
echo "        --allow-shared-key-access false"

# Create container using Azure AD authentication (not storage keys)
echo "Creating container using Azure AD authentication..."

# Assign Storage Blob Data Contributor to current user temporarily for container creation
CURRENT_USER=$(az account show --query user.name -o tsv)
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee "${CURRENT_USER}" \
  --scope "${STORAGE_ID}" \
  --output none 2>/dev/null || true

# Wait a moment for RBAC propagation
sleep 10

az storage container create \
  --name "${CONTAINER_NAME}" \
  --account-name "${STORAGE_ACCOUNT}" \
  --auth-mode login

# Get storage account ID for private endpoint
STORAGE_ID=$(az storage account show \
  --name "${STORAGE_ACCOUNT}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query id -o tsv)

# Step 6b: Create Private DNS Zone for Blob Storage
echo ""
echo "Step 6b: Creating Private DNS Zone for blob storage..."

az network private-dns zone create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "privatelink.blob.core.windows.net"

# Link DNS zone to both VNets
az network private-dns link vnet create \
  --resource-group "${RESOURCE_GROUP}" \
  --zone-name "privatelink.blob.core.windows.net" \
  --name "dns-link-primary" \
  --virtual-network "${VNET_PRIMARY}" \
  --registration-enabled false

az network private-dns link vnet create \
  --resource-group "${RESOURCE_GROUP}" \
  --zone-name "privatelink.blob.core.windows.net" \
  --name "dns-link-secondary" \
  --virtual-network "${VNET_SECONDARY}" \
  --registration-enabled false

# Step 6c: Create Private Endpoint in Primary Region
echo ""
echo "Step 6c: Creating private endpoint in ${LOCATION_PRIMARY}..."
echo "This endpoint will be used by the primary AKS cluster."

PE_PRIMARY="pe-blob-${LOCATION_PRIMARY}"
PE_SECONDARY="pe-blob-${LOCATION_SECONDARY}"

SUBNET_PE_ID_PRIMARY=$(az network vnet subnet show \
  --resource-group "${RESOURCE_GROUP}" \
  --vnet-name "${VNET_PRIMARY}" \
  --name "${SUBNET_PE_PRIMARY}" \
  --query id -o tsv)

az network private-endpoint create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${PE_PRIMARY}" \
  --location "${LOCATION_PRIMARY}" \
  --subnet "${SUBNET_PE_ID_PRIMARY}" \
  --private-connection-resource-id "${STORAGE_ID}" \
  --group-id blob \
  --connection-name "${PE_PRIMARY}-connection"

# Create DNS zone group for automatic DNS registration (Primary)
az network private-endpoint dns-zone-group create \
  --resource-group "${RESOURCE_GROUP}" \
  --endpoint-name "${PE_PRIMARY}" \
  --name "blob-dns-zone-group" \
  --private-dns-zone "privatelink.blob.core.windows.net" \
  --zone-name blob

# Step 6d: Create Private Endpoint in Secondary Region
echo ""
echo "Step 6d: Creating private endpoint in ${LOCATION_SECONDARY}..."
echo "This endpoint will be used by the secondary AKS cluster after failover."

SUBNET_PE_ID_SECONDARY=$(az network vnet subnet show \
  --resource-group "${RESOURCE_GROUP}" \
  --vnet-name "${VNET_SECONDARY}" \
  --name "${SUBNET_PE_SECONDARY}" \
  --query id -o tsv)

az network private-endpoint create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${PE_SECONDARY}" \
  --location "${LOCATION_SECONDARY}" \
  --subnet "${SUBNET_PE_ID_SECONDARY}" \
  --private-connection-resource-id "${STORAGE_ID}" \
  --group-id blob \
  --connection-name "${PE_SECONDARY}-connection"

# Create DNS zone group for automatic DNS registration (Secondary)
az network private-endpoint dns-zone-group create \
  --resource-group "${RESOURCE_GROUP}" \
  --endpoint-name "${PE_SECONDARY}" \
  --name "blob-dns-zone-group" \
  --private-dns-zone "privatelink.blob.core.windows.net" \
  --zone-name blob

echo ""
echo "Private Endpoints Configuration:"
echo "--------------------------------"
echo "Per Microsoft guidance: Private endpoints automatically connect to the"
echo "new primary storage location after failover."
echo ""
echo "Disaster Recovery Design:"
echo "  - Primary cluster (${LOCATION_PRIMARY}) uses local PE in its VNet"
echo "  - Secondary cluster (${LOCATION_SECONDARY}) uses local PE in its VNet"
echo "  - If primary site is down, secondary cluster uses its local PE"
echo "  - Both PEs resolve via shared Private DNS zone"
echo "  - No DNS changes needed after failover!"

# Step 7: Get AKS Credentials
echo ""
echo "Step 7: Getting AKS credentials..."

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
echo "Infrastructure setup complete!"
echo "=================================================="
echo ""
echo "Summary:"
echo "--------"
echo "Resource Group: ${RESOURCE_GROUP}"
echo "Primary AKS: ${AKS_PRIMARY} (${LOCATION_PRIMARY})"
echo "Secondary AKS: ${AKS_SECONDARY} (${LOCATION_SECONDARY})"
echo "Storage Account: ${STORAGE_ACCOUNT} (GRS)"
echo "Container: ${CONTAINER_NAME}"
echo "Private Endpoints:"
echo "  Primary: ${PE_PRIMARY} (${LOCATION_PRIMARY})"
echo "  Secondary: ${PE_SECONDARY} (${LOCATION_SECONDARY})"
echo "Private DNS Zone: privatelink.blob.core.windows.net"
echo ""
echo "Contexts:"
echo "  Primary: aks-primary"
echo "  Secondary: aks-secondary"
echo ""
echo "Next: Run setup-workload-identity.sh"
echo ""

# Save variables for next scripts
cat > /tmp/grs-demo-vars.sh <<EOF
export RESOURCE_GROUP="${RESOURCE_GROUP}"
export LOCATION_PRIMARY="${LOCATION_PRIMARY}"
export LOCATION_SECONDARY="${LOCATION_SECONDARY}"
export AKS_PRIMARY="${AKS_PRIMARY}"
export AKS_SECONDARY="${AKS_SECONDARY}"
export STORAGE_ACCOUNT="${STORAGE_ACCOUNT}"
export CONTAINER_NAME="${CONTAINER_NAME}"
export VNET_PRIMARY="${VNET_PRIMARY}"
export VNET_SECONDARY="${VNET_SECONDARY}"
export SUBNET_PE_PRIMARY="${SUBNET_PE_PRIMARY}"
export SUBNET_PE_SECONDARY="${SUBNET_PE_SECONDARY}"
export PE_PRIMARY="${PE_PRIMARY}"
export PE_SECONDARY="${PE_SECONDARY}"
EOF

echo "Variables saved to /tmp/grs-demo-vars.sh"
