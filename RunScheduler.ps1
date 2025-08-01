$Today = (Get-Date).DayOfWeek

if ($Today -eq 'Saturday' -or $Today -eq 'Sunday') {
    .\AppServicePlanManager.ps1 -Action "downgrade"
} else {
    .\AppServicePlanManager.ps1 -Action "restore"
}
