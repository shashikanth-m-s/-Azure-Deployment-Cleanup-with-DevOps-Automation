param(
  [Parameter(Mandatory=$true)]
  [int]$NumberOfDeploymentsToKeep,
  
  [Parameter(Mandatory=$true)]
  [string[]]$SubscriptionIds  # Array of subscription IDs to target
)

# Set TLS 1.2 as the security protocol
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Iterate through the specified subscriptions
foreach ($subscriptionId in $SubscriptionIds) {
  try {
    Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop
    $subscription = Get-AzContext
    Write-Host "Current Subscription: $($subscription.Subscription.Id)"
  } catch {
    Write-Error "Error setting or getting subscription '$subscriptionId': $($_.Exception.Message)"
    continue
  }

  # Hash table to store resource groups with lock details
  $resourceGroupsWithLocks = @{}

  # Get all resource groups
  try {
    $rgs = Get-AzResourceGroup
    Write-Host "Resource Groups:"
    $rgs | ForEach-Object { Write-Host $_.ResourceGroupName }  # List resource group names
  } catch {
    Write-Error "Error getting resource groups: $($_.Exception.Message)"
    continue  # Move to the next subscription if resource groups cannot be retrieved
  }

  # Iterate through resource groups
  foreach ($rg in $rgs) {
    $rgname = $rg.ResourceGroupName

    # Store retrieved locks for this resource group (using logic you provided)
    $existingLocks = Get-AzResourceLock -ResourceGroupName $rgname
    $lockDetails = @{}  # Create an empty hash table to store lock details

    if ($existingLocks) {
      foreach ($lock in $existingLocks) {
        $lockDetails[$lock.Name] = $lock.Properties.Level  # Store lock name as key, level as value
      }
      $resourceGroupsWithLocks[$rgname] = $lockDetails  # Add lock details to hash table with resource group as key
    }

    # Remove lock on resource group if it exists
    try {
      if ($existingLocks) {
        $existingLocks | ForEach-Object {
          Remove-AzResourceLock -ResourceId $_.ResourceId -Force -Confirm:$false
          Write-Host "    Removed lock: $($_.Name)"
        }
      }
     Start-Sleep -Seconds 3
    } catch {
      Write-Error "Error removing lock from resource group '$($rgname)': $($_.Exception.Message)"
      continue
    }

    # Get all deployments in resource group
    try {
      $deployments = Get-AzResourceGroupDeployment -ResourceGroupName $rgname
    } catch {
      Write-Error "Error getting deployments for resource group '$($rgname)': $($_.Exception.Message)"
      continue
    }

    # Sort the deployments by timestamp in descending order
    $deployments = $deployments | Sort-Object -Property Timestamp -Descending

    # Keep the specified number of deployments and delete the rest
    for ($i = $NumberOfDeploymentsToKeep; $i -lt $deployments.Count; $i++) {
      # Delete deployment
      try {
        Remove-AzResourceGroupDeployment -ResourceGroupName $rgname -Name $deployments[$i].DeploymentName -Confirm:$false
        Write-Host "    Deleted deployment: $($deployments[$i].DeploymentName)"
      } catch {
        Write-Error "Error deleting deployment '$($deployments[$i].DeploymentName)' in resource group '$($rgname)': $($_.Exception.Message)"
      }
    }

    # Re-enable locks if previously existed for this resource group
    if ($resourceGroupsWithLocks.ContainsKey($rgname)) {
      Write-Host "  Re-enabling locks on resource group: $rgname"
      $locksToEnable = $resourceGroupsWithLocks[$rgname]
      foreach ($lockName in $locksToEnable.Keys) {
        $lockLevel = $locksToEnable[$lockName]
        try {
          New-AzResourceLock -LockName $lockName -LockLevel $lockLevel -ResourceGroupName $rgname -Force -Confirm:$false
          Write-Host "    Re-enabled lock: $lockName"
        } catch {
          Write-Error "Error re-enabling lock '$lockName' on resource group '$($rgname)': $($_.Exception.Message)"
        }
      }
    }
  }
}

Write-Host "Script completed."
