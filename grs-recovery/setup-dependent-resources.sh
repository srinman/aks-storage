#!/bin/bash
set -e

# Setup Dependent Resources (Storage, Private Endpoints, DNS)
# This can be deleted and recreated quickly for testing

# Load base variables
if [ -f /tmp/grs-demo-base-vars.sh ]; then
  source /tmp/grs-demo-base-vars.sh
else
  echo "ERROR: Base variables not found. Run setup-clusters.sh first."
  exit 1
fi

# Storage Configuration
STORAGE_ACCOUNT="stgrsdemo$(date +%s | tail -c 10)"
CONTAINER_NAME="democontainer"

# Private Endpoint names
PE_PRIMARY="pe-blob-${LOCATION_PRIMARY}"
PE_SECONDARY="pe-blob-${LOCATION_SECONDARY}"

echo "=================================================="
echo "GRS Demo - Dependent Resources Setup"
echo "=================================================="
echo ""
echo "This script creates:"
echo "  - GRS Storage Account"
echo "  - Blob Container"
echo "  - Private DNS Zone"
echo "  - Private Endpoints (both regions)"
echo ""
echo "Duration: ~5-10 minutes"
echo ""

# Step 1: Create GRS Storage Account
echo "Step 1: Creating GRS storage account..."

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
echo "      After workload identity is configured, you can disable it for enhanced security."

# Step 2: Create Container
echo ""
echo "Step 2: Creating container using Azure AD authentication..."

