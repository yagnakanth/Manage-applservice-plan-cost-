param (
    [string]$ConfigFile = "./Config.json",
    [ValidateSet("downgrade", "restore")]
    [string]$Action
)

function Get-Configuration {
    param([string]$Path)
    return Get-Content $Path | ConvertFrom-Json
}

function Set-SubscriptionContext {
    param([string]$SubscriptionId)
    try {
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    } catch {
        Write-Warning "Failed to set context for subscription ${SubscriptionId}"
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

    $FileName = "${BackupPath}\${($Plan.Name)}_backup.json"
    $Backup | ConvertTo-Json -Depth 10 | Out-File -FilePath $FileName -Force
}

function Restore-AppServicePlans {
    param($BackupPath)

    $Files = Get-ChildItem -Path $BackupPath -Filter "*_backup.json"
    foreach ($File in $Files) {
        $Backup = Get-Content $File.FullName | ConvertFrom-Json

        Set-SubscriptionContext -SubscriptionId (Get-AzContext).Subscription.Id

        $Name = $Backup.Name
        $RG = $Backup.ResourceGroup
        $Tier = $Backup.Tier
        $Size = $Backup.Size
        $Workers = $Backup.Capacity

        Write-Host "Restoring: $Name..."
        try {
            Set-AzAppServicePlan -Name $Name -ResourceGroupName $RG `
                -SkuTier $Tier -SkuName $Size -NumberOfWorkers $Workers
        } catch {
            Write-Warning "Failed to restore ${Name}: $_"
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
        Write-Host "Processing Environment: ${Project.Environment} Subscription: ${Project.SubscriptionId}"
        Set-SubscriptionContext -SubscriptionId ${Project.SubscriptionId}
        
        $ResourceGroups = Get-AzResourceGroup | Select-Object -ExpandProperty ResourceGroupName
        foreach ($RG in $ResourceGroups) {
            try {
                $Plans = Get-AzAppServicePlan -ResourceGroupName $RG
            } catch {
                Write-Warning "Failed to retrieve App Service Plans in resource group ${RG}: $_"
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
$Configuration = Get-Configuration -Path $ConfigFile
Invoke-AppServicePlanAction -Config $Configuration -Action $Action
