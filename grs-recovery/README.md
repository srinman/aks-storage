# GRS Storage Failover Demo with AKS

This demo demonstrates Azure GRS (Geo-Redundant Storage) failover capabilities using AKS clusters in two regions with the Blob CSI driver and Managed Service Identity (MSI).

## Overview

This demo will:
1. Create VNets and subnets (AKS and Private Endpoint subnets) in two Azure regions (Central US and East US 2)
2. Deploy AKS clusters with Blob CSI driver enabled in both regions
3. Create a GRS storage account in Central US
4. **Create user-assigned managed identities and assign Storage Blob Data Contributor role**
5. **Create private endpoint for blob storage in primary region (Central US)**
6. **Configure Private DNS zone and link to both VNets**
7. **Associate managed identities with AKS node pools (VMSS)**
8. Mount the blob storage using CSI driver with MSI authentication in the primary cluster (Central US)
9. Write sample content to the blob storage
10. Wait for GRS replication (recommended 15 minutes)
11. Initiate a customer-controlled GRS failover to East US 2
12. **Create private endpoint for blob storage in secondary region (East US 2)**
13. Mount the same storage in the secondary cluster (East US 2) via its local private endpoint
14. Read and verify the content survived the failover

### Why Private Endpoints in Both Regions?

**Disaster Recovery Scenario:** When the primary site (Central US) is down, the secondary AKS cluster cannot reach the primary VNet or its private endpoint. Therefore, each region needs its own private endpoint.

**Key Design Principles:**
- Primary cluster uses the private endpoint in its VNet (Central US)
- Secondary cluster uses the private endpoint in its VNet (East US 2)
- Both private endpoints connect to the same storage account
- Private DNS zone is linked to both VNets for automatic resolution
- After GRS failover, private endpoints automatically connect to the new primary storage location
- **No DNS reconfiguration needed after failover** (per Microsoft guidance)

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Azure Subscription                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  ┌────────────── Central US (Primary) ────────┐                     │
│  │  VNet: 10.1.0.0/16                         │                     │
│  │  ┌─────────────────────────────────────┐   │                     │
│  │  │ AKS Subnet: 10.1.0.0/22             │   │                     │
│  │  │  ┌─────────────────────────────┐    │   │                     │
│  │  │  │ AKS Cluster (Primary)       │────┼───┼──┐                  │
│  │  │  │ - Blob CSI Driver           │    │   │  │                  │
│  │  │  │ - MSI Authentication        │    │   │  │                  │
│  │  │  └─────────────────────────────┘    │   │  │                  │
│  │  └─────────────────────────────────────┘   │  │                  │
│  │  ┌─────────────────────────────────────┐   │  │                  │
│  │  │ PE Subnet: 10.1.4.0/24              │   │  │                  │
│  │  │  ┌──────────────────────────────┐   │   │  │                  │
│  │  │  │ Private Endpoint (Primary)   │◄──┼───┼──┘                  │
│  │  │  │ - IP: 10.1.4.x               │   │   │                     │
│  │  │  └──────────────┬───────────────┘   │   │                     │
│  │  └─────────────────┼───────────────────┘   │                     │
│  │                    │                        │                     │
│  │  ┌─────────────────▼───────────────────┐   │                     │
│  │  │ Private DNS Zone                    │   │                     │
│  │  │ privatelink.blob.core.windows.net   │───┼──┐                  │
│  │  └─────────────────────────────────────┘   │  │                  │
│  └──────────────────────────────────────────────┘  │                  │
│                           │                         │                  │
│                           │ Linked to both VNets    │                  │
│                           │                         │                  │
│              ┌────────────▼───────────┐             │                  │
│              │ GRS Storage Account    │◄────────────┘                  │
│              │ - Primary: Central US  │                                │
│              │ - Secondary: East US 2 │                                │
│              │ - Auto Replication ───────┐                             │
│              └────────────────────────────┘│                            │
│                                            │                            │
│  ┌────────────── East US 2 (Secondary) ────▼────┐                     │
│  │  VNet: 10.2.0.0/16                           │                     │
│  │  ┌──────────────────────────────────────┐    │                     │
│  │  │ AKS Subnet: 10.2.0.0/22              │    │                     │
│  │  │  ┌─────────────────────────────┐     │    │                     │
│  │  │  │ AKS Cluster (Secondary)     │─────┼────┼──┐                  │
│  │  │  │ - Blob CSI Driver           │     │    │  │                  │
│  │  │  │ - MSI Authentication        │     │    │  │                  │
│  │  │  └─────────────────────────────┘     │    │  │                  │
│  │  └──────────────────────────────────────┘    │  │                  │
│  │  ┌──────────────────────────────────────┐    │  │                  │
│  │  │ PE Subnet: 10.2.4.0/24               │    │  │                  │
│  │  │  ┌──────────────────────────────┐    │    │  │                  │
│  │  │  │ Private Endpoint (Secondary) │◄───┼────┼──┘                  │
│  │  │  │ - IP: 10.2.4.x               │    │    │                     │
│  │  │  │ - Used after failover        │    │    │                     │
│  │  │  └──────────────────────────────┘    │    │                     │
│  │  └──────────────────────────────────────┘    │                     │
│  └───────────────────────────────────────────────┘                     │
│                                                                         │
│  Flow during normal operations:                                        │
│    Primary AKS → PE Primary → Storage (Central US)                    │
│                                                                         │
│  Flow after failover (Primary site down):                             │
│    Secondary AKS → PE Secondary → Storage (now primary in East US 2)  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Azure CLI installed and authenticated (`az login`)
- kubectl installed
- Bash shell (Linux/macOS/WSL)
- Azure subscription with permissions to:
  - Create resource groups
  - Create VNets and subnets
  - Create AKS clusters
  - Create storage accounts
  - Create managed identities
  - Assign RBAC roles