STORAGE_ID=$(az storage account show \
  --name "${STORAGE_ACCOUNT}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query id -o tsv)

# Assign role to current user for container creation
CURRENT_USER=$(az account show --query user.name -o tsv)
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee "${CURRENT_USER}" \
  --scope "${STORAGE_ID}" \
  --output none 2>/dev/null || true

# Wait for RBAC propagation
sleep 10

az storage container create \
  --name "${CONTAINER_NAME}" \
  --account-name "${STORAGE_ACCOUNT}" \
  --auth-mode login

# Step 3: Create Private DNS Zone
echo ""
echo "Step 3: Creating Private DNS Zone..."

az network private-dns zone create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "privatelink.blob.core.windows.net"

# Step 4: Link DNS zone to both VNets
echo ""
echo "Step 4: Linking DNS zone to VNets..."

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

# Step 5: Create Private Endpoint in Primary Region ONLY
echo ""
echo "Step 5: Creating private endpoint in ${LOCATION_PRIMARY}..."
echo "NOTE: Secondary region private endpoint will be created AFTER failover"
echo "      to avoid DNS conflicts (last PE created overwrites DNS record)."

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

# Get the private endpoint IP for reference
PE_IP_PRIMARY=$(az network private-endpoint show \
  --name "${PE_PRIMARY}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query 'customDnsConfigs[0].ipAddresses[0]' -o tsv 2>/dev/null || \
  az network nic show --ids $(az network private-endpoint show \
    --name "${PE_PRIMARY}" \
    --resource-group "${RESOURCE_GROUP}" \
    --query 'networkInterfaces[0].id' -o tsv) \
  --query 'ipConfigurations[0].privateIPAddress' -o tsv)

echo "Primary private endpoint IP: ${PE_IP_PRIMARY}"

# Step 6: Create Managed Identities for blob access
echo ""
echo "Step 6: Creating managed identities for storage access..."

IDENTITY_PRIMARY="id-blob-${LOCATION_PRIMARY}"
IDENTITY_SECONDARY="id-blob-${LOCATION_SECONDARY}"

# Create managed identity for primary region
az identity create \
  --name "${IDENTITY_PRIMARY}" \
  --resource-group "${RESOURCE_GROUP}" \
  --location "${LOCATION_PRIMARY}"

IDENTITY_CLIENT_ID_PRIMARY=$(az identity show \
  --name "${IDENTITY_PRIMARY}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query clientId -o tsv)

IDENTITY_PRINCIPAL_ID_PRIMARY=$(az identity show \
  --name "${IDENTITY_PRIMARY}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query principalId -o tsv)

echo "Created identity: ${IDENTITY_PRIMARY}"
echo "  Client ID: ${IDENTITY_CLIENT_ID_PRIMARY}"

# Create managed identity for secondary region
az identity create \
  --name "${IDENTITY_SECONDARY}" \
  --resource-group "${RESOURCE_GROUP}" \
  --location "${LOCATION_SECONDARY}"

IDENTITY_CLIENT_ID_SECONDARY=$(az identity show \
  --name "${IDENTITY_SECONDARY}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query clientId -o tsv)

IDENTITY_PRINCIPAL_ID_SECONDARY=$(az identity show \
  --name "${IDENTITY_SECONDARY}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query principalId -o tsv)

echo "Created identity: ${IDENTITY_SECONDARY}"
echo "  Client ID: ${IDENTITY_CLIENT_ID_SECONDARY}"

# Step 7: Assign Storage Blob Data Contributor role to managed identities
echo ""
echo "Step 7: Assigning Storage Blob Data Contributor role to identities..."

az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee-object-id "${IDENTITY_PRINCIPAL_ID_PRIMARY}" \
  --assignee-principal-type ServicePrincipal \
  --scope "${STORAGE_ID}" \
  --output none

echo "Role assigned to ${IDENTITY_PRIMARY}"

az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee-object-id "${IDENTITY_PRINCIPAL_ID_SECONDARY}" \
  --assignee-principal-type ServicePrincipal \
  --scope "${STORAGE_ID}" \
  --output none

echo "Role assigned to ${IDENTITY_SECONDARY}"

# Wait for RBAC propagation
echo "Waiting 30 seconds for RBAC propagation..."
sleep 30

# Step 8: Assign managed identities to AKS node pool VMSS
echo ""
echo "Step 8: Assigning managed identities to AKS node pool VMSS..."

# Get the node resource group and VMSS name for primary cluster
NODE_RG_PRIMARY=$(az aks show \
  --name "${AKS_PRIMARY}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query nodeResourceGroup -o tsv)

VMSS_NAME_PRIMARY=$(az vmss list \
  --resource-group "${NODE_RG_PRIMARY}" \
  --query '[0].name' -o tsv)

echo "Primary cluster VMSS: ${VMSS_NAME_PRIMARY}"

# Get the managed identity resource ID
IDENTITY_ID_PRIMARY=$(az identity show \
  --name "${IDENTITY_PRIMARY}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query id -o tsv)

# Assign identity to VMSS
az vmss identity assign \
  --resource-group "${NODE_RG_PRIMARY}" \
  --name "${VMSS_NAME_PRIMARY}" \
  --identities "${IDENTITY_ID_PRIMARY}"

echo "Assigned ${IDENTITY_PRIMARY} to ${VMSS_NAME_PRIMARY}"

# Get the node resource group and VMSS name for secondary cluster
NODE_RG_SECONDARY=$(az aks show \
  --name "${AKS_SECONDARY}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query nodeResourceGroup -o tsv)

VMSS_NAME_SECONDARY=$(az vmss list \
  --resource-group "${NODE_RG_SECONDARY}" \
  --query '[0].name' -o tsv)

echo "Secondary cluster VMSS: ${VMSS_NAME_SECONDARY}"

# Get the managed identity resource ID
IDENTITY_ID_SECONDARY=$(az identity show \
  --name "${IDENTITY_SECONDARY}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query id -o tsv)

# Assign identity to VMSS
az vmss identity assign \
  --resource-group "${NODE_RG_SECONDARY}" \
  --name "${VMSS_NAME_SECONDARY}" \
  --identities "${IDENTITY_ID_SECONDARY}"

echo "Assigned ${IDENTITY_SECONDARY} to ${VMSS_NAME_SECONDARY}"

# Update VMSS instances to apply the identity
echo ""
echo "Updating VMSS instances to apply managed identity..."
echo "This may take a few minutes..."

az vmss update-instances \
  --resource-group "${NODE_RG_PRIMARY}" \
  --name "${VMSS_NAME_PRIMARY}" \
  --instance-ids '*'

echo "Primary VMSS instances updated"

az vmss update-instances \
  --resource-group "${NODE_RG_SECONDARY}" \
  --name "${VMSS_NAME_SECONDARY}" \
  --instance-ids '*'

echo "Secondary VMSS instances updated"

# Wait for instances to update
echo "Waiting 30 seconds for VMSS updates to complete..."
sleep 30

echo ""
echo "Private Endpoint Configuration:"
echo "-------------------------------"
echo "PRIMARY region (${LOCATION_PRIMARY}):"
echo "  - Private endpoint created: ${PE_PRIMARY}"
echo "  - IP Address: ${PE_IP_PRIMARY}"
echo "  - DNS record created in privatelink.blob.core.windows.net"
echo ""
echo "SECONDARY region (${LOCATION_SECONDARY}):"
echo "  - Private endpoint NOT created yet (avoids DNS conflicts)"
echo "  - Will be created AFTER failover in deploy-secondary-workload.sh"
echo ""
echo "Why? The last PE created overwrites the DNS A record. We want the"
echo "primary IP active during normal operations."

echo ""
echo "=================================================="
echo "Dependent resources setup complete!"
echo "=================================================="
echo ""
echo "Summary:"
echo "--------"
echo "Storage Account: ${STORAGE_ACCOUNT} (GRS)"
echo "Container: ${CONTAINER_NAME}"
echo "Managed Identities:"
echo "  Primary: ${IDENTITY_PRIMARY}"
echo "    Client ID: ${IDENTITY_CLIENT_ID_PRIMARY}"
echo "  Secondary: ${IDENTITY_SECONDARY}"
echo "    Client ID: ${IDENTITY_CLIENT_ID_SECONDARY}"
echo "Private Endpoints:"
echo "  Primary: ${PE_PRIMARY} (${LOCATION_PRIMARY}) - IP: ${PE_IP_PRIMARY}"
echo "  Secondary: NOT created yet (will be created after failover)"
echo "Private DNS Zone: privatelink.blob.core.windows.net"
echo ""
echo "Next: Run deploy-primary-workload.sh"
echo ""

# Save all variables
cat > /tmp/grs-demo-vars.sh <<EOF
# Base variables
export RESOURCE_GROUP="${RESOURCE_GROUP}"
export LOCATION_PRIMARY="${LOCATION_PRIMARY}"
export LOCATION_SECONDARY="${LOCATION_SECONDARY}"
export AKS_PRIMARY="${AKS_PRIMARY}"
export AKS_SECONDARY="${AKS_SECONDARY}"
export VNET_PRIMARY="${VNET_PRIMARY}"
export VNET_SECONDARY="${VNET_SECONDARY}"
export SUBNET_PE_PRIMARY="${SUBNET_PE_PRIMARY}"
export SUBNET_PE_SECONDARY="${SUBNET_PE_SECONDARY}"

# Dependent resource variables
export STORAGE_ACCOUNT="${STORAGE_ACCOUNT}"
export CONTAINER_NAME="${CONTAINER_NAME}"
export PE_PRIMARY="${PE_PRIMARY}"
export PE_SECONDARY="${PE_SECONDARY}"
export PE_IP_PRIMARY="${PE_IP_PRIMARY}"

# Managed Identity variables
export IDENTITY_PRIMARY="${IDENTITY_PRIMARY}"
export IDENTITY_SECONDARY="${IDENTITY_SECONDARY}"
export IDENTITY_CLIENT_ID_PRIMARY="${IDENTITY_CLIENT_ID_PRIMARY}"
export IDENTITY_CLIENT_ID_SECONDARY="${IDENTITY_CLIENT_ID_SECONDARY}"
export IDENTITY_PRINCIPAL_ID_PRIMARY="${IDENTITY_PRINCIPAL_ID_PRIMARY}"
export IDENTITY_PRINCIPAL_ID_SECONDARY="${IDENTITY_PRINCIPAL_ID_SECONDARY}"
EOF

echo "Variables saved to /tmp/grs-demo-vars.sh"
