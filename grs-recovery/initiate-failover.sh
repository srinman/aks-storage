#!/bin/bash
set -e

# Load variables
source /tmp/grs-demo-vars.sh

echo "=================================================="
echo "Initiating GRS Failover"
echo "=================================================="
echo ""

# Step 1: Check current replication status
echo "Step 1: Checking storage account replication status..."
az storage account show \
  --name "${STORAGE_ACCOUNT}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query '{name:name, sku:sku.name, primaryLocation:primaryLocation, secondaryLocation:secondaryLocation, statusOfPrimary:statusOfPrimary, statusOfSecondary:statusOfSecondary}' \
  --output table

echo ""
echo "Step 2: Checking replication status..."
echo ""
echo "NOTE: Standard_GRS does not expose Last Sync Time via API."
echo "      Only RA-GRS (Read-Access GRS) accounts expose this metric."
echo ""
echo "For Standard_GRS:"
echo "  - Data is replicated asynchronously to secondary region"
echo "  - Typical RPO: 15 minutes (can be longer)"
echo "  - Recommendation: Wait at least 15 minutes after last write before failover"
echo ""

# Calculate time since deployment
if [ -f /tmp/grs-demo-deployment-time ]; then
  DEPLOY_TIME=$(cat /tmp/grs-demo-deployment-time)
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - DEPLOY_TIME))
  ELAPSED_MIN=$((ELAPSED / 60))
  echo "Time since primary deployment: ${ELAPSED_MIN} minutes"
  
  if [ $ELAPSED_MIN -lt 15 ]; then
    echo "⚠️  WARNING: Less than 15 minutes have passed. GRS replication may not be complete."
    echo "   Recommended: Wait $((15 - ELAPSED_MIN)) more minutes before failover."
    echo ""
  else
    echo "✓ More than 15 minutes have passed. GRS replication should be complete."
    echo ""
  fi
else
  echo "⚠️  WARNING: Cannot determine deployment time."
  echo "   Recommended: Verify at least 15 minutes have passed since last write."
  echo ""
fi

# Step 3: Prompt for confirmation
read -p "Do you want to proceed with failover to ${LOCATION_SECONDARY}? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Failover cancelled."
    exit 0
fi

# Step 4: Initiate failover
echo ""
echo "Step 3: Initiating customer-controlled failover to ${LOCATION_SECONDARY}..."
echo "This process typically takes 1-2 hours to complete."
echo ""

az storage account failover \
  --name "${STORAGE_ACCOUNT}" \
  --resource-group "${RESOURCE_GROUP}" \
  --no-wait

echo ""
echo "Failover initiated. You can check the status with:"
echo ""
echo "  az storage account show \\"
echo "    --name ${STORAGE_ACCOUNT} \\"
echo "    --resource-group ${RESOURCE_GROUP} \\"
echo "    --query '{primaryLocation:primaryLocation, secondaryLocation:secondaryLocation, statusOfPrimary:statusOfPrimary}'"
echo ""

# Step 5: Monitor failover progress
echo ""
echo "Step 4: Monitoring failover progress..."
echo "This will check status every 60 seconds. Press Ctrl+C to stop monitoring."
echo ""

FAILOVER_COMPLETE=false
CHECK_COUNT=0

while [ "$FAILOVER_COMPLETE" = false ]; do
    CHECK_COUNT=$((CHECK_COUNT + 1))
    echo "Check #${CHECK_COUNT} at $(date)"
    
    PRIMARY_LOC=$(az storage account show \
      --name "${STORAGE_ACCOUNT}" \
      --resource-group "${RESOURCE_GROUP}" \
      --query 'primaryLocation' \
      --output tsv)
    
    STATUS=$(az storage account show \
      --name "${STORAGE_ACCOUNT}" \
      --resource-group "${RESOURCE_GROUP}" \
      --query 'statusOfPrimary' \
      --output tsv 2>/dev/null || echo "checking")
    
    echo "  Primary Location: ${PRIMARY_LOC}"
    echo "  Status: ${STATUS}"
    
    if [ "${PRIMARY_LOC}" = "${LOCATION_SECONDARY}" ] && [ "${STATUS}" = "available" ]; then
        FAILOVER_COMPLETE=true
        echo ""
        echo "✓ Failover completed successfully!"
        break
    fi
    
    echo "  Waiting... (check again in 60 seconds)"
    echo ""
    sleep 60
done

echo ""
echo "=================================================="
echo "Failover Complete!"
echo "=================================================="
echo ""
echo "Storage account is now primary in: ${LOCATION_SECONDARY}"
echo ""
echo "NOTE: After failover, the account is temporarily LRS."
echo "      To enable geo-redundancy again, update to GRS/GZRS."
echo ""
echo "Next: Run deploy-secondary-workload.sh to read data from the secondary cluster"
echo ""

# Update storage account type to LRS in vars (it's now LRS after failover)
cat >> /tmp/grs-demo-vars.sh <<EOF
export FAILOVER_COMPLETED="true"
export NEW_PRIMARY_LOCATION="${LOCATION_SECONDARY}"
EOF
