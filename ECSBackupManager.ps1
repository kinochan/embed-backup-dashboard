Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Core
# ============================================
# AppRoot detection
# ============================================
$script:AppVersion = "2.0"
$AppRoot = $null
if ($PSScriptRoot -and $PSScriptRoot.Trim() -ne "") {
    $AppRoot = $PSScriptRoot
}
elseif ($MyInvocation.MyCommand.Path -and $MyInvocation.MyCommand.Path.Trim() -ne "") {
    $AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $AppRoot = Split-Path -Parent $exePath
}
if (-not $AppRoot -or $AppRoot.Trim() -eq "") {
    throw "AppRoot could not be determined."
}
# ============================================
# Core paths
# ============================================
$ConfigFile  = Join-Path $AppRoot "backup.config"
$ProfilesDir = Join-Path $AppRoot "Profiles"
$SitesDir    = Join-Path $AppRoot "Sites"
$LogDir      = Join-Path $AppRoot "Logs"
$LogFile     = Join-Path $LogDir "backup_log.txt"
foreach ($d in @($ProfilesDir,$SitesDir,$LogDir)) {
    if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
}
# ============================================
# Logging
# ============================================
function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date), $Message
    Add-Content -Path $LogFile -Value $line
}
# ============================================
# Config helpers
# ============================================
function Load-Config {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Config file '$Path' not found." }
    $cfg = @{}
    $section = ""
    foreach ($line in Get-Content $Path) {
        $trim = $line.Trim()
        if ($trim -eq "" -or $trim.StartsWith("#")) { continue }
        if ($trim.StartsWith("[") -and $trim.EndsWith("]")) {
            $section = $trim.Trim("[","]")
            if (-not $cfg.ContainsKey($section)) { $cfg[$section] = @{} }
            continue
        }
        if ($trim -match "^(.*?)=(.*)$") {
            $key = $matches[1].Trim()
            $val = $matches[2].Trim()
            $cfg[$section][$key] = $val
        }
    }
    return $cfg
}
function Save-Config {
    param($Config,[string]$Path)
    $lines = @()
    foreach ($section in $Config.Keys) {
        $lines += "[$section]"
        foreach ($key in $Config[$section].Keys) {
            $val = $Config[$section][$key]
            $lines += "$key = $val"
        }
        $lines += ""
    }
    $lines | Out-File $Path -Encoding UTF8
}
function Load-Profile {
    param([string]$ProfileName)
    $ProfilePath = Join-Path $ProfilesDir "$ProfileName.ini"
    if (-not (Test-Path $ProfilePath)) { throw "Profile '$ProfileName' not found." }
    return Load-Config $ProfilePath
}
function Save-Profile {
    param([string]$ProfileName,$ConfigObject)
    $ProfilePath = Join-Path $ProfilesDir "$ProfileName.ini"
    Save-Config -Config $ConfigObject -Path $ProfilePath
}
# ============================================
# Initial config (production-safe: no auto-create)
# ============================================
if (-not (Test-Path $ConfigFile)) {
    Write-Log "No backup.config found — waiting for user to create one."
    $Config = @{
        General = @{}
        Email   = @{}
    }
} else {
    $Config = Load-Config $ConfigFile
}
$Global:ActiveProfile = $null
# ============================================
# Theme detection
# ============================================
function Get-IsDarkTheme {
    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        $appsUseLight = Get-ItemProperty -Path $key -Name AppsUseLightTheme -ErrorAction Stop
        return ($appsUseLight.AppsUseLightTheme -eq 0)
    } catch { return $false }
}
$IsDark = Get-IsDarkTheme
# ============================================
# SQLCMD detection
# ============================================
function Get-SqlCmdPath {
    $ecsSqlCmd = "C:\Program Files (x86)\ECS7\Manager\sqlcmd.exe"
    if (Test-Path $ecsSqlCmd) { return $ecsSqlCmd }
    $odbc180 = "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\sqlcmd.exe"
    if (Test-Path $odbc180) { return $odbc180 }
    $wingetSqlCmd = "C:\Program Files\Microsoft SQLCMD\sqlcmd.exe"
    if (Test-Path $wingetSqlCmd) { return $wingetSqlCmd }
    $wingetLink = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\sqlcmd.exe"
    if (Test-Path $wingetLink) { return $wingetLink }
    $candidates = @(
        "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\sqlcmd.exe",
        "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\160\Tools\Binn\sqlcmd.exe",
        "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\150\Tools\Binn\sqlcmd.exe",
        "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\140\Tools\Binn\sqlcmd.exe"
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }
    throw "SQLCMD not found."
}
# ============================================
# AzCopy detection
# ============================================
function Get-AzCopyPath {
    $link = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\azcopy.exe"
    if ($link -and (Test-Path $link)) { return $link }
    $common = @(
        "C:\Program Files (x86)\Microsoft SDKs\Azure\AzCopy\AzCopy.exe",
        "C:\Program Files\Microsoft SDKs\Azure\AzCopy\AzCopy.exe"
    )
    foreach ($p in $common) {
        if (Test-Path $p) { return $p }
    }
    return "azcopy.exe"
}
# ============================================
# BackupPath resolution (used only when user sets)
# ============================================
function Resolve-BackupPath {
    $defaultE = "E:\SQL\BACKUP"
    $defaultC = "C:\SQL\BACKUP"
    if (Test-Path "E:\") {
        if (-not (Test-Path $defaultE)) {
            New-Item -Path $defaultE -ItemType Directory -Force | Out-Null
        }
        return $defaultE
    }
    if (Test-Path $defaultC) { return $defaultC }
    New-Item -Path $defaultC -ItemType Directory -Force | Out-Null
    return $defaultC
}
# ============================================
# SAS validation
# ============================================
function Validate-SasToken {
    param([string]$SasToken)
    if (-not $SasToken -or $SasToken.Trim() -eq "") { return $false }
    if ($SasToken -notmatch "\?")   { return $false }
    if ($SasToken -notmatch "sig=") { return $false }
    return $true
}
# ============================================
# Config validator (no sensitive defaults)
# ============================================
function Validate-Config {
    param([ref]$Config)
    if (-not $Config.Value.ContainsKey("General")) {
        $Config.Value["General"] = @{
            SiteName       = ""
            BackupPath     = ""
            SASToken       = ""
            StorageAccount = ""
            AzureUpload    = "false"
        }
    }
    if (-not $Config.Value.ContainsKey("Email")) {
        $Config.Value["Email"] = @{
            SMTPServer = ""
            SMTPPort   = ""
            SMTPUser   = ""
            SMTPPass   = ""
            EmailTo    = ""
            EmailFrom  = ""
        }
    }
    return $Config.Value
}
# ============================================
# Backup engine
# ============================================
function Update-Progress {
    param([int]$Value)
    if ($Value -lt $progressBar.Minimum) { $Value = $progressBar.Minimum }
    if ($Value -gt $progressBar.Maximum) { $Value = $progressBar.Maximum }
    if ($progressBar.InvokeRequired) {
        $progressBar.Invoke([Action]{ $progressBar.Value = $Value })
    } else {
        $progressBar.Value = $Value
    }
}
function Update-Status {
    param([string]$Message)
    if ($lblStatus.InvokeRequired) {
        $lblStatus.Invoke([Action]{ $lblStatus.Text = "Status: $Message" })
    } else {
        $lblStatus.Text = "Status: $Message"
    }
}
function Backup-Database {
    param(
        [string]$ServerName,
        [string]$BackupPath,
        [string]$DbName,
        [string]$Timestamp,
        [string]$SqlCmdPath,
        [int]$ProgressStart,
        [int]$ProgressRange
    )
    $bakFile = Join-Path $BackupPath "$dbName-$timestamp.bak"
    Write-Log "Backing up $dbName to $bakFile"
    $query  = "BACKUP DATABASE [$dbName] TO DISK='$bakFile' WITH INIT, STATS = 10"
    & $SqlCmdPath -S $ServerName -E -C -Q $query 2>&1 | ForEach-Object {
        $line = [string]$_
        if ($line -match "([0-9]+) percent processed") {
            $percent = [int]$matches[1]
            Update-Progress ($ProgressStart + [int]($percent * $ProgressRange / 100))
            Update-Status "Backing up $dbName ($percent%)"
        }
    } | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "sqlcmd returned exit code $LASTEXITCODE for $dbName"
    }
    Write-Log "Backup complete for $dbName"
    return $bakFile
}
function Upload-ToAzure {
    param(
        [string]$AzCopyPath,
        [string]$BakFile,
        [string]$StorageAccount,
        [string]$Container,
        [string]$SasToken,
        [string]$DbName,
        [string]$Timestamp,
        [int]$ProgressStart,
        [int]$ProgressRange
    )
    $blobName        = "$dbName-$timestamp.bak"
    $encodedBlobName = [System.Uri]::EscapeDataString($blobName)
    $dest            = "https://$StorageAccount.blob.core.windows.net/$Container/$encodedBlobName$SasToken"
    Write-Log "Uploading $bakFile to Azure container '$container'"
    Write-Log "Destination: $dest"
    & $AzCopyPath copy $BakFile $dest --overwrite=true --from-to=LocalBlob 2>&1 | ForEach-Object {
        $line = [string]$_
        if ($line -match "([0-9]+(?:\.[0-9]+)?)\s*%") {
            $percent = [double]$matches[1]
            Update-Progress ($ProgressStart + [int]($percent * $ProgressRange / 100))
            Update-Status "Uploading $dbName to Azure ($percent%)"
        }
    } | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "AzCopy returned exit code $LASTEXITCODE for $dbName"
    }
    Write-Log "AzCopy upload complete for $dbName"
}
function Clean-Retention {
    param(
        [string]$BackupPath,
        [int]$RetentionDays
    )
    Write-Log "Cleaning local backups older than $RetentionDays days..."
    Get-ChildItem -Path $BackupPath -Filter *.bak |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) } |
        ForEach-Object {
            Write-Log "Deleting: $($_.FullName)"
            Remove-Item $_.FullName -Force
        }
}
function Send-EmailReport {
    param(
        [string]$SiteName,
        [string]$Timestamp,
        [System.Collections.ArrayList]$Errors,
        [string]$SmtpServer,
        [int]$SmtpPort,
        [string]$SmtpUser,
        [string]$SmtpPass,
        [string]$EmailTo,
        [string]$EmailFrom
    )
    if ($Errors.Count -eq 0) {
        $subject = "SQL Backup SUCCESS ($siteName) - $timestamp"
        $body    = "All backups completed successfully for site '$siteName'.`nLog file: $LogFile"
    } else {
        $subject = "SQL Backup FAILURE ($siteName) - $timestamp"
        $body    = "Errors occurred:`n`n" + ($Errors -join "`n") + "`n`nLog file: $LogFile"
    }
    try {
        $securePass = ConvertTo-SecureString $smtpPass -AsPlainText -Force
        $cred       = New-Object System.Management.Automation.PSCredential($smtpUser, $securePass)
        Send-MailMessage -To $emailTo -From $emailFrom -Subject $subject -Body $body `
            -SmtpServer $smtpServer -Port $SmtpPort -UseSsl -Credential $cred
        Write-Log "Email sent: $subject"
    }
    catch {
        Write-Log "ERROR sending email: $_"
    }
}
function Start-Backup {
    param(
        $Config,
        [ScriptBlock]$StatusCallback,
        [string]$SelectedSite,
        [bool]$EnableAzure
    )
    if ([string]::IsNullOrWhiteSpace($SelectedSite) -and $Config.General) {
        $SelectedSite = [string]$Config.General.SiteName
    }
    Write-Log "Backup worker resolved site selection: '$SelectedSite'."
    if ([string]::IsNullOrWhiteSpace($SelectedSite)) {
        throw "No site selected — cannot run backup."
    }
    $siteConfigPath = Join-Path $SitesDir "$SelectedSite.ini"
    if (-not (Test-Path $siteConfigPath)) {
        throw "Site config '$siteConfigPath' not found — create it first."
    }
    $siteConfig = Load-Config $siteConfigPath
    $Config = Validate-Config ([ref]$Config)
    $Config.General.SiteName       = $siteConfig.Site.SiteName
    $Config.General.BackupPath     = $siteConfig.Site.BackupPath
    $Config.General.SASToken       = $siteConfig.Site.SASToken
    $Config.General.StorageAccount = $siteConfig.Site.StorageAccount
    $siteName       = $Config.General.SiteName
    $backupPath     = $Config.General.BackupPath
    $sas            = $Config.General.SASToken
    $storageAccount = $Config.General.StorageAccount
    if (-not $siteName -or -not $backupPath) {
        throw "SiteName and BackupPath must be set in site config."
    }
    $emailCfg = $Config.Email
    $serverName = "ECSSERVER"
    $databases  = @("ECS7","ECS7_Cloud")
    $localRetentionDays = 3
    $sqlcmd = Get-SqlCmdPath
    $azcopy = Get-AzCopyPath
    Write-Log "SqlCmdPath: $sqlcmd"
    Write-Log "AzCopyPath: $azcopy"
    if (-not (Test-Path $backupPath)) {
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
    }
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $errors = New-Object System.Collections.ArrayList
    Write-Log "==============================="
    Write-Log "Backup started for site: $siteName at $(Get-Date)"
    Write-Log "AppRoot: $AppRoot"
    Write-Log "ProfilesDir: $ProfilesDir"
    Write-Log "SitesDir: $SitesDir"
    Write-Log "LogDir: $LogDir"
    Write-Log "BackupPath: $backupPath"
    Write-Log "AzureUpload: $EnableAzure"
    Write-Log "==============================="
    & taskkill /IM azcopy.exe /F 2>$null
    Start-Sleep -Seconds 1
    $StatusCallback.Invoke("Starting backup...")
    Update-Progress 5
    for ($databaseIndex = 0; $databaseIndex -lt $databases.Count; $databaseIndex++) {
        $dbName = $databases[$databaseIndex]
        $phaseStart = 5 + ($databaseIndex * 45)
        $backupRange = if ($EnableAzure) { 30 } else { 45 }
        try {
            $StatusCallback.Invoke("Backing up $dbName...")
            Update-Progress $phaseStart
            $bakFile = Backup-Database -ServerName $serverName -BackupPath $backupPath `
                                       -DbName $dbName -Timestamp $timestamp -SqlCmdPath $sqlcmd `
                                       -ProgressStart $phaseStart -ProgressRange $backupRange
            Update-Progress ($phaseStart + $backupRange)
            if ($EnableAzure) {
                if (-not (Validate-SasToken $sas)) {
                    $msg = "Invalid SAS token; skipping Azure upload for $dbName."
                    $errors.Add($msg) | Out-Null
                    Write-Log "ERROR: $msg"
                    $StatusCallback.Invoke($msg)
                    continue
                }
                $StatusCallback.Invoke("Uploading $dbName to Azure...")
                Upload-ToAzure -AzCopyPath $azcopy -BakFile $bakFile -StorageAccount $storageAccount `
                               -Container $siteName -SasToken $sas -DbName $dbName -Timestamp $timestamp `
                               -ProgressStart ($phaseStart + $backupRange) -ProgressRange (45 - $backupRange)
                Update-Progress ($phaseStart + 45)
            }
            else {
                Write-Log "Azure upload disabled — skipping upload for $dbName."
                $StatusCallback.Invoke("Azure upload disabled — skipping $dbName.")
            }
            Update-Progress ($phaseStart + 45)
        }
        catch {
            $msg = "Error backing up ${dbName}: ${_}"
            $errors.Add($msg) | Out-Null
            Write-Log "ERROR: $msg"
            Update-Progress ($phaseStart + 45)
        }
    }
    try {
        $StatusCallback.Invoke("Cleaning retention...")
        Update-Progress 96
        Clean-Retention -BackupPath $backupPath -RetentionDays $localRetentionDays
    }
    catch {
        $msg = "Error during retention cleanup: ${_}"
        $errors.Add($msg) | Out-Null
        Write-Log "ERROR: $msg"
    }
    # Email validation patch
    $missing = @()
    if (-not $emailCfg.SMTPServer -or $emailCfg.SMTPServer.Trim() -eq "") { $missing += "SMTPServer" }
    if (-not $emailCfg.SMTPPort   -or $emailCfg.SMTPPort.Trim()   -eq "") { $missing += "SMTPPort" }
    if (-not $emailCfg.SMTPUser   -or $emailCfg.SMTPUser.Trim()   -eq "") { $missing += "SMTPUser" }
    if (-not $emailCfg.SMTPPass   -or $emailCfg.SMTPPass.Trim()   -eq "") { $missing += "SMTPPass" }
    if (-not $emailCfg.EmailTo    -or $emailCfg.EmailTo.Trim()    -eq "") { $missing += "EmailTo" }
    if (-not $emailCfg.EmailFrom  -or $emailCfg.EmailFrom.Trim()  -eq "") { $missing += "EmailFrom" }
    if ($missing.Count -gt 0) {
        $msg = "Email skipped — missing fields: " + ($missing -join ", ")
        Write-Log $msg
        $StatusCallback.Invoke($msg)
    }
    else {
        $StatusCallback.Invoke("Sending email report...")
        Update-Progress 98
        Send-EmailReport -SiteName $siteName -Timestamp $timestamp -Errors $errors `
                         -SmtpServer $emailCfg.SMTPServer `
                         -SmtpPort   ([int]$emailCfg.SMTPPort) `
                         -SmtpUser   $emailCfg.SMTPUser `
                         -SmtpPass   $emailCfg.SMTPPass `
                         -EmailTo    $emailCfg.EmailTo `
                         -EmailFrom  $emailCfg.EmailFrom
    }
    Update-Progress 100
    $StatusCallback.Invoke("Backup completed.")
    Write-Log "Backup completed for site '$siteName' at $(Get-Date)"
    return ($errors.Count -eq 0)
}
# ============================================
# WinForms GUI
# ============================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "ECS Backup Manager"
$form.Size = New-Object System.Drawing.Size(900,650)
$form.StartPosition = "CenterScreen"
if ($IsDark) {
    $form.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
    $form.ForeColor = [System.Drawing.Color]::White
} else {
    $form.BackColor = [System.Drawing.Color]::White
    $form.ForeColor = [System.Drawing.Color]::Black
}
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = [System.Windows.Forms.DockStyle]::Fill
$tabSettings = New-Object System.Windows.Forms.TabPage
$tabSettings.Text = "Settings"
$tabStatus = New-Object System.Windows.Forms.TabPage
$tabStatus.Text = "Backup Status"
$tabLogs = New-Object System.Windows.Forms.TabPage
$tabLogs.Text = "Logs"
$tabEmail = New-Object System.Windows.Forms.TabPage
$tabEmail.Text = "Email Config"
$tabAbout = New-Object System.Windows.Forms.TabPage
$tabAbout.Text = "About"
$tabs.TabPages.AddRange(@($tabSettings,$tabStatus,$tabLogs,$tabEmail,$tabAbout))
$form.Controls.Add($tabs)
# ============================================
# Settings tab
# ============================================
$lblProfile = New-Object System.Windows.Forms.Label
$lblProfile.Text = "Profile (Business):"
$lblProfile.Location = New-Object System.Drawing.Point(20,10)
$lblProfile.Size = New-Object System.Drawing.Size(120,20)
$cmbProfiles = New-Object System.Windows.Forms.ComboBox
$cmbProfiles.Location = New-Object System.Drawing.Point(150,8)
$cmbProfiles.Size = New-Object System.Drawing.Size(200,24)
$cmbProfiles.DropDownStyle = "DropDownList"
$cmbProfiles.Items.Clear()
if (Test-Path $ProfilesDir) {
    Get-ChildItem -Path $ProfilesDir -Filter *.ini | ForEach-Object {
        [void]$cmbProfiles.Items.Add($_.BaseName)
    }
}
$btnLoadProfile = New-Object System.Windows.Forms.Button
$btnLoadProfile.Text = "Load Profile"
$btnLoadProfile.Location = New-Object System.Drawing.Point(360,8)
$btnLoadProfile.Size = New-Object System.Drawing.Size(120,24)
$btnSaveProfile = New-Object System.Windows.Forms.Button
$btnSaveProfile.Text = "Save Profile"
$btnSaveProfile.Location = New-Object System.Drawing.Point(490,8)
$btnSaveProfile.Size = New-Object System.Drawing.Size(120,24)
$btnNewProfile = New-Object System.Windows.Forms.Button
$btnNewProfile.Text = "New Profile"
$btnNewProfile.Location = New-Object System.Drawing.Point(620,8)
$btnNewProfile.Size = New-Object System.Drawing.Size(120,24)
$lblSite = New-Object System.Windows.Forms.Label
$lblSite.Text = "Site (Location):"
$lblSite.Location = New-Object System.Drawing.Point(20,40)
$lblSite.Size = New-Object System.Drawing.Size(120,20)
$cmbSite = New-Object System.Windows.Forms.ComboBox
$cmbSite.Location = New-Object System.Drawing.Point(150,38)
$cmbSite.Size = New-Object System.Drawing.Size(200,24)
$cmbSite.DropDownStyle = "DropDownList"
$cmbSite.Items.Clear()
if (Test-Path $SitesDir) {
    Get-ChildItem -Path $SitesDir -Filter *.ini | ForEach-Object {
        [void]$cmbSite.Items.Add($_.BaseName)
    }
}
$lblBackupPath = New-Object System.Windows.Forms.Label
$lblBackupPath.Text = "Backup Path:"
$lblBackupPath.Location = New-Object System.Drawing.Point(20,80)
$lblBackupPath.Size = New-Object System.Drawing.Size(100,20)
$txtBackupPath = New-Object System.Windows.Forms.TextBox
$txtBackupPath.Location = New-Object System.Drawing.Point(150,78)
$txtBackupPath.Size = New-Object System.Drawing.Size(400,24)
$txtBackupPath.Text = ""
$lblSAS = New-Object System.Windows.Forms.Label
$lblSAS.Text = "SAS Token:"
$lblSAS.Location = New-Object System.Drawing.Point(20,120)
$lblSAS.Size = New-Object System.Drawing.Size(100,20)
$txtSAS = New-Object System.Windows.Forms.TextBox
$txtSAS.Location = New-Object System.Drawing.Point(150,118)
$txtSAS.Size = New-Object System.Drawing.Size(400,24)
$txtSAS.Text = ""
$lblStorage = New-Object System.Windows.Forms.Label
$lblStorage.Text = "Storage Account:"
$lblStorage.Location = New-Object System.Drawing.Point(20,160)
$lblStorage.Size = New-Object System.Drawing.Size(120,20)
$txtStorage = New-Object System.Windows.Forms.TextBox
$txtStorage.Location = New-Object System.Drawing.Point(150,158)
$txtStorage.Size = New-Object System.Drawing.Size(200,24)
$txtStorage.Text = ""
$chkAzureUpload = New-Object System.Windows.Forms.CheckBox
$chkAzureUpload.Text = "Enable Azure Upload"
$chkAzureUpload.Location = New-Object System.Drawing.Point(20,200)
$chkAzureUpload.Size = New-Object System.Drawing.Size(200,24)
$chkAzureUpload.Checked = ($Config.General.AzureUpload -eq "true")
$chkAzureUpload.Add_CheckedChanged({
    if ($chkAzureUpload.Checked) {
        $txtSAS.Enabled     = $true
        $txtStorage.Enabled = $true
    } else {
        $txtSAS.Enabled     = $false
        $txtStorage.Enabled = $false
    }
})
if ($chkAzureUpload.Checked) {
    $txtSAS.Enabled     = $true
    $txtStorage.Enabled = $true
} else {
    $txtSAS.Enabled     = $false
    $txtStorage.Enabled = $false
}
$btnSaveSettings = New-Object System.Windows.Forms.Button
$btnSaveSettings.Text = "Save Settings (default config)"
$btnSaveSettings.Location = New-Object System.Drawing.Point(20,240)
$btnSaveSettings.Size = New-Object System.Drawing.Size(220,30)
$btnCreateSchedule = New-Object System.Windows.Forms.Button
$btnCreateSchedule.Text = "Create Daily Backup Schedule"
$btnCreateSchedule.Location = New-Object System.Drawing.Point(260,240)
$btnCreateSchedule.Size = New-Object System.Drawing.Size(220,30)
$btnSaveSite = New-Object System.Windows.Forms.Button
$btnSaveSite.Text = "Save Site Settings"
$btnSaveSite.Location = New-Object System.Drawing.Point(500,240)
$btnSaveSite.Size = New-Object System.Drawing.Size(150,30)
$btnSaveSettings.Add_Click({
    $Config = Validate-Config ([ref]$Config)
    $Config.General.SiteName       = $cmbSite.SelectedItem
    $Config.General.BackupPath     = $txtBackupPath.Text
    $Config.General.SASToken       = $txtSAS.Text
    $Config.General.StorageAccount = $txtStorage.Text
    if ($chkAzureUpload.Checked) {
        $Config.General.AzureUpload = "true"
    } else {
        $Config.General.AzureUpload = "false"
    }
    Save-Config -Config $Config -Path $ConfigFile
    [System.Windows.Forms.MessageBox]::Show("Default config saved.","ECS Backup Manager")
})
$btnLoadProfile.Add_Click({
    $selected = $cmbProfiles.SelectedItem
    if (-not $selected) { return }
    try {
        $profileConfig = Load-Profile $selected
        $Global:ActiveProfile = $selected
        $Config = Validate-Config ([ref]$Config)
        if ($profileConfig.ContainsKey("Email")) {
            $Config.Email.SMTPServer = $profileConfig.Email.SMTPServer
            $Config.Email.SMTPPort   = $profileConfig.Email.SMTPPort
            $Config.Email.SMTPUser   = $profileConfig.Email.SMTPUser
            $Config.Email.SMTPPass   = $profileConfig.Email.SMTPPass
            $Config.Email.EmailTo    = $profileConfig.Email.EmailTo
            $Config.Email.EmailFrom  = $profileConfig.Email.EmailFrom
            $txtSMTPServer.Text = $Config.Email.SMTPServer
            $txtSMTPPort.Text   = $Config.Email.SMTPPort
            $txtSMTPUser.Text   = $Config.Email.SMTPUser
            $txtSMTPPass.Text   = $Config.Email.SMTPPass
            $txtEmailTo.Text    = $Config.Email.EmailTo
            $txtEmailFrom.Text  = $Config.Email.EmailFrom
        }
        [System.Windows.Forms.MessageBox]::Show("Business profile '$selected' loaded.")
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_)
    }
})
$btnSaveProfile.Add_Click({
    if (-not $Global:ActiveProfile) {
        [System.Windows.Forms.MessageBox]::Show("No profile loaded.")
        return
    }
    $Config = Validate-Config ([ref]$Config)
    $profileConfig = @{
        Profile = @{
            BusinessName = $Global:ActiveProfile
        }
        Email = @{
            SMTPServer = $Config.Email.SMTPServer
            SMTPPort   = $Config.Email.SMTPPort
            SMTPUser   = $Config.Email.SMTPUser
            SMTPPass   = $Config.Email.SMTPPass
            EmailTo    = $Config.Email.EmailTo
            EmailFrom  = $Config.Email.EmailFrom
        }
    }
    Save-Profile -ProfileName $Global:ActiveProfile -ConfigObject $profileConfig
    [System.Windows.Forms.MessageBox]::Show("Profile '$Global:ActiveProfile' saved.")
})
$btnNewProfile.Add_Click({
    $name = [Microsoft.VisualBasic.Interaction]::InputBox("Enter new business profile name:", "New Profile")
    if ($name -eq "") { return }
    $profilePath = Join-Path $ProfilesDir "$name.ini"
    $newProfileConfig = @{
        Profile = @{
            BusinessName = $name
        }
        Email = @{
            SMTPServer = ""
            SMTPPort   = ""
            SMTPUser   = ""
            SMTPPass   = ""
            EmailTo    = ""
            EmailFrom  = ""
        }
    }
    Save-Config -Config $newProfileConfig -Path $profilePath
    if (-not ($cmbProfiles.Items.Contains($name))) {
        [void]$cmbProfiles.Items.Add($name)
    }
    $cmbProfiles.SelectedItem = $name
    $Global:ActiveProfile = $name
    [System.Windows.Forms.MessageBox]::Show("Business profile '$name' created.")
})
$cmbSite.Add_SelectedIndexChanged({
    $selectedSite = $cmbSite.SelectedItem
    if (-not $selectedSite) { return }
    try {
        $siteConfigPath = Join-Path $SitesDir "$selectedSite.ini"
        $siteConfig = Load-Config $siteConfigPath
        $txtBackupPath.Text = $siteConfig.Site.BackupPath
        $txtSAS.Text        = $siteConfig.Site.SASToken
        $txtStorage.Text    = $siteConfig.Site.StorageAccount
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Error loading site '$selectedSite': $_")
    }
})
$btnSaveSite.Add_Click({
    if (-not $cmbSite.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show("Select a site first.")
        return
    }
    $siteName = $cmbSite.SelectedItem
    $sitePath = Join-Path $SitesDir "$siteName.ini"
    $siteConfig = @{
        Site = @{
            SiteName       = $siteName
            BackupPath     = $txtBackupPath.Text
            SASToken       = $txtSAS.Text
            StorageAccount = $txtStorage.Text
        }
    }
    Save-Config -Config $siteConfig -Path $sitePath
    [System.Windows.Forms.MessageBox]::Show("Site '$siteName' saved successfully.")
})
$btnCreateSchedule.Add_Click({
    $taskName = "ECSBackupManager_DailyBackup"
    $scriptPath = Join-Path $AppRoot "ECSBackupManager.ps1"
    $time = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Enter daily backup time (HH:MM, 24-hour):",
        "Schedule Backup",
        "02:00"
    )
    if ($time -eq "") { return }
    try {
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        $trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($time,"HH:mm",$null))
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Description "Daily ECS backup" -User "SYSTEM" -RunLevel Highest -Force
        [System.Windows.Forms.MessageBox]::Show("Scheduled task '$taskName' created for $time daily.","ECS Backup Manager")
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Error creating scheduled task: $_")
    }
})
$tabSettings.Controls.AddRange(@(
    $lblProfile,$cmbProfiles,
    $btnLoadProfile,$btnSaveProfile,$btnNewProfile,
    $lblSite,$cmbSite,
    $lblBackupPath,$txtBackupPath,
    $lblSAS,$txtSAS,
    $lblStorage,$txtStorage,
    $chkAzureUpload,
    $btnSaveSettings,
    $btnCreateSchedule,
    $btnSaveSite
))
# ============================================
# Backup Status tab
# ============================================
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Status: Idle"
$lblStatus.Location = New-Object System.Drawing.Point(20,20)
$lblStatus.Size = New-Object System.Drawing.Size(400,20)
$btnRunBackup = New-Object System.Windows.Forms.Button
$btnRunBackup.Text = "Run Backup Now"
$btnRunBackup.Location = New-Object System.Drawing.Point(20,60)
$btnRunBackup.Size = New-Object System.Drawing.Size(150,30)
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(20,100)
$progressBar.Size = New-Object System.Drawing.Size(500,25)
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$progressBar.Value = 0
$tabStatus.Controls.AddRange(@($lblStatus,$btnRunBackup,$progressBar))
# ============================================
# Logs tab
# ============================================
$btnClearLog = New-Object System.Windows.Forms.Button
$btnClearLog.Text = "Clear Log"
$btnClearLog.Location = New-Object System.Drawing.Point(20,10)
$btnClearLog.Size = New-Object System.Drawing.Size(120,30)
$txtLogs = New-Object System.Windows.Forms.TextBox
$txtLogs.Multiline = $true
$txtLogs.ScrollBars = "Vertical"
$txtLogs.ReadOnly = $true
$txtLogs.Location = New-Object System.Drawing.Point(20,160)
$txtLogs.Size = New-Object System.Drawing.Size(820,390)
$lblHistory = New-Object System.Windows.Forms.Label
$lblHistory.Text = "Backup History:"
$lblHistory.Location = New-Object System.Drawing.Point(160,10)
$lblHistory.Size = New-Object System.Drawing.Size(120,20)
$listHistory = New-Object System.Windows.Forms.ListBox
$listHistory.Location = New-Object System.Drawing.Point(160,30)
$listHistory.Size = New-Object System.Drawing.Size(250,120)
$tabLogs.Controls.Add($btnClearLog)
$tabLogs.Controls.Add($txtLogs)
$tabLogs.Controls.Add($lblHistory)
$tabLogs.Controls.Add($listHistory)
$btnClearLog.Add_Click({
    try {
        if (Test-Path $LogFile) {
            Clear-Content -Path $LogFile -Force
        }
        $txtLogs.Text = ""
        $listHistory.Items.Clear()
        Write-Log "Log file cleared by user."
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Unable to clear log: $_")
    }
})
function Refresh-History {
    $listHistory.Items.Clear()
    if (Test-Path $LogFile) {
        Get-Content $LogFile | Where-Object { $_ -match "Backup started for site" } | ForEach-Object {
            [void]$listHistory.Items.Add($_)
        }
    }
}
function Refresh-Logs {
    if ($txtLogs.InvokeRequired) {
        $txtLogs.Invoke([Action]{
            if (Test-Path $LogFile) {
                $txtLogs.Text = [System.IO.File]::ReadAllText($LogFile)
            } else {
                $txtLogs.Text = "No log file found at $LogFile"
            }
            Refresh-History
        })
    } else {
        if (Test-Path $LogFile) {
            $txtLogs.Text = [System.IO.File]::ReadAllText($LogFile)
        } else {
            $txtLogs.Text = "No log file found at $LogFile"
        }
        Refresh-History
    }
}
# ============================================
# Email Config tab
# ============================================
$Config = Validate-Config ([ref]$Config)
$lblEmailHeader = New-Object System.Windows.Forms.Label
$lblEmailHeader.Text = "Email Configuration (used for backup reports)"
$lblEmailHeader.Location = New-Object System.Drawing.Point(20,20)
$lblEmailHeader.Size = New-Object System.Drawing.Size(400,20)
$lblSMTPServer = New-Object System.Windows.Forms.Label
$lblSMTPServer.Text = "SMTP Server:"
$lblSMTPServer.Location = New-Object System.Drawing.Point(20,60)
$lblSMTPServer.Size = New-Object System.Drawing.Size(100,20)
$txtSMTPServer = New-Object System.Windows.Forms.TextBox
$txtSMTPServer.Location = New-Object System.Drawing.Point(150,58)
$txtSMTPServer.Size = New-Object System.Drawing.Size(300,24)
$txtSMTPServer.Text = ""
$lblSMTPPort = New-Object System.Windows.Forms.Label
$lblSMTPPort.Text = "SMTP Port:"
$lblSMTPPort.Location = New-Object System.Drawing.Point(20,100)
$lblSMTPPort.Size = New-Object System.Drawing.Size(100,20)
$txtSMTPPort = New-Object System.Windows.Forms.TextBox
$txtSMTPPort.Location = New-Object System.Drawing.Point(150,98)
$txtSMTPPort.Size = New-Object System.Drawing.Size(100,24)
$txtSMTPPort.Text = ""
$lblSMTPUser = New-Object System.Windows.Forms.Label
$lblSMTPUser.Text = "SMTP User:"
$lblSMTPUser.Location = New-Object System.Drawing.Point(20,140)
$lblSMTPUser.Size = New-Object System.Drawing.Size(100,20)
$txtSMTPUser = New-Object System.Windows.Forms.TextBox
$txtSMTPUser.Location = New-Object System.Drawing.Point(150,138)
$txtSMTPUser.Size = New-Object System.Drawing.Size(300,24)
$txtSMTPUser.Text = ""
$lblSMTPPass = New-Object System.Windows.Forms.Label
$lblSMTPPass.Text = "SMTP Password:"
$lblSMTPPass.Location = New-Object System.Drawing.Point(20,180)
$lblSMTPPass.Size = New-Object System.Drawing.Size(100,20)
$txtSMTPPass = New-Object System.Windows.Forms.TextBox
$txtSMTPPass.Location = New-Object System.Drawing.Point(150,178)
$txtSMTPPass.Size = New-Object System.Drawing.Size(300,24)
$txtSMTPPass.Text = ""
$txtSMTPPass.UseSystemPasswordChar = $true
$lblEmailTo = New-Object System.Windows.Forms.Label
$lblEmailTo.Text = "Email To:"
$lblEmailTo.Location = New-Object System.Drawing.Point(20,220)
$lblEmailTo.Size = New-Object System.Drawing.Size(100,20)
$txtEmailTo = New-Object System.Windows.Forms.TextBox
$txtEmailTo.Location = New-Object System.Drawing.Point(150,218)
$txtEmailTo.Size = New-Object System.Drawing.Size(300,24)
$txtEmailTo.Text = ""
$lblEmailFrom = New-Object System.Windows.Forms.Label
$lblEmailFrom.Text = "Email From:"
$lblEmailFrom.Location = New-Object System.Drawing.Point(20,260)
$lblEmailFrom.Size = New-Object System.Drawing.Size(100,20)
$txtEmailFrom = New-Object System.Windows.Forms.TextBox
$txtEmailFrom.Location = New-Object System.Drawing.Point(150,258)
$txtEmailFrom.Size = New-Object System.Drawing.Size(300,24)
$txtEmailFrom.Text = ""
$btnSaveEmail = New-Object System.Windows.Forms.Button
$btnSaveEmail.Text = "Save Email Settings"
$btnSaveEmail.Location = New-Object System.Drawing.Point(20,300)
$btnSaveEmail.Size = New-Object System.Drawing.Size(160,30)
$btnTestEmail = New-Object System.Windows.Forms.Button
$btnTestEmail.Text = "Send Test Email"
$btnTestEmail.Location = New-Object System.Drawing.Point(190,300)
$btnTestEmail.Size = New-Object System.Drawing.Size(160,30)
function Validate-EmailGuiFields {
    $controls = @(
        @{Box=$txtSMTPServer; Name="SMTP Server"},
        @{Box=$txtSMTPPort;   Name="SMTP Port"},
        @{Box=$txtSMTPUser;   Name="SMTP User"},
        @{Box=$txtSMTPPass;   Name="SMTP Password"},
        @{Box=$txtEmailTo;    Name="Email To"},
        @{Box=$txtEmailFrom;  Name="Email From"}
    )
    $missingNames = @()
    foreach ($c in $controls) {
        if (-not $c.Box.Text -or $c.Box.Text.Trim() -eq "") {
            $c.Box.BackColor = [System.Drawing.Color]::LightPink
            $missingNames += $c.Name
        } else {
            $c.Box.BackColor = [System.Drawing.Color]::White
        }
    }
    return $missingNames
}
$btnSaveEmail.Add_Click({
    $missing = Validate-EmailGuiFields
    if ($missing.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Cannot save email settings. Missing: " + ($missing -join ", "),
            "Email Validation"
        )
        return
    }
    $Config = Validate-Config ([ref]$Config)
    $Config.Email.SMTPServer = $txtSMTPServer.Text
    $Config.Email.SMTPPort   = $txtSMTPPort.Text
    $Config.Email.SMTPUser   = $txtSMTPUser.Text
    $Config.Email.SMTPPass   = $txtSMTPPass.Text
    $Config.Email.EmailTo    = $txtEmailTo.Text
    $Config.Email.EmailFrom  = $txtEmailFrom.Text
    Save-Config -Config $Config -Path $ConfigFile
    [System.Windows.Forms.MessageBox]::Show("Email settings saved.","ECS Backup Manager")
})
$btnTestEmail.Add_Click({
    $missing = Validate-EmailGuiFields
    if ($missing.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Cannot send test email. Missing: " + ($missing -join ", "),
            "Email Validation"
        )
        return
    }
    try {
        $securePass = ConvertTo-SecureString $txtSMTPPass.Text -AsPlainText -Force
        $cred       = New-Object System.Management.Automation.PSCredential($txtSMTPUser.Text, $securePass)
        Send-MailMessage -To $txtEmailTo.Text -From $txtEmailFrom.Text `
            -Subject "ECS Backup Manager Test Email" `
            -Body "This is a test email from ECS Backup Manager." `
            -SmtpServer $txtSMTPServer.Text -Port ([int]$txtSMTPPort.Text) -UseSsl -Credential $cred
        [System.Windows.Forms.MessageBox]::Show("Test email sent.","ECS Backup Manager")
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Error sending test email: $_")
    }
})
$tabEmail.Controls.AddRange(@(
    $lblEmailHeader,
    $lblSMTPServer,$txtSMTPServer,
    $lblSMTPPort,$txtSMTPPort,
    $lblSMTPUser,$txtSMTPUser,
    $lblSMTPPass,$txtSMTPPass,
    $lblEmailTo,$txtEmailTo,
    $lblEmailFrom,$txtEmailFrom,
    $btnSaveEmail,$btnTestEmail
))
# ============================================
# About tab
# ============================================
$lblAbout = New-Object System.Windows.Forms.Label
$lblAbout.Text = "ECS Backup Manager`nProduction-safe: no auto-created configs or site files.`nUser must create profiles and site INI files.`nSQL progress + Azure progress + scheduler + history + site saving."
$lblAbout.Location = New-Object System.Drawing.Point(20,20)
$lblAbout.Size = New-Object System.Drawing.Size(500,140)
$tabAbout.Controls.Add($lblAbout)
# ============================================
# Tray icon
# ============================================
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Information
$tray.Visible = $true
$tray.Text = "ECS Backup Manager"
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $trayMenu.Items.Add("Open")
$miExit = $trayMenu.Items.Add("Exit")
$miOpen.Add_Click({ $form.Show(); $form.WindowState = "Normal" })
$miExit.Add_Click({
    $tray.Visible = $false
    $form.Close()
})
$tray.ContextMenuStrip = $trayMenu
$form.Add_Resize({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $form.Hide()
        $tray.ShowBalloonTip(1000,"ECS Backup Manager","Still running in tray.",[System.Windows.Forms.ToolTipIcon]::Info)
    }
})
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:backupPowerShell) {
        $eventArgs.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show(
            "Wait for the backup to finish before closing ECS Backup Manager.",
            "Backup in Progress"
        )
        return
    }
    $tray.Visible = $false
})
# ============================================
# Backup button wiring
# ============================================
$script:backupPowerShell = $null
$script:backupAsyncResult = $null
$script:backupProgressState = $null
$script:backupTimer = New-Object System.Windows.Forms.Timer
$script:backupTimer.Interval = 200
$script:backupTimer.Add_Tick({
    if ($script:backupProgressState.Status -ne $script:lastBackupStatus) {
        $script:lastBackupStatus = $script:backupProgressState.Status
        Update-Status $script:lastBackupStatus
    }
    if ($script:backupProgressState.Progress -ne $script:lastBackupProgress) {
        $script:lastBackupProgress = $script:backupProgressState.Progress
        Update-Progress $script:lastBackupProgress
    }
    if (-not $script:backupAsyncResult.IsCompleted) { return }

    $script:backupTimer.Stop()
    $success = $false
    try {
        $workerOutput = $script:backupPowerShell.EndInvoke($script:backupAsyncResult)
        if ($workerOutput.Count -gt 0) {
            $success = [bool]$workerOutput[$workerOutput.Count - 1]
        }
        if ($script:backupPowerShell.Streams.Error.Count -gt 0) {
            throw ($script:backupPowerShell.Streams.Error -join [Environment]::NewLine)
        }
    }
    catch {
        Update-Status "Backup failed."
        Write-Log "Backup failed: $_"
        Refresh-Logs
        $tray.ShowBalloonTip(1500,"Backup Failed","Errors occurred during backup.",[System.Windows.Forms.ToolTipIcon]::Error)
        $success = $null
    }
    finally {
        $runspace = $script:backupPowerShell.Runspace
        $script:backupPowerShell.Dispose()
        $runspace.Dispose()
        $script:backupPowerShell = $null
        $script:backupAsyncResult = $null
        $script:backupProgressState = $null
        $btnRunBackup.Enabled = $true
        $btnRunBackup.Text = "Run Backup Now"
    }
    if ($null -eq $success) { return }

    Refresh-Logs
    if ($success) {
        Update-Status "Backup completed successfully."
        $tray.ShowBalloonTip(1500,"Backup Complete","All backup tasks finished.",[System.Windows.Forms.ToolTipIcon]::Info)
    } else {
        Update-Status "Backup completed with errors."
        $tray.ShowBalloonTip(1500,"Backup Completed with Errors","Review the log for details.",[System.Windows.Forms.ToolTipIcon]::Warning)
    }
})
$btnRunBackup.Add_Click({
    $selectedSite = $cmbSite.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($selectedSite)) {
        [System.Windows.Forms.MessageBox]::Show("Select a Site (Location) before running backup.")
        return
    }
    $missingEmail = Validate-EmailGuiFields
    if ($missingEmail.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Email config incomplete. Missing: " + ($missingEmail -join ", "),
            "Email Validation"
        )
        # Continue backup without email, or abort; here we continue.
    }
    Update-Status "Starting backup..."
    Update-Progress 0
    try {
        Write-Log "Backup triggered from GUI for site '$selectedSite'."
        if (Test-Path $ConfigFile) {
            $Config = Load-Config $ConfigFile
        }
        $Config = Validate-Config ([ref]$Config)
        $Config.General.SiteName       = $selectedSite
        $Config.General.BackupPath     = $txtBackupPath.Text
        $Config.General.SASToken       = $txtSAS.Text
        $Config.General.StorageAccount = $txtStorage.Text
        if ($chkAzureUpload.Checked) {
            $Config.General.AzureUpload = "true"
        } else {
            $Config.General.AzureUpload = "false"
        }
        $Config.Email.SMTPServer = $txtSMTPServer.Text
        $Config.Email.SMTPPort   = $txtSMTPPort.Text
        $Config.Email.SMTPUser   = $txtSMTPUser.Text
        $Config.Email.SMTPPass   = $txtSMTPPass.Text
        $Config.Email.EmailTo    = $txtEmailTo.Text
        $Config.Email.EmailFrom  = $txtEmailFrom.Text
        $workerArgs = @{
            Config = $Config
            EnableAzure = [bool]$chkAzureUpload.Checked
        }
        $functionNames = @(
            "Write-Log", "Load-Config", "Validate-Config", "Validate-SasToken",
            "Get-SqlCmdPath", "Get-AzCopyPath", "Backup-Database",
            "Upload-ToAzure", "Clean-Retention", "Send-EmailReport", "Start-Backup"
        )
        $functionDefinitions = foreach ($functionName in $functionNames) {
            $functionBody = (Get-Command $functionName -CommandType Function).ScriptBlock.ToString()
            "function $functionName {`n$functionBody`n}"
        }
        $workerScript = @"
param(`$Config, `$EnableAzure)
function Update-Progress {
    param([int]`$Value)
    if (`$Value -lt 0) { `$Value = 0 }
    if (`$Value -gt 100) { `$Value = 100 }
    `$BackupProgressState.Progress = `$Value
}
function Update-Status {
    param([string]`$Message)
    `$BackupProgressState.Status = `$Message
}
$($functionDefinitions -join "`n")
`$result = Start-Backup -Config `$Config `
    -StatusCallback { param(`$message) Update-Status `$message } `
    -SelectedSite `$Config.General.SiteName -EnableAzure `$EnableAzure
