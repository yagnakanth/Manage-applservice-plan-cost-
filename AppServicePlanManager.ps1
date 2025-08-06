param (
    [string]$ConfigFile = "./config.json",
    [ValidateSet("downgrade", "restore")]
    [string]$Action
)

function Log-Group {
    param ([string]$Name)
    Write-Host "::group::$Name"
}
function Log-EndGroup {
    Write-Host "::endgroup::"
}

function Get-Configuration {
    param([string]$Path)
    Log-Group "Load Configuration"
    Write-Host "Loading config from $Path..."
    $config = Get-Content $Path | ConvertFrom-Json
    Log-EndGroup
    return $config
}

function Set-SubscriptionContext {
    param([string]$SubscriptionId)

    Log-Group "Set Context: $SubscriptionId"
    try {
        $context = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
        Write-Host "Context set to: $($context.Subscription.Name) ($SubscriptionId)"
        Log-EndGroup
        return $true
    } catch {
        Write-Warning "Failed to set context for subscription '${SubscriptionId}': $_"
        Log-EndGroup
        return $false
    }
}

function Backup-AppServicePlan {
    param($Plan, $BackupPath)
    $FileName = Join-Path $BackupPath "${($Plan.Name)}_backup.json"
    Log-Group "Backup Plan: $($Plan.Name)"
    Write-Host "Backing up $($Plan.Name) to $FileName"
    $Plan | ConvertTo-Json -Depth 10 | Out-File -FilePath $FileName -Force
    Log-EndGroup
}

function Restore-AppServicePlans {
    param($BackupPath)

    Log-Group "Restore App Service Plans"
    $Files = Get-ChildItem -Path $BackupPath -Filter "*_backup.json"
    foreach ($File in $Files) {
        $Backup = Get-Content $File.FullName | ConvertFrom-Json
        $success = Set-SubscriptionContext -SubscriptionId (Get-AzContext).Subscription.Id
        if (-not $success) { continue }

        try {
            Write-Host "Restoring $($Backup.Name)..."
            Set-AzAppServicePlan -Name $Backup.Name -ResourceGroupName $Backup.ResourceGroup `
                -SkuTier $Backup.Tier -SkuName $Backup.Size -NumberOfWorkers $Backup.Capacity
        } catch {
            Write-Warning "Failed to restore $($Backup.Name): $_"
        }
    }
    Log-EndGroup
}

function Set-AppServicePlanToBasic {
    param($Plan)

    Log-Group "Downgrade Plan: $($Plan.Name)"
    if ($Plan.Sku.Tier -eq "Basic" -and $Plan.Sku.Name -eq "B1") {
        Write-Host "Skipping: ${Plan.Name} is already B1"
    } else {
        Write-Host "Downgrading ${Plan.Name} to Basic B1"
        try {
            Set-AzAppServicePlan -Name ${Plan.Name} -ResourceGroupName ${Plan.ResourceGroup} `
                -SkuTier "Basic" -SkuName "B1" -NumberOfWorkers 1
        } catch {
            Write-Warning "Failed to downgrade ${Plan.Name}: $_"
        }
    }
    Log-EndGroup
}

function Invoke-AppServicePlanAction {
    param($Config, $Action)

    $BackupPath = "./AppPlanBackups"
    if (!(Test-Path $BackupPath)) {
        New-Item -ItemType Directory -Path $BackupPath | Out-Null
    }

    foreach ($Project in $Config.Projects) {
        $SubscriptionId = $Project.SubscriptionId
        Write-Host ">>> Processing: Environment=${Project.Environment}, SubscriptionId=$SubscriptionId"

        $success = Set-SubscriptionContext -SubscriptionId $SubscriptionId
        if (-not $success) {
            continue
        }

        $ResourceGroups = Get-AzResourceGroup | Select-Object -ExpandProperty ResourceGroupName
        foreach ($RG in $ResourceGroups) {
            try {
                $Plans = Get-AzAppServicePlan -ResourceGroupName $RG
            } catch {
                Write-Warning "Cannot fetch plans in $RG: $_"
                continue
            }

            foreach ($Plan in $Plans) {
                if ($Action -eq "downgrade") {
                    Backup-AppServicePlan -Plan $Plan -BackupPath $BackupPath
                    Set-AppServicePlanToBasic -Plan $Plan
                } elseif ($Action -eq "restore") {
                    Restore-AppServicePlans -BackupPath $BackupPath
                    break
                }
            }
        }
    }
}

# ------- Main -------
Write-Host "::group::Start Execution"
Write-Host "ConfigFile: $ConfigFile"
Write-Host "Action: $Action"
Write-Host "::endgroup::"

$Configuration = Get-Configuration -Path $ConfigFile
Invoke-AppServicePlanAction -Config $Configuration -Action $Action
