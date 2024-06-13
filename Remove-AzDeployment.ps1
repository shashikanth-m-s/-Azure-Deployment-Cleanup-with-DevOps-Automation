param(
    [Parameter(Mandatory=$true)]
    [int]$NumberOfDeploymentsToKeep,

    [Parameter(Mandatory=$true)]
    [string[]]$SubscriptionIds,  
    
    [Parameter(Mandatory=$true)]
    [string]$OutputDirectory  # Directory to store lock details
)

# Set TLS 1.2 as the security protocol
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Ensure the directory exists
if (-not (Test-Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory
}

# File to store lock details
$lockDetailsFile = Join-Path -Path $OutputDirectory -ChildPath "lockDetails.json"

# Function to save lock details to file
function Save-LockDetailsToFile {
    param (
        [Parameter(Mandatory=$true)]
        [array]$lockDetails
    )
    $lockDetails | ConvertTo-Json -Depth 5 | Set-Content -Path $lockDetailsFile
}

# Function to load lock details from file
function Load-LockDetailsFromFile {
    if (Test-Path $lockDetailsFile) {
        return Get-Content -Path $lockDetailsFile | ConvertFrom-Json
    } else {
        return @()
    }
}

# Load previously saved lock details
$allLockDetails = @()  # Initialize as an empty array

foreach ($subscriptionId in $SubscriptionIds) {
    try {
        Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop
        $subscription = Get-AzContext
        Write-Host "Current Subscription: $($subscription.Subscription.Id)"
    } catch {
        Write-Error "Error setting or getting subscription '$subscriptionId': $($_.Exception.Message)"
        continue
    }

    # Get all resource groups
    try {
        $rgs = Get-AzResourceGroup
    } catch {
        Write-Error "Error getting resource groups: $($_.Exception.Message)"
        continue  # Move to the next subscription if resource groups cannot be retrieved
    }

    # Iterate through resource groups
    foreach ($rg in $rgs) {
        $rgname = $rg.ResourceGroupName

        # Store retrieved locks for this resource group
        $existingLocks = Get-AzResourceLock -ResourceGroupName $rgname -ErrorAction SilentlyContinue
        $lockDetails = @{}  # Create an empty hash table to store lock details

        if ($existingLocks) {
            foreach ($lock in $existingLocks) {
                $lockDetails[$lock.Name] = $lock.Properties.Level  # Store lock name as key, level as value
            }
            $allLockDetails += [PSCustomObject]@{
                ResourceGroup = $rgname
                Locks = $lockDetails
            }
            Write-Host "Resource Group with Locks: $rgname"
        }

        # Remove lock on resource group if it exists
        try {
            if ($existingLocks) {
                $existingLocks | ForEach-Object {
                    Remove-AzResourceLock -LockId $_.LockId -Force -ErrorAction Stop
                    Write-Host "    Removed lock: $($_.Name)"
                }
            }
        } catch {
            Write-Error "Error removing lock from resource group '$($rgname)': $($_.Exception.Message)"
            continue
        }

        # Save lock details to file
        Save-LockDetailsToFile -lockDetails $allLockDetails

        # Wait for 3 seconds to ensure locks are fully removed
        Start-Sleep -Seconds 3

        # Get all deployments in resource group
        try {
            $deployments = Get-AzResourceGroupDeployment -ResourceGroupName $rgname -ErrorAction SilentlyContinue
        } catch {
            Write-Error "Error getting deployments for resource group '$($rgname)': $($_.Exception.Message)"
            continue
        }

        if ($deployments) {
            if ($deployments.Count -gt $NumberOfDeploymentsToKeep) {
                # Sort the deployments by timestamp in descending order
                $deployments = $deployments | Sort-Object -Property Timestamp -Descending

                # Delete deployments beyond the specified number to keep
                for ($i = $NumberOfDeploymentsToKeep; $i -lt $deployments.Count; $i++) {
                    try {
                        Remove-AzResourceGroupDeployment -ResourceGroupName $rgname -Name $deployments[$i].DeploymentName -ErrorAction Stop
                        Write-Host "Deleted deployment: $($deployments[$i].DeploymentName) in resource group: $rgname"
                    } catch {
                        Write-Error "Error deleting deployment '$($deployments[$i].DeploymentName)' in resource group '$($rgname)': $($_.Exception.Message)"
                    }
                }
            } else {
                Write-Host "No deployments to delete in resource group: $rgname"
            }
        } else {
            Write-Host "No deployments found in resource group: $rgname"
        }

        # Re-enable locks if they existed before
        $locksToEnable = $allLockDetails | Where-Object { $_.ResourceGroup -eq $rgname } | Select-Object -ExpandProperty Locks
        if ($locksToEnable) {
            foreach ($lockName in $locksToEnable.Keys) {
                $lockLevel = $locksToEnable[$lockName]
                try {
                    New-AzResourceLock -LockName $lockName -LockLevel $lockLevel -ResourceGroupName $rgname -Force -ErrorAction Stop
                    Write-Host "Re-enabled lock: $lockName in resource group: $rgname"
                } catch {
                    Write-Error "Error re-enabling lock '$lockName' on resource group '$($rgname)': $($_.Exception.Message)"
                }
            }
        }
    }

    # Save lock details to file after processing each subscription
    Save-LockDetailsToFile -lockDetails $allLockDetails
}

Write-Host "Script completed. Lock details are saved in $lockDetailsFile."