return `$result
"@
        $script:backupProgressState = [hashtable]::Synchronized(@{
            Status = "Starting backup..."
            Progress = 0
        })
        $script:lastBackupStatus = $null
        $script:lastBackupProgress = -1
        $script:backupPowerShell = [powershell]::Create()
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.Open()
        foreach ($variableName in @("AppRoot", "ProfilesDir", "SitesDir", "LogDir", "LogFile")) {
            $runspace.SessionStateProxy.SetVariable($variableName, (Get-Variable $variableName -ValueOnly))
        }
        $runspace.SessionStateProxy.SetVariable("BackupProgressState", $script:backupProgressState)
        $script:backupPowerShell.Runspace = $runspace
        [void]$script:backupPowerShell.AddScript($workerScript)
        [void]$script:backupPowerShell.AddArgument($workerArgs.Config)
        [void]$script:backupPowerShell.AddArgument($workerArgs.EnableAzure)
        $btnRunBackup.Enabled = $false
        $btnRunBackup.Text = "Backup Running..."
        Update-Status "Running backup..."
        $script:backupAsyncResult = $script:backupPowerShell.BeginInvoke()
        $script:backupTimer.Start()
    }
    catch {
        if ($script:backupPowerShell) {
            $runspace = $script:backupPowerShell.Runspace
            $script:backupPowerShell.Dispose()
            if ($runspace) { $runspace.Dispose() }
            $script:backupPowerShell = $null
            $script:backupAsyncResult = $null
            $script:backupProgressState = $null
            $script:backupTimer.Stop()
        }
        $btnRunBackup.Enabled = $true
        $btnRunBackup.Text = "Run Backup Now"
        Update-Status "Backup failed."
        Write-Log "Backup failed: $_"
        Refresh-Logs
        $tray.ShowBalloonTip(1500,"Backup Failed","Errors occurred during backup.",[System.Windows.Forms.ToolTipIcon]::Error)
    }
})
Refresh-Logs
[void]$form.ShowDialog()