## Setup Instructions

### Step 1: Create AKS Clusters

Create the AKS clusters and network infrastructure (one-time setup).

```bash
cd /home/srinman/git/aks-storage/grs-recovery
chmod +x *.sh
./setup-clusters.sh
```

**What this does:**
- Creates a resource group
- Creates VNets with AKS and Private Endpoint subnets in both regions
- Deploys AKS clusters with Blob CSI driver enabled

**Duration:** ~15-20 minutes

### Step 2: Setup Dependent Resources

Create storage, private endpoints, managed identities, and configure VMSS identity associations.

```bash
./setup-dependent-resources.sh
```

**What this does:**
- Creates GRS storage account and container
- Creates private endpoint for blob storage in primary region (Central US)
- Creates and configures Private DNS zone
- Links DNS zone to both VNets
- Creates user-assigned managed identities for both clusters (id-blob-centralus, id-blob-eastus2)
- Grants Storage Blob Data Contributor role to both identities
- Associates managed identities with AKS node pool VMSS in both regions
- Updates VMSS instances to apply the identity changes

**Duration:** ~10-15 minutes

### Step 3: Deploy Workload in Primary Cluster

This script deploys a pod in the Central US cluster that writes data to the blob storage using MSI authentication.

```bash
./deploy-primary-workload-new.sh
```

**What this does:**
- Switches to the primary cluster context
- Creates namespace (blob-demo)
- Creates StorageClass with MSI authentication (AzureStorageAuthType: MSI)
- Creates PersistentVolume with managed identity client ID
- Creates PersistentVolumeClaim using the Blob CSI driver
- Deploys a writer pod (blob-writer) that continuously writes data
- Writes sample content with timestamp to /mnt/blob/data.txt
- Saves deployment timestamp for failover timing reference

**Duration:** ~1-2 minutes

### Step 4: Initiate GRS Failover

Wait at least 15 minutes after deploying the primary workload to allow GRS replication, then initiate a customer-controlled failover to the East US 2 region.

```bash
./initiate-failover.sh
```

**What this does:**
- Checks the current replication status
- Shows deployment time and recommends waiting 15 minutes for replication
- **Note:** Standard_GRS doesn't expose Last Sync Time (only RA-GRS does)
- Prompts for confirmation
- Initiates the failover to East US 2
- Monitors the failover progress

**Duration:** ~1-2 hours (Azure-controlled process)

**Important Notes:**
- **Wait at least 15 minutes after writing data** before initiating failover to ensure GRS replication
- This is a real failover operation and will:
  - Make East US 2 the new primary region
  - Convert the storage account temporarily to LRS (Locally Redundant Storage)
  - Require manual reconfiguration to enable geo-redundancy again
