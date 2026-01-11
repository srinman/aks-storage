#!/bin/bash
set -e

# Load variables from infrastructure setup
source /tmp/grs-demo-vars.sh

echo "=================================================="
echo "Setting up Workload Identity and Blob CSI Driver"
echo "=================================================="
echo ""

# Step 1: Create Managed Identities for both clusters
echo "Step 1: Creating managed identities..."

IDENTITY_PRIMARY="id-blob-${LOCATION_PRIMARY}"
IDENTITY_SECONDARY="id-blob-${LOCATION_SECONDARY}"

az identity create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${IDENTITY_PRIMARY}" \
  --location "${LOCATION_PRIMARY}"

az identity create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${IDENTITY_SECONDARY}" \
  --location "${LOCATION_SECONDARY}"

# Get identity details
IDENTITY_CLIENT_ID_PRIMARY=$(az identity show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${IDENTITY_PRIMARY}" \
  --query clientId -o tsv)

IDENTITY_CLIENT_ID_SECONDARY=$(az identity show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${IDENTITY_SECONDARY}" \
  --query clientId -o tsv)

IDENTITY_PRINCIPAL_ID_PRIMARY=$(az identity show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${IDENTITY_PRIMARY}" \
  --query principalId -o tsv)

IDENTITY_PRINCIPAL_ID_SECONDARY=$(az identity show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${IDENTITY_SECONDARY}" \
  --query principalId -o tsv)

echo "Primary Identity Client ID: ${IDENTITY_CLIENT_ID_PRIMARY}"
echo "Secondary Identity Client ID: ${IDENTITY_CLIENT_ID_SECONDARY}"

# Step 2: Grant Storage Blob Data Contributor role to identities
echo ""
echo "Step 2: Granting Storage Blob Data Contributor role..."

STORAGE_ID=$(az storage account show \
  --name "${STORAGE_ACCOUNT}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query id -o tsv)

az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee-object-id "${IDENTITY_PRINCIPAL_ID_PRIMARY}" \
  --assignee-principal-type ServicePrincipal \
  --scope "${STORAGE_ID}"

az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee-object-id "${IDENTITY_PRINCIPAL_ID_SECONDARY}" \
  --assignee-principal-type ServicePrincipal \
  --scope "${STORAGE_ID}"

echo "Role assignments created. Waiting 60 seconds for propagation..."
sleep 60

# Step 3: Get OIDC Issuer URLs
echo ""
echo "Step 3: Getting OIDC issuer URLs..."

OIDC_ISSUER_PRIMARY=$(az aks show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${AKS_PRIMARY}" \
  --query oidcIssuerProfile.issuerUrl -o tsv)

OIDC_ISSUER_SECONDARY=$(az aks show \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${AKS_SECONDARY}" \
  --query oidcIssuerProfile.issuerUrl -o tsv)

echo "Primary OIDC Issuer: ${OIDC_ISSUER_PRIMARY}"
echo "Secondary OIDC Issuer: ${OIDC_ISSUER_SECONDARY}"

# Step 4: Create namespace and service account in primary cluster
echo ""
echo "Step 4: Setting up Kubernetes resources in primary cluster..."

kubectl config use-context aks-primary

kubectl create namespace blob-demo --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: blob-sa
  namespace: blob-demo
  annotations:
    azure.workload.identity/client-id: ${IDENTITY_CLIENT_ID_PRIMARY}
EOF

# Step 5: Create federated identity credential for primary
echo ""
echo "Step 5: Creating federated identity credential for primary cluster..."

az identity federated-credential create \
  --name "fed-${AKS_PRIMARY}" \
  --identity-name "${IDENTITY_PRIMARY}" \
  --resource-group "${RESOURCE_GROUP}" \
  --issuer "${OIDC_ISSUER_PRIMARY}" \
  --subject system:serviceaccount:blob-demo:blob-sa

# Step 6: Create namespace and service account in secondary cluster
echo ""
echo "Step 6: Setting up Kubernetes resources in secondary cluster..."

kubectl config use-context aks-secondary

kubectl create namespace blob-demo --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: blob-sa
  namespace: blob-demo
  annotations:
    azure.workload.identity/client-id: ${IDENTITY_CLIENT_ID_SECONDARY}
EOF

# Step 7: Create federated identity credential for secondary
echo ""
echo "Step 7: Creating federated identity credential for secondary cluster..."

az identity federated-credential create \
  --name "fed-${AKS_SECONDARY}" \
  --identity-name "${IDENTITY_SECONDARY}" \
  --resource-group "${RESOURCE_GROUP}" \
  --issuer "${OIDC_ISSUER_SECONDARY}" \
  --subject system:serviceaccount:blob-demo:blob-sa

# Step 8: Verify Blob CSI driver is installed
echo ""
echo "Step 8: Verifying Blob CSI driver installation..."

kubectl config use-context aks-primary
echo "Primary cluster CSI driver pods:"
kubectl get pods -n kube-system -l app=csi-blob-controller

kubectl config use-context aks-secondary
echo ""
echo "Secondary cluster CSI driver pods:"
kubectl get pods -n kube-system -l app=csi-blob-controller

echo ""
echo "=================================================="
echo "Workload Identity setup complete!"
echo "=================================================="
echo ""
echo "Summary:"
echo "--------"
echo "Primary Identity: ${IDENTITY_PRIMARY}"
echo "  Client ID: ${IDENTITY_CLIENT_ID_PRIMARY}"
echo "Secondary Identity: ${IDENTITY_SECONDARY}"
echo "  Client ID: ${IDENTITY_CLIENT_ID_SECONDARY}"
echo ""
echo "Kubernetes namespace: blob-demo"
echo "Service Account: blob-sa"
echo ""
echo "Next: Run deploy-primary-workload.sh"
echo ""

# Save additional variables
cat >> /tmp/grs-demo-vars.sh <<EOF
export IDENTITY_PRIMARY="${IDENTITY_PRIMARY}"
export IDENTITY_SECONDARY="${IDENTITY_SECONDARY}"
export IDENTITY_CLIENT_ID_PRIMARY="${IDENTITY_CLIENT_ID_PRIMARY}"
export IDENTITY_CLIENT_ID_SECONDARY="${IDENTITY_CLIENT_ID_SECONDARY}"
EOF

echo "Variables updated in /tmp/grs-demo-vars.sh"
