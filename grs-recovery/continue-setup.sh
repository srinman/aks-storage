#!/bin/bash
set -e

# Continue setup from where it broke
echo "=================================================="
echo "Continuing GRS Demo Setup"
echo "=================================================="
echo ""

# Set variables (update these if different)
RESOURCE_GROUP="rg-aks-grs-demo"
LOCATION_PRIMARY="centralus"
LOCATION_SECONDARY="eastus2"

# Get existing resources
echo "Step 1: Discovering existing resources..."

# Find storage account
STORAGE_ACCOUNT=$(az storage account list \
  --resource-group "${RESOURCE_GROUP}" \
  --query '[0].name' -o tsv)

if [ -z "$STORAGE_ACCOUNT" ]; then
  echo "ERROR: No storage account found. Please check resource group."
  exit 1
fi

echo "Found storage account: ${STORAGE_ACCOUNT}"

# Find AKS clusters
AKS_PRIMARY=$(az aks list \
  --resource-group "${RESOURCE_GROUP}" \
  --query "[?location=='${LOCATION_PRIMARY}'].name" -o tsv)

AKS_SECONDARY=$(az aks list \
  --resource-group "${RESOURCE_GROUP}" \
  --query "[?location=='${LOCATION_SECONDARY}'].name" -o tsv)

echo "Found AKS clusters:"
echo "  Primary: ${AKS_PRIMARY}"
echo "  Secondary: ${AKS_SECONDARY}"

# Find VNets
VNET_PRIMARY=$(az network vnet list \
  --resource-group "${RESOURCE_GROUP}" \
  --query "[?location=='${LOCATION_PRIMARY}'].name" -o tsv)

VNET_SECONDARY=$(az network vnet list \
  --resource-group "${RESOURCE_GROUP}" \
  --query "[?location=='${LOCATION_SECONDARY}'].name" -o tsv)

echo "Found VNets:"
echo "  Primary: ${VNET_PRIMARY}"
echo "  Secondary: ${VNET_SECONDARY}"

# Set derived variables
CONTAINER_NAME="democontainer"
SUBNET_PE_PRIMARY="subnet-pe-${LOCATION_PRIMARY}"
SUBNET_PE_SECONDARY="subnet-pe-${LOCATION_SECONDARY}"
PE_PRIMARY="pe-blob-${LOCATION_PRIMARY}"
PE_SECONDARY="pe-blob-${LOCATION_SECONDARY}"

# Step 2: Create container if it doesn't exist
echo ""
echo "Step 2: Creating container (if not exists)..."