- The storage account will be unavailable during failover

**Monitor failover status manually:**
```bash
source /tmp/grs-demo-vars.sh
az storage account show \
  --name "${STORAGE_ACCOUNT}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query '{primaryLocation:primaryLocation, statusOfPrimary:statusOfPrimary}'
```

### Step 5: Deploy Workload in Secondary Cluster

After the failover completes, deploy a reader pod in the East US 2 cluster.

```bash
./deploy-secondary-workload-new.sh
```

**What this does:**
- Creates private endpoint for blob storage in secondary region (East US 2)
- Switches to the secondary cluster context
- Creates namespace (blob-demo)
- Creates StorageClass with MSI authentication using secondary managed identity
- Creates PersistentVolume with secondary managed identity client ID
- Creates PersistentVolumeClaim pointing to the now-primary storage
- Deploys a reader pod (blob-reader) using the netshoot image
- Reads and displays the content written in the primary cluster
- Writes a verification message
- Outputs the complete demo results

**Duration:** ~1-2 minutes

**Verify the data:**
```bash
kubectl config use-context aks-secondary
kubectl logs -n blob-demo blob-reader
kubectl exec -it -n blob-demo blob-reader -- cat /mnt/blob/data.txt
```

## Cleanup

To delete all resources:

```bash
./cleanup.sh
```

This will delete the resource group and all resources.

---

## Key Concepts Demonstrated

### 1. GRS Storage
- **Geo-Redundant Storage** automatically replicates data to a secondary region
- Provides durability against regional disasters
- RPO (Recovery Point Objective): typically < 15 minutes
- RTO (Recovery Time Objective): 1-2 hours for customer-initiated failover

### 2. Managed Service Identity (MSI)
- Authentication method using user-assigned managed identities
- Identities are associated with AKS node pool VMSS
- Pods use MSI to authenticate to Azure services
- No secrets or keys needed in StorageClass or PV definitions
- Storage Blob Data Contributor role provides read/write access

### 3. Blob CSI Driver
- Kubernetes Container Storage Interface (CSI) driver for Azure Blob
- Mounts blob containers as volumes in pods
- Supports both read and write operations
- Works with FUSE protocol (blobfuse2) for filesystem-like access
- **Supports MSI authentication with AzureStorageAuthType: MSI**
- **Uses AzureStorageIdentityClientID for user-assigned managed identity**
- **Uses private endpoints for secure, network-isolated connectivity**

### 4. Customer-Controlled Failover
- Allows manual initiation of failover to secondary region
- Used for disaster recovery scenarios
- Tests business continuity plans
- Account becomes LRS after failover (requires manual re-enable of geo-redundancy)

### 5. Private Endpoints for Disaster Recovery
- **Each region has its own private endpoint in its VNet**
- Private DNS zone linked to both VNets for seamless resolution
- Primary cluster uses primary region's private endpoint
- Secondary cluster uses secondary region's private endpoint
- **After failover, private endpoints automatically connect to new primary** (no DNS changes needed)
- Provides network isolation and security
- Eliminates exposure to public internet
- Critical for DR: Secondary cluster can access storage even when primary site is down

## References

- [Azure GRS Storage](https://learn.microsoft.com/azure/storage/common/storage-redundancy)
- [Azure Blob CSI Driver](https://github.com/kubernetes-sigs/blob-csi-driver)
- [CSI driver with Managed Identity](https://github.com/kubernetes-sigs/blob-csi-driver/tree/master/deploy/example/blobfuse-mi#mount-azure-blob-storage-with-managed-identity)
- [Customer-managed failover](https://learn.microsoft.com/azure/storage/common/storage-initiate-account-failover)
- [Private Endpoints for Azure Storage](https://learn.microsoft.com/azure/storage/common/storage-private-endpoints)
- [Private Endpoint DNS Configuration](https://learn.microsoft.com/azure/private-link/private-endpoint-dns)
- [Azure Managed Identities](https://learn.microsoft.com/azure/active-directory/managed-identities-azure-resources/overview)
## License

This demo is provided as-is for educational purposes.
