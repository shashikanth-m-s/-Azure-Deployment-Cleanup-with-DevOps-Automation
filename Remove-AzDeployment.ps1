param(
    [Parameter(Mandatory=$true)]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$NumberOfDeploymentsToKeep,

    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory=$true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupNamePattern
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
    if ($lockDetails -and $lockDetails.Count -gt 0) {
        $lockDetails | ConvertTo-Json -Depth 5 | Set-Content -Path $lockDetailsFile
    }
}

# Function to log messages
function Log-Message {
    param (
        [string]$message,
        [string]$type = "INFO"  # INFO, ERROR, WARNING
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp [$type] $message"
    $logFile = Join-Path -Path $OutputDirectory -ChildPath "script.log"
    $logMessage | Out-File -Append -FilePath $logFile
    Write-Host $logMessage
}

# Initialize lock details array
$allLockDetails = @()

try {
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    $subscription = Get-AzContext
    Log-Message -message "Current Subscription: $($subscription.Subscription.Id)" -type "INFO"
} catch {
    Log-Message -message "Error setting or getting subscription '$SubscriptionId': $($_.Exception.Message)" -type "ERROR"
    exit 1
}

# Get all resource groups
try {
    if ($ResourceGroupNamePattern) {
        $rgs = Get-AzResourceGroup | Where-Object { $_.ResourceGroupName -match $ResourceGroupNamePattern }
    } else {
        $rgs = Get-AzResourceGroup
    }
} catch {
    Log-Message -message "Error getting resource groups: $($_.Exception.Message)" -type "ERROR"
    exit 1
}

# Iterate through resource groups
foreach ($rg in $rgs) {
    $rgname = $rg.ResourceGroupName

    # Store retrieved locks for this resource group
    $existingLocks = Get-AzResourceLock -ResourceGroupName $rgname -ErrorAction SilentlyContinue
    $lockDetails = @{}  # Create an empty hash table to store lock details

    if ($existingLocks) {
        foreach ($lock in $existingLocks) {
            $lockDetails[$lock.Name] = @{
                Level        = $lock.Properties.Level
                ResourceName = $lock.ResourceName
                ResourceType = $lock.ResourceType
            }
        }
        Log-Message -message "Resource Group with Locks: $rgname" -type "INFO"
    }

    # Save lock details to array and immediately to file
    if ($lockDetails.Count -gt 0) {
        $allLockDetails += [PSCustomObject]@{
            ResourceGroup = $rgname
            Locks = $lockDetails
        }
        Save-LockDetailsToFile -lockDetails $allLockDetails
    }

    # Remove lock on resource group if it exists
    try {
        if ($existingLocks) {
            $existingLocks | ForEach-Object {
                # Only remove the lock if its scope is on the resource group
                if ($_.ResourceType -eq "Microsoft.Authorization/locks") {
                    Remove-AzResourceLock -LockId $_.LockId -Force -ErrorAction Stop
                    Log-Message -message "Removed lock: $($_.Name) with scope on resource group: $rgname" -type "INFO"
                } else {
                    Log-Message -message "Skipped lock: $($_.Name) with scope on resource: $($_.ResourceName)" -type "INFO"
                }
            }
        }
    } catch {
        Log-Message -message "Error removing lock from resource group '$($rgname)': $($_.Exception.Message)" -type "ERROR"
        continue
    }

    # Wait for 2 seconds to ensure locks are fully removed
    Start-Sleep -Seconds 2

    # Get all deployments in resource group
    try {
        $deployments = Get-AzResourceGroupDeployment -ResourceGroupName $rgname -ErrorAction SilentlyContinue
    } catch {
        Log-Message -message "Error getting deployments for resource group '$($rgname)': $($_.Exception.Message)" -type "ERROR"
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
                    Log-Message -message "Deleted deployment: $($deployments[$i].DeploymentName) in resource group: $rgname" -type "INFO"
                } catch {
                    Log-Message -message "Error deleting deployment '$($deployments[$i].DeploymentName)' in resource group '$($rgname)': $($_.Exception.Message)" -type "ERROR"
                }
            }
        } else {
            Log-Message -message "No deployments to delete in resource group: $rgname" -type "INFO"
        }
    } else {
        Log-Message -message "No deployments found in resource group: $rgname" -type "INFO"
    }

    # Re-enable locks if they existed before
    if ($existingLocks) {
        foreach ($lock in $existingLocks) {
            $lockName = $lock.Name
            $lockLevel = $lock.Properties.Level
            $ResourceType = $lock.ResourceType
            # Check if the lock is at the resource group level by comparing Name and ResourceName
            if ($ResourceType -eq "Microsoft.Authorization/locks") {
                try {
                    New-AzResourceLock -LockName $lockName -LockLevel $lockLevel -ResourceGroupName $rgname -Force -ErrorAction Stop
                    Log-Message -message "Re-enabled lock: $lockName on resource group: $rgname" -type "INFO"
                } catch {
                    Log-Message -message "Error re-enabling lock '$lockName' on resource group '$($rgname)': $($_.Exception.Message)" -type "ERROR"
                }
            } else {
                try {
                    # Use the original method for resources that are not resource groups
                    Log-Message -message "Skipping Re-enabling of lock: $lockName on resource: $($lock.ResourceName) as already lock present and scope type $($lock.ResourceType)" -type "INFO"
                } catch {
                    Log-Message -message "Error getting lock info for '$lockName' on resource '$($lock.ResourceName)' of type '$($lock.ResourceType)': $($_.Exception.Message)" -type "ERROR"
                }
            }
        }
    }
}

# Save all lock details to file at the end if there are any details to save
if ($allLockDetails.Count -gt 0) {
    Save-LockDetailsToFile -lockDetails $allLockDetails
}

Log-Message -message "Script completed. Lock details are saved in $lockDetailsFile." -type "INFO"
