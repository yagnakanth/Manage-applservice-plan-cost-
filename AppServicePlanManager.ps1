param (
    [string]$ConfigFile = "config.json",
    [ValidateSet("downgrade", "restore")]
    [string]$Action
)

function Get-Configuration {
    param([string]$Path)
    return Get-Content -Path $Path | ConvertFrom-Json
}

function Backup-AppServicePlans {
    param($Plans, $Environment)

    $backupDir = "./AppPlanBackups"
    if (!(Test-Path $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir | Out-Null
    }

    $backupFile = Join-Path $backupDir "$Environment-AppPlans.json"
    $Plans | ConvertTo-Json -Depth 10 | Set-Content -Path $backupFile
    Write-Host "Backup completed for $Environment: $backupFile"
}

function Load-BackupPlans {
    param($Environment)

    $backupFile = "./AppPlanBackups/$Environment-AppPlans.json"
    if (Test-Path $backupFile) {
        return Get-Content -Path $backupFile | ConvertFrom-Json
    } else {
        Write-Host "No backup found for $Environment. Skipping restore."
        return @()
    }
}

function Invoke-AppServicePlanAction {
    param($Config, $Action)

    $Results = @()

    foreach ($Project in $Config.Projects) {
        $Environment = $Project.Environment
        $SubscriptionId = $Project.SubscriptionId
        $ResourceGroup = $Project.ResourceGroup # 🆕 Added

        if (-not $ResourceGroup) { # 🆕 Added
            Write-Warning "Missing ResourceGroup for $Environment. Skipping..." # 🆕 Added
            continue # 🆕 Added
        }

        try {
            Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
        } catch {
            Write-Host "Failed to set subscription context for $Environment"
            continue
        }

        Write-Host "[${Environment}] Processing Resource Group: $ResourceGroup" # 🔄 Changed

        try {
            $Plans = Get-AzAppServicePlan -ResourceGroupName $ResourceGroup # 🔄 Changed

            if ($Action -eq "downgrade") {
                Backup-AppServicePlans -Plans $Plans -Environment $Environment

                foreach ($Plan in $Plans) {
                    if ($Plan.Sku.Tier -eq "PremiumV2" -or $Plan.Sku.Tier -eq "PremiumV3") {
                        Write-Host "Downgrading $($Plan.Name) to B1..."
                        Set-AzAppServicePlan -ResourceGroupName $Plan.ResourceGroup -Name $Plan.Name -Tier "Basic" -WorkerSize 0
                        $Results += "${Environment} - $($Plan.Name) downgraded to Basic (B1)" # 🔄 Fixed
                    } else {
                        $Results += "${Environment} - $($Plan.Name) is already at or below Basic tier." # 🔄 Fixed
                    }
                }

            } elseif ($Action -eq "restore") {
                $BackupPlans = Load-BackupPlans -Environment $Environment

                foreach ($Backup in $BackupPlans) {
                    $planName = $Backup.Name
                    $sku = $Backup.Sku
                    Write-Host "Restoring $planName to $($sku.Tier) ($($sku.Name))..."
                    Set-AzAppServicePlan -ResourceGroupName $ResourceGroup -Name $planName -Tier $sku.Tier -WorkerSize $sku.Capacity
                    $Results += "${Environment} - $planName restored to $($sku.Tier) ($($sku.Name))" # 🔄 Fixed
                }
            }

        } catch {
            Write-Host "Error processing $Environment: $_"
        }
    }

    $Results | Out-File -FilePath "./AppServicePlanResults.txt" -Encoding utf8
    Write-Host "Action [$Action] completed. Results saved to AppServicePlanResults.txt"
}

# Entry point
try {
    $Configuration = Get-Configuration -Path $ConfigFile
    Invoke-AppServicePlanAction -Config $Configuration -Action $Action
} catch {
    Write-Error "Failed to run the script: $_"
    exit 1
}
