param (
    [string]$ConfigFile = "config.json",
    [ValidateSet("downgrade", "restore")]
    [string]$Action
)

function Get-Configuration {
    param([string]$Path)
    return Get-Content $Path | ConvertFrom-Json
}

function Set-SubscriptionContext {
    param([string]$SubscriptionId)

    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
        Write-Warning "SubscriptionId is null or empty. Cannot set context."
        return $false
    }

    try {
        $context = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
        if (-not $context) {
            throw "Context not returned for subscription ${SubscriptionId}"
        }
        return $true
    } catch {
        Write-Warning "Failed to set context for subscription '${SubscriptionId}': $_"
        return $false
    }
}

function Backup-AppServicePlan {
    param($Plan, $BackupPath)

    $Backup = @{
        Name          = $Plan.Name
        ResourceGroup = $Plan.ResourceGroup
        Tier          = $Plan.Sku.Tier
        Size          = $Plan.Sku.Name
        Capacity      = $Plan.Sku.Capacity
        Location      = $Plan.Location
    }

    $FileName = Join-Path $BackupPath "${($Plan.Name)}_backup.json"
    $Backup | ConvertTo-Json -Depth 10 | Out-File -FilePath $FileName -Force
}

function Restore-AppServicePlans {
    param($BackupPath)

    $Files = Get-ChildItem -Path $BackupPath -Filter "*_backup.json"
    foreach ($File in $Files) {
        $Backup = Get-Content $File.FullName | ConvertFrom-Json

        $SubscriptionId = (Get-AzContext).Subscription.Id
        if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
            Write-Error "Azure context not found. Ensure the workflow is properly authenticated."
            continue
        }

        $success = Set-SubscriptionContext -SubscriptionId $SubscriptionId
        if (-not $success) {
            continue
        }

        Write-Host "Restoring: $($Backup.Name)..."
        try {
            Set-AzAppServicePlan -Name $Backup.Name -ResourceGroupName $Backup.ResourceGroup `
                -SkuTier $Backup.Tier -SkuName $Backup.Size -NumberOfWorkers $Backup.Capacity
        } catch {
            Write-Warning "Failed to restore $($Backup.Name): $_"
        }
    }
}

function Set-AppServicePlanToBasic {
    param($Plan)

    if ($Plan.Sku.Tier -eq "Basic" -and $Plan.Sku.Name -eq "B1") {
        Write-Host "Skipping: ${Plan.Name} is already B1"
        return
    }

    Write-Host "Setting: ${Plan.Name} to B1 (Basic)..."
    try {
        Set-AzAppServicePlan -Name ${Plan.Name} -ResourceGroupName ${Plan.ResourceGroup} `
            -SkuTier "Basic" -SkuName "B1" -NumberOfWorkers 1
    } catch {
        Write-Warning "Failed to downgrade ${Plan.Name}: $_"
    }
}

function Invoke-AppServicePlanAction {
    param($Config, $Action)

    $BackupPath = "./AppPlanBackups"
    if (!(Test-Path $BackupPath)) {
        New-Item -ItemType Directory -Path $BackupPath | Out-Null
    }

    foreach ($Project in $Config.Projects) {
        if ([string]::IsNullOrWhiteSpace($Project.SubscriptionId)) {
            Write-Warning "Skipping project with missing SubscriptionId."
            continue
        }

        Write-Host "Processing Environment: ${Project.Environment} Subscription: ${Project.SubscriptionId}"

        $success = Set-SubscriptionContext -SubscriptionId ${Project.SubscriptionId}
        if (-not $success) {
            Write-Error "Azure context not found. Ensure the workflow is properly authenticated."
            continue
        }
        try {
            $ResourceGroups = Get-AzResourceGroup | Select-Object -ExpandProperty ResourceGroupName
        } catch {
            Write-Warning "Failed to retrieve resource groups: $_"
            continue
        }
        foreach ($RG in $ResourceGroups) {
            try {
                $Plans = Get-AzAppServicePlan -ResourceGroupName $RG
            } catch {
                Write-Warning "Failed to retrieve App Service Plans in resource group '${RG}': $_"
                continue
            }

            foreach ($Plan in $Plans) {
                if ($Action -eq "downgrade") {
                    Backup-AppServicePlan -Plan $Plan -BackupPath $BackupPath
                    Set-AppServicePlanToBasic -Plan $Plan
                } elseif ($Action -eq "restore") {
                    Restore-AppServicePlans -BackupPath $BackupPath
                    break  # Only need to restore once from backup
                }
            }
        }
    }
}

# -------- Main Execution --------
try {
    $Configuration = Get-Configuration -Path $ConfigFile
    Invoke-AppServicePlanAction -Config $Configuration -Action $Action
} catch {
    Write-Error "Script execution failed: $_"
    exit 1
}
