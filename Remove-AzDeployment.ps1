param(
    [Parameter(Mandatory=$true)]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$NumberOfDeploymentsToKeep,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,  # Single subscription ID to target
    
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory  # Directory to store lock details (although not storing in JSON)
)

# Set TLS 1.2 as the security protocol
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Function to handle subscription context
function Set-SubscriptionContext {
    param (
        [Parameter(Mandatory=$true)]
        [string]$subscriptionId
    )
    try {
        Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop
        $subscription = Get-AzContext
        Write-Host "Current Subscription: $($subscription.Subscription.Id)"
    } catch {
        Write-Error "Error setting or getting subscription '$subscriptionId': $($_.Exception.Message)"
        throw $_  # Rethrow exception to handle upstream
    }
}

# Function to get and process resource groups
function Process-ResourceGroups {
    try {
        $rgs = Get-AzResourceGroup
    } catch {
        Write-Error "Error getting resource groups: $($_.Exception.Message)"
        return  # Skip further processing for this subscription
    }

    foreach ($rg in $rgs) {
        $rgname = $rg.ResourceGroupName

        # Process resource group
        Process-ResourceGroup -rgname $rgname
    }
}

# Function to process individual resource group
function Process-ResourceGroup {
    param (
        [Parameter(Mandatory=$true)]
        [string]$rgname
    )

    # Remove locks on resource group if they exist
    $existingLocks = Get-AzResourceLock -ResourceGroupName $rgname -ErrorAction SilentlyContinue
    try {
        if ($existingLocks) {
            $existingLocks | ForEach-Object {
                Remove-AzResourceLock -LockId $_.LockId -Force -ErrorAction Stop
                Write-Host "Removed lock: $($_.Name) from resource group: $rgname"
            }
        }
    } catch {
        Write-Error "Error removing lock from resource group '$($rgname)': $($_.Exception.Message)"
        return
    }

    # Wait for 3 seconds to ensure locks are fully removed
    Start-Sleep -Seconds 3

    # Get all deployments in resource group
    try {
        $deployments = Get-AzResourceGroupDeployment -ResourceGroupName $rgname -ErrorAction SilentlyContinue
    } catch {
        Write-Error "Error getting deployments for resource group '$($rgname)': $($_.Exception.Message)"
        return
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
}

# Set the subscription context and process resource groups
try {
    Set-SubscriptionContext -subscriptionId $SubscriptionId
    Process-ResourceGroups
} catch {
    Write-Error "Error processing subscription '$SubscriptionId': $($_.Exception.Message)"
}

Write-Host "Script completed."