CURRENT_USER=$(az account show --query user.name -o tsv)
STORAGE_ID=$(az storage account show \
  --name "${STORAGE_ACCOUNT}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query id -o tsv)

# Assign role to current user
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee "${CURRENT_USER}" \
  --scope "${STORAGE_ID}" \
  --output none 2>/dev/null || echo "Role already assigned"

sleep 5

# Check if container exists
CONTAINER_EXISTS=$(az storage container exists \
  --name "${CONTAINER_NAME}" \
  --account-name "${STORAGE_ACCOUNT}" \
  --auth-mode login \
  --query exists -o tsv 2>/dev/null || echo "false")

if [ "$CONTAINER_EXISTS" = "true" ]; then
  echo "Container already exists: ${CONTAINER_NAME}"
else
  echo "Creating container: ${CONTAINER_NAME}"
  az storage container create \
    --name "${CONTAINER_NAME}" \
    --account-name "${STORAGE_ACCOUNT}" \
    --auth-mode login
fi

# Step 3: Create Private DNS Zone if not exists
echo ""
echo "Step 3: Creating Private DNS Zone (if not exists)..."

DNS_ZONE_EXISTS=$(az network private-dns zone show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "privatelink.blob.core.windows.net" \
  --query id -o tsv 2>/dev/null || echo "")

if [ -n "$DNS_ZONE_EXISTS" ]; then
  echo "Private DNS zone already exists"
else
  echo "Creating Private DNS zone..."
  az network private-dns zone create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "privatelink.blob.core.windows.net"
fi

# Step 4: Link DNS zone to VNets
echo ""
echo "Step 4: Linking DNS zone to VNets..."

# Check primary link
PRIMARY_LINK=$(az network private-dns link vnet show \
  --resource-group "${RESOURCE_GROUP}" \
  --zone-name "privatelink.blob.core.windows.net" \
  --name "dns-link-primary" \
  --query id -o tsv 2>/dev/null || echo "")

if [ -n "$PRIMARY_LINK" ]; then
  echo "Primary VNet already linked"
else
  echo "Linking primary VNet..."
  az network private-dns link vnet create \
    --resource-group "${RESOURCE_GROUP}" \
    --zone-name "privatelink.blob.core.windows.net" \
    --name "dns-link-primary" \
    --virtual-network "${VNET_PRIMARY}" \
    --registration-enabled false
fi

# Check secondary link
SECONDARY_LINK=$(az network private-dns link vnet show \
  --resource-group "${RESOURCE_GROUP}" \
  --zone-name "privatelink.blob.core.windows.net" \
  --name "dns-link-secondary" \
  --query id -o tsv 2>/dev/null || echo "")

if [ -n "$SECONDARY_LINK" ]; then
  echo "Secondary VNet already linked"
else
  echo "Linking secondary VNet..."
  az network private-dns link vnet create \
    --resource-group "${RESOURCE_GROUP}" \
    --zone-name "privatelink.blob.core.windows.net" \
    --name "dns-link-secondary" \
    --virtual-network "${VNET_SECONDARY}" \
    --registration-enabled false
fi

# Step 5: Create Private Endpoint in Primary Region
echo ""
echo "Step 5: Creating private endpoint in primary region..."

PE_PRIMARY_EXISTS=$(az network private-endpoint show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${PE_PRIMARY}" \
  --query id -o tsv 2>/dev/null)

if [ -n "$PE_PRIMARY_EXISTS" ]; then
  echo "Primary private endpoint already exists"
else
  echo "Creating primary private endpoint..."
  
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

  # Create DNS zone group
  az network private-endpoint dns-zone-group create \
    --resource-group "${RESOURCE_GROUP}" \
    --endpoint-name "${PE_PRIMARY}" \
    --name "blob-dns-zone-group" \
    --private-dns-zone "privatelink.blob.core.windows.net" \
    --zone-name blob
fi

# Step 6: Create Private Endpoint in Secondary Region
echo ""
echo "Step 6: Creating private endpoint in secondary region..."

PE_SECONDARY_EXISTS=$(az network private-endpoint show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${PE_SECONDARY}" \
  --query id -o tsv 2>/dev/null)

if [ -n "$PE_SECONDARY_EXISTS" ]; then
  echo "Secondary private endpoint already exists"
else
  echo "Creating secondary private endpoint..."
  
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

  # Create DNS zone group
  az network private-endpoint dns-zone-group create \
    --resource-group "${RESOURCE_GROUP}" \
    --endpoint-name "${PE_SECONDARY}" \
    --name "blob-dns-zone-group" \
    --private-dns-zone "privatelink.blob.core.windows.net" \
    --zone-name blob
fi

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
echo "Setup continuation complete!"
echo "=================================================="
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
echo ""
echo "Summary:"
echo "--------"
echo "Resource Group: ${RESOURCE_GROUP}"
echo "Primary AKS: ${AKS_PRIMARY} (${LOCATION_PRIMARY})"
echo "Secondary AKS: ${AKS_SECONDARY} (${LOCATION_SECONDARY})"
echo "Storage Account: ${STORAGE_ACCOUNT} (GRS)"
echo "Container: ${CONTAINER_NAME}"
echo ""
echo "Private Endpoints:"
echo "  Primary PE: ${PE_PRIMARY} in ${LOCATION_PRIMARY}"
echo "  Secondary PE: ${PE_SECONDARY} in ${LOCATION_SECONDARY}"
echo "  DNS Zone: privatelink.blob.core.windows.net (linked to both VNets)"
echo ""
echo "Contexts:"
echo "  Primary: aks-primary"
echo "  Secondary: aks-secondary"
echo ""
echo "Next: Run setup-workload-identity.sh"
echo ""
