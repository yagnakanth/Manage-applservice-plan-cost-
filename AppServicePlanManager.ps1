param (
    [string]$ConfigFile = "config.json",
    [ValidateSet("downgrade", "restore")]
    [string]$Action,
    [Parameter(Mandatory=$true)]                          ### NEW
    [string]$ResourceGroupName                            ### NEW
)

function Get-Configuration {
    param([string]$Path)
    return Get-Content $Path | ConvertFrom-Json
}

function Set-CurrentSubscriptionContext {
    try {
        $context = Get-AzContext
        if (-not $context) {
            throw "Azure context is not available. Ensure login is completed in the workflow."
        }
        Write-Host "Using the Azure subscription: $($context.Subscription.Name) [$($context.Subscription.Id)]"    ### FIXED typo
        return $context.Subscription.Id
    } catch {
        Write-Error "Failed to retrieve Azure Context: $_"
        exit 1                                                ### FIXED typo (was exiit)
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
    Write-Output "Backup created for: $($Plan.Name)"        ### UPDATED from Write-Host to Write-Output
}

function Restore-AppServicePlans {
    param($BackupPath, $ResultLog)                          ### UPDATED

    $Files = Get-ChildItem -Path $BackupPath -Filter "*_backup.json"
    foreach ($File in $Files) {
        $Backup = Get-Content $File.FullName | ConvertFrom-Json

        Write-Host "Restoring: $($Backup.Name)..."
        try {
            Set-AzAppServicePlan -Name $Backup.Name -ResourceGroupName $Backup.ResourceGroup `
                -SkuTier $Backup.Tier -SkuName $Backup.Size -NumberOfWorkers $Backup.Capacity
            Add-Content $ResultLog "Restored: $($Backup.Name) in $($Backup.ResourceGroup) to $($Backup.Tier)/$($Backup.Size)"  ### NEW
        } catch {
            $errorMsg = "Failed to restore $($Backup.Name): $_"
            Write-Warning $errorMsg
            Add-Content $ResultLog $errorMsg                  ### NEW
        }
    }
}

function Set-AppServicePlanToBasic {
    param($Plan, $ResultLog)                                ### UPDATED

    if ($Plan.Sku.Tier -eq "Basic" -and $Plan.Sku.Name -eq "B1") {
        $msg = "Skipping: ${Plan.Name} is already B1"
        Write-Host $msg
        Add-Content $ResultLog $msg                          ### NEW
        return
    }

    Write-Host "Setting: ${Plan.Name} to B1 (Basic)..."
    try {
        Set-AzAppServicePlan -Name ${Plan.Name} -ResourceGroupName ${Plan.ResourceGroup} `
            -SkuTier "Basic" -SkuName "B1" -NumberOfWorkers 1
        Add-Content $ResultLog "Downgraded: ${Plan.Name} in ${Plan.ResourceGroup} to Basic/B1"    ### NEW
    } catch {
        $errorMsg = "Failed to downgrade ${Plan.Name}: $_"
        Write-Warning $errorMsg
        Add-Content $ResultLog $errorMsg                      ### NEW
    }
}

function Invoke-AppServicePlanAction {
    param($Config, $Action, $TargetRG)                       ### UPDATED

    $context = Get-AzContext
    if (-not $context) {
        Write-Error "Azure context is not valid. Exiting script."
        exit 1 
    }

    $ActiveSubscriptionId = $context.Subscription.Id
    Write-Host "`n=== Active Subscription: $ActiveSubscriptionId ===`n"

    $BackupPath = "./AppPlanBackups"
    if (!(Test-Path $BackupPath)) {
        New-Item -ItemType Directory -Path $BackupPath | Out-Null
    }

    $ResultLog = "./AppServicePlanResults.txt"               ### NEW
    Remove-Item $ResultLog -ErrorAction SilentlyContinue     ### NEW
    New-Item -Path $ResultLog -ItemType File -Force | Out-Null  ### NEW

    foreach ($Project in $Config.Projects) {
        if ($Project.SubscriptionId -ne $ActiveSubscriptionId) {
            Write-Warning "Skipping config for SubscriptionId $($Project.SubscriptionId), current is $ActiveSubscriptionId."
            continue
        }

        Write-Host "`nProcessing Environment: $($Project.Environment) Subscription: $($Project.SubscriptionId)"

        try {
            $Plans = Get-AzAppServicePlan -ResourceGroupName $TargetRG     ### UPDATED to use specific RG
        } catch {
            Write-Warning "Failed to retrieve App Service Plans in resource group '${TargetRG}': $_"
            continue
        }

        foreach ($Plan in $Plans) {
            if ($Action -eq "downgrade") {
                Backup-AppServicePlan -Plan $Plan -BackupPath $BackupPath
                Set-AppServicePlanToBasic -Plan $Plan -ResultLog $ResultLog       ### UPDATED to log results
            } elseif ($Action -eq "restore") {
                Restore-AppServicePlans -BackupPath $BackupPath -ResultLog $ResultLog   ### UPDATED to log results
                break
            }
        }
    }

    Write-Host "`nAction '$Action' completed. Results saved to: $ResultLog"       ### NEW
}

# -------- Main Execution --------
try {
    $Configuration = Get-Configuration -Path $ConfigFile
    Invoke-AppServicePlanAction -Config $Configuration -Action $Action -TargetRG $ResourceGroupName    ### UPDATED
} catch {
    Write-Error "Script execution failed: $_"
    exit 1
}
