#requires -RunAsAdministrator

[CmdletBinding()]
param(

    [switch]$Resume,
    [switch]$Silent,

    [switch]$InstallAll,

    [switch]$Chrome,
    [switch]$Firefox,
    [switch]$M365,
    [switch]$Teams,
    [switch]$Adobe,
    [switch]$NetExtender,

    [switch]$DellUpdate,
    [switch]$WindowsUpdate,

    [string]$LocalAdminName,
    [string]$LocalAdminPassword,

    [string]$ComputerName,

    [string]$DomainName,
    [string]$DomainUser,
    [string]$DomainPassword,

    [switch]$EntraJoin
)

# ------------------------------------------------------------
# VARIABLES GLOBALES
# ------------------------------------------------------------

$RootFolder = "C:\AuditDeploy"
$LogFile = Join-Path $RootFolder "Deploy.log"
$StateFile = Join-Path $RootFolder "State.json"

$ResumeTaskName = "AuditDeployResume"
$DellPackageId = "Dell.CommandUpdate"

$PendingReboot = $false
$ErrorCount = 0

$DeploymentSteps = @(
    "Applications",
    "Dell",
    "WindowsUpdate",
    "LocalAdmin",
    "Rename",
    "Join",
    "PostConfig",
    "Cleanup"
)

# ------------------------------------------------------------
# CATALOGUE APPLICATIONS
# ------------------------------------------------------------

$Packages = [ordered]@{
    "Google Chrome"         = "Google.Chrome"
    "Firefox"               = "Mozilla.Firefox"
    "Microsoft 365 Apps"    = "Microsoft.Office"
    "Teams"                 = "Microsoft.Teams"
    "Adobe Creative Cloud"  = "Adobe.CreativeCloud"
    "SonicWall NetExtender" = "SonicWall.NetExtender"
}

# ------------------------------------------------------------
# DOSSIERS
# ------------------------------------------------------------

if (-not (Test-Path $RootFolder)) {

    New-Item `
        -Path $RootFolder `
        -ItemType Directory `
        -Force | Out-Null
}

# ------------------------------------------------------------
# LOGGING
# ------------------------------------------------------------

function Write-Log {

    param(

        [ValidateSet(
            "INFO",
            "OK",
            "WARNING",
            "ERROR"
        )]
        [string]$Level,

        [string]$Message
    )

    if ($Level -eq "ERROR") {
        $script:ErrorCount++
    }

    $Line = "[{0}] {1}" -f $Level, $Message

    Write-Host $Line

    Add-Content `
        -Path $LogFile `
        -Value $Line
}

# ------------------------------------------------------------
# PROGRESSION
# ------------------------------------------------------------

function Update-GlobalProgress {

    param(
        [string]$CurrentStep
    )

    $Index =
        $DeploymentSteps.IndexOf(
            $CurrentStep
        ) + 1

    $Percent =
        :Round(
            ($Index / $DeploymentSteps.Count) * 100
        )

    Write-Progress `
        -Activity "Audit Deploy" `
        -Status $CurrentStep `
        -PercentComplete $Percent
}

# ------------------------------------------------------------
# ETAT
# ------------------------------------------------------------

function Save-State {

    param(
        [hashtable]$Config,
        [string]$NextStep
    )

    $State = @{
        NextStep = $NextStep
        Config = $Config
    }

    $State |
        ConvertTo-Json -Depth 20 |
        Set-Content $StateFile
}

function Load-State {

    if (-not (Test-Path $StateFile)) {
        return $null
    }

    try {

        return (
            Get-Content `
                $StateFile `
                -Raw |
            ConvertFrom-Json
        )
    }
    catch {

        Write-Log ERROR "Lecture State.json impossible"
        return $null
    }
}

function Clear-State {

    if (Test-Path $StateFile) {

        Remove-Item `
            $StateFile `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------
# REBOOT
# ------------------------------------------------------------

function Test-PendingReboot {

    $Keys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    )

    foreach ($Key in $Keys) {

        if (Test-Path $Key) {
            return $true
        }
    }

    return $false
}

function Invoke-Reboot {

    param(
        [hashtable]$Config,
        [string]$NextStep
    )

    Write-Log INFO "Redemarrage requis"

    Save-State `
        -Config $Config `
        -NextStep $NextStep

    $Action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-ExecutionPolicy Bypass -File `"$PSCommandPath`" -Resume"

    $Trigger =
        New-ScheduledTaskTrigger `
            -AtLogOn

    Register-ScheduledTask `
        -TaskName $ResumeTaskName `
        -Action $Action `
        -Trigger $Trigger `
        -Force | Out-Null

    Restart-Computer -Force
}

function Remove-ResumeTask {

    Unregister-ScheduledTask `
        -TaskName $ResumeTaskName `
        -Confirm:$false `
        -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------
# PRE REQUIS
# ------------------------------------------------------------

function Initialize-Environment {

    Write-Log INFO "Demarrage"

    try {

        Get-Command winget `
            -ErrorAction Stop | Out-Null

        Write-Log OK "Winget detecte"
    }
    catch {

        Write-Log ERROR "Winget absent"
        throw
    }

    try {

        $Connected =
            Test-NetConnection `
                -ComputerName "8.8.8.8" `
                -Port 53 `
                -InformationLevel Quiet

        if ($Connected) {

            Write-Log OK "Internet disponible"
        }
        else {

            Write-Log WARNING "Internet non valide"
        }
    }
    catch {

        Write-Log WARNING "Verification Internet impossible"
    }
}

# ------------------------------------------------------------
# CONFIGURATION CLI
# ------------------------------------------------------------

function New-Configuration {

    if (-not $Silent) {
        return $null
    }

    $Config = @{
        Applications  = @()

        DellUpdate    = $DellUpdate
        WindowsUpdate = $WindowsUpdate

        LocalAdminName = $LocalAdminName
        LocalAdminPass = $LocalAdminPassword

        ComputerName = $ComputerName

        DomainName = $DomainName
        DomainUser = $DomainUser
        DomainPass = $DomainPassword

        EntraJoin = $EntraJoin
    }

    if ($InstallAll) {

        $Config.Applications =
            @($Packages.Keys)
    }
    else {

        if ($Chrome) {
            $Config.Applications += "Google Chrome"
        }

        if ($Firefox) {
            $Config.Applications += "Firefox"
        }

        if ($M365) {
            $Config.Applications += "Microsoft 365 Apps"
        }

        if ($Teams) {
            $Config.Applications += "Teams"
        }

        if ($Adobe) {
            $Config.Applications += "Adobe Creative Cloud"
        }

        if ($NetExtender) {
            $Config.Applications += "SonicWall NetExtender"
        }
    }

    return $Config
}

# ------------------------------------------------------------
# GUI
# ------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-GUI {

    $Form = New-Object System.Windows.Forms.Form
    $Form.Text = "Audit Deploy"
    $Form.Size = New-Object System.Drawing.Size(700,650)
    $Form.StartPosition = "CenterScreen"
    $Form.MaximizeBox = $false
    $Form.FormBorderStyle = "FixedDialog"

    # --------------------------------------------------------
    # Applications
    # --------------------------------------------------------

    $GrpApps = New-Object System.Windows.Forms.GroupBox
    $GrpApps.Text = "Applications"
    $GrpApps.Location = New-Object System.Drawing.Point(10,10)
    $GrpApps.Size = New-Object System.Drawing.Size(320,250)

    $LstApps = New-Object System.Windows.Forms.CheckedListBox
    $LstApps.Location = New-Object System.Drawing.Point(10,20)
    $LstApps.Size = New-Object System.Drawing.Size(290,210)
    $LstApps.CheckOnClick = $true

    foreach ($App in $Packages.Keys) {
        [void]$LstApps.Items.Add($App,$true)
    }

    $GrpApps.Controls.Add($LstApps)

    # --------------------------------------------------------
    # UPDATES
    # --------------------------------------------------------

    $GrpUpdates = New-Object System.Windows.Forms.GroupBox
    $GrpUpdates.Text = "Mises a jour"
    $GrpUpdates.Location = New-Object System.Drawing.Point(350,10)
    $GrpUpdates.Size = New-Object System.Drawing.Size(320,100)

    $ChkDell = New-Object System.Windows.Forms.CheckBox
    $ChkDell.Text = "Dell Update"
    $ChkDell.Location = New-Object System.Drawing.Point(15,25)
    $ChkDell.Checked = $true

    $ChkWU = New-Object System.Windows.Forms.CheckBox
    $ChkWU.Text = "Windows Update"
    $ChkWU.Location = New-Object System.Drawing.Point(15,55)
    $ChkWU.Checked = $true

    $GrpUpdates.Controls.AddRange(@(
        $ChkDell,
        $ChkWU
    ))

    # --------------------------------------------------------
    # ADMIN LOCAL
    # --------------------------------------------------------

    $GrpAdmin = New-Object System.Windows.Forms.GroupBox
    $GrpAdmin.Text = "Administrateur local"
    $GrpAdmin.Location = New-Object System.Drawing.Point(350,130)
    $GrpAdmin.Size = New-Object System.Drawing.Size(320,130)

    $LblAdminName = New-Object System.Windows.Forms.Label
    $LblAdminName.Text = "Nom"
    $LblAdminName.Location = New-Object System.Drawing.Point(10,35)

    $TxtAdminName = New-Object System.Windows.Forms.TextBox
    $TxtAdminName.Location = New-Object System.Drawing.Point(100,30)
    $TxtAdminName.Width = 190

    $LblAdminPass = New-Object System.Windows.Forms.Label
    $LblAdminPass.Text = "Mot de passe"
    $LblAdminPass.Location = New-Object System.Drawing.Point(10,75)

    $TxtAdminPass = New-Object System.Windows.Forms.TextBox
    $TxtAdminPass.Location = New-Object System.Drawing.Point(100,70)
    $TxtAdminPass.Width = 190

    $GrpAdmin.Controls.AddRange(@(
        $LblAdminName,
        $TxtAdminName,
        $LblAdminPass,
        $TxtAdminPass
    ))

    # --------------------------------------------------------
    # CONFIGURATION MACHINE
    # --------------------------------------------------------

    $GrpMachine = New-Object System.Windows.Forms.GroupBox
    $GrpMachine.Text = "Configuration machine"
    $GrpMachine.Location = New-Object System.Drawing.Point(10,280)
    $GrpMachine.Size = New-Object System.Drawing.Size(660,230)

    # Nom PC

    $LblComputer = New-Object System.Windows.Forms.Label
    $LblComputer.Text = "Nom du poste"
    $LblComputer.Location = New-Object System.Drawing.Point(10,30)

    $TxtComputer = New-Object System.Windows.Forms.TextBox
    $TxtComputer.Location = New-Object System.Drawing.Point(130,25)
    $TxtComputer.Width = 250

    # Domaine

    $LblDomain = New-Object System.Windows.Forms.Label
    $LblDomain.Text = "Domaine"
    $LblDomain.Location = New-Object System.Drawing.Point(10,70)

    $TxtDomain = New-Object System.Windows.Forms.TextBox
    $TxtDomain.Location = New-Object System.Drawing.Point(130,65)
    $TxtDomain.Width = 250

    # Compte

    $LblDomainUser = New-Object System.Windows.Forms.Label
    $LblDomainUser.Text = "Compte"
    $LblDomainUser.Location = New-Object System.Drawing.Point(10,110)

    $TxtDomainUser = New-Object System.Windows.Forms.TextBox
    $TxtDomainUser.Location = New-Object System.Drawing.Point(130,105)
    $TxtDomainUser.Width = 250

    # Password

    $LblDomainPass = New-Object System.Windows.Forms.Label
    $LblDomainPass.Text = "Mot de passe"
    $LblDomainPass.Location = New-Object System.Drawing.Point(10,150)

    $TxtDomainPass = New-Object System.Windows.Forms.TextBox
    $TxtDomainPass.Location = New-Object System.Drawing.Point(130,145)
    $TxtDomainPass.Width = 250

    # Entra

    $ChkEntra = New-Object System.Windows.Forms.CheckBox
    $ChkEntra.Text = "Joindre Microsoft Entra ID"
    $ChkEntra.Location = New-Object System.Drawing.Point(10,190)

    $GrpMachine.Controls.AddRange(@(
        $LblComputer,
        $TxtComputer,
        $LblDomain,
        $TxtDomain,
        $LblDomainUser,
        $TxtDomainUser,
        $LblDomainPass,
        $TxtDomainPass,
        $ChkEntra
    ))

    # --------------------------------------------------------
    # BOUTONS
    # --------------------------------------------------------

    $BtnStart = New-Object System.Windows.Forms.Button
    $BtnStart.Text = "Lancer"
    $BtnStart.Location = New-Object System.Drawing.Point(500,560)
    $BtnStart.Width = 80

    $BtnQuit = New-Object System.Windows.Forms.Button
    $BtnQuit.Text = "Quitter"
    $BtnQuit.Location = New-Object System.Drawing.Point(590,560)
    $BtnQuit.Width = 80

    # --------------------------------------------------------
    # VALIDATION
    # --------------------------------------------------------

    $BtnStart.Add_Click({

        # Validation Admin Local

        if (
            -not :IsNullOrWhiteSpace($TxtAdminPass.Text) -and
            :IsNullOrWhiteSpace($TxtAdminName.Text)
        ) {

            [System.Windows.Forms.MessageBox]::Show(
                "Renseignez un nom pour l'administrateur local."
            )

            return
        }

        # Validation AD

        if (
            -not :IsNullOrWhiteSpace($TxtDomain.Text) -and
            (
                :IsNullOrWhiteSpace($TxtDomainUser.Text) -or
                :IsNullOrWhiteSpace($TxtDomainPass.Text)
            )
        ) {

            [System.Windows.Forms.MessageBox]::Show(
                "Informations de domaine incomplètes."
            )

            return
        }

        # Validation nom machine

        if (
            $TxtComputer.Text.Length -gt 15
        ) {

            [System.Windows.Forms.MessageBox]::Show(
                "Le nom du poste ne doit pas dépasser 15 caractères."
            )

            return
        }

        $SelectedApps = @()

        foreach ($Item in $LstApps.CheckedItems) {
            $SelectedApps += $Item.ToString()
        }

        $Form.Tag = @{
            Applications = $SelectedApps

            DellUpdate = $ChkDell.Checked
            WindowsUpdate = $ChkWU.Checked

            LocalAdminName = $TxtAdminName.Text.Trim()
            LocalAdminPass = $TxtAdminPass.Text

            ComputerName = $TxtComputer.Text.Trim()

            DomainName = $TxtDomain.Text.Trim()
            DomainUser = $TxtDomainUser.Text.Trim()
            DomainPass = $TxtDomainPass.Text

            EntraJoin = $ChkEntra.Checked
        }

        $Form.Close()
    })

    $BtnQuit.Add_Click({
        $Form.Close()
    })

    # --------------------------------------------------------
    # CONTROLS
    # --------------------------------------------------------

    $Form.Controls.AddRange(@(
        $GrpApps,
        $GrpUpdates,
        $GrpAdmin,
        $GrpMachine,
        $BtnStart,
        $BtnQuit
    ))

    [void]$Form.ShowDialog()

    return $Form.Tag
}

# ------------------------------------------------------------
# APPLICATIONS
# ------------------------------------------------------------

function Install-WingetPackage {

    param(
        [string]$Name,
        [string]$PackageId
    )

    Write-Log INFO "Installation : $Name"

    try {

        winget install `
            --id $PackageId `
            --exact `
            --accept-package-agreements `
            --accept-source-agreements `
            --silent

        if ($LASTEXITCODE -eq 0) {

            Write-Log OK $Name

            if (Test-PendingReboot) {
                $script:PendingReboot = $true
            }

            return $true
        }

        Write-Log ERROR "$Name installation échouée"
        return $false
    }
    catch {

        Write-Log ERROR "$Name installation échouée"
        return $false
    }
}

function Install-Applications {

    param(
        [hashtable]$Config
    )

    Update-GlobalProgress "Applications"

    if ($Config.Applications.Count -eq 0) {

        Write-Log INFO "Aucune application sélectionnée"
        return
    }

    $Index = 0
    $Total = $Config.Applications.Count

    foreach ($Application in $Config.Applications) {

        $Index++

        Write-Progress `
            -Activity "Applications" `
            -Status $Application `
            -PercentComplete (:Round(($Index / $Total) * 100))

        Install-WingetPackage `
            -Name $Application `
            -PackageId $Packages[$Application]
    }

    Write-Progress `
        -Activity "Applications" `
        -Completed
}

# ------------------------------------------------------------
# DELL
# ------------------------------------------------------------

function Test-Dell {

    try {

        $Manufacturer =
            (Get-CimInstance Win32_ComputerSystem).Manufacturer

        return ($Manufacturer -match "Dell")
    }
    catch {

        return $false
    }
}

function Get-DellCommandUpdate {

    $Candidates = @(
        "C:\Program Files\Dell\CommandUpdate\dcu-cli.exe",
        "C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe"
    )

    foreach ($Path in $Candidates) {

        if (Test-Path $Path) {
            return $Path
        }
    }

    $Cmd = Get-Command `
        dcu-cli.exe `
        -ErrorAction SilentlyContinue

    if ($Cmd) {
        return $Cmd.Source
    }

    return $null
}

function Invoke-DellUpdate {

    param(
        [hashtable]$Config
    )

    Update-GlobalProgress "Dell"

    if (-not $Config.DellUpdate) {

        Write-Log INFO "Dell Update désactivé"
        return
    }

    if (-not (Test-Dell)) {

        Write-Log INFO "Machine non Dell"
        return
    }

    Write-Log INFO "Machine Dell détectée"

    $DcuCli = Get-DellCommandUpdate

    if (-not $DcuCli) {

        Write-Log INFO "Installation Dell Command Update"

        Install-WingetPackage `
            -Name "Dell Command Update" `
            -PackageId $DellPackageId

        $DcuCli = Get-DellCommandUpdate
    }

    if (-not $DcuCli) {

        Write-Log ERROR "Dell Command Update introuvable"
        return
    }

    Write-Log INFO "Scan Dell"

    & $DcuCli /scan -silent

    Write-Log INFO "Installation mises à jour Dell"

    & $DcuCli /applyUpdates -silent

    $ExitCode = $LASTEXITCODE

    switch ($ExitCode) {

        0 {

            Write-Log OK "Dell Update terminé"
        }

        default {

            Write-Log INFO "Redémarrage Dell requis"
            $script:PendingReboot = $true
        }
    }

    if (Test-PendingReboot) {
        $script:PendingReboot = $true
    }
}# ------------------------------------------------------------
# WINDOWS UPDATE
# ------------------------------------------------------------

function Invoke-WindowsUpdate {

    param(
        [hashtable]$Config
    )

    Update-GlobalProgress "WindowsUpdate"

    if (-not $Config.WindowsUpdate) {

        Write-Log INFO "Windows Update désactivé"
        return
    }

    Write-Log INFO "Windows Update"

    try {

        [Net.ServicePointManager]::SecurityProtocol =
            [Net.SecurityProtocolType]::Tls12

        if (-not (
            Get-PackageProvider `
                -Name NuGet `
                -ErrorAction SilentlyContinue
        )) {

            Install-PackageProvider `
                -Name NuGet `
                -Force | Out-Null
        }

        if (-not (
            Get-Module `
                PSWindowsUpdate `
                -ListAvailable
        )) {

            Install-Module `
                PSWindowsUpdate `
                -Force `
                -Scope AllUsers `
                -Confirm:$false
        }

        Import-Module `
            PSWindowsUpdate `
            -Force

        Get-WindowsUpdate `
            -Install `
            -AcceptAll `
            -IgnoreReboot

        if (Test-PendingReboot) {
            $script:PendingReboot = $true
        }

        Write-Log OK "Windows Update terminé"
    }
    catch {

        Write-Log ERROR "Windows Update échoué"
    }
}
# ------------------------------------------------------------
# ADMIN LOCAL
# ------------------------------------------------------------

function Configure-LocalAdmin {

    param(
        [hashtable]$Config
    )

    Update-GlobalProgress "LocalAdmin"

    if (:IsNullOrWhiteSpace(
        $Config.LocalAdminName
    )) {

        Write-Log INFO "Pas d'administrateur local demandé"
        return
    }

    try {

        if (
            Get-LocalUser `
                -Name $Config.LocalAdminName `
                -ErrorAction SilentlyContinue
        ) {

            Write-Log INFO "Administrateur local déjà présent"
            return
        }

        $Password =
            ConvertTo-SecureString `
                $Config.LocalAdminPass `
                -AsPlainText `
                -Force

        New-LocalUser `
            -Name $Config.LocalAdminName `
            -Password $Password `
            -PasswordNeverExpires `
            -AccountNeverExpires

        Add-LocalGroupMember `
            -Group "Administrators" `
            -Member $Config.LocalAdminName

        Write-Log OK "Administrateur local créé"
    }
    catch {

        Write-Log ERROR "Création administrateur local"
    }
}

# ------------------------------------------------------------
# RENOMMAGE
# ------------------------------------------------------------

function Configure-ComputerName {

    param(
        [hashtable]$Config
    )

    Update-GlobalProgress "Rename"

    if (:IsNullOrWhiteSpace(
        $Config.ComputerName
    )) {

        Write-Log INFO "Pas de renommage demandé"
        return
    }

    try {

        if ($env:COMPUTERNAME -eq $Config.ComputerName) {

            Write-Log INFO "Nom déjà conforme"
            return
        }

        Rename-Computer `
            -NewName $Config.ComputerName `
            -Force

        $script:PendingReboot = $true

        Write-Log OK "Renommage programmé"
    }
    catch {

        Write-Log ERROR "Renommage"
    }
}

# ------------------------------------------------------------
# ACTIVE DIRECTORY
# ------------------------------------------------------------

function Configure-DomainJoin {

    param(
        [hashtable]$Config
    )

    if (:IsNullOrWhiteSpace(
        $Config.DomainName
    )) {

        Write-Log INFO "Pas de jointure domaine"
        return
    }

    try {

        $SecurePassword =
            ConvertTo-SecureString `
                $Config.DomainPass `
                -AsPlainText `
                -Force

        $Credential =
            New-Object `
                System.Management.Automation.PSCredential(
                    $Config.DomainUser,
                    $SecurePassword
                )

        Add-Computer `
            -DomainName $Config.DomainName `
            -Credential $Credential `
            -Force

        $script:PendingReboot = $true

        Write-Log OK "Jointure domaine programmée"
    }
    catch {

        Write-Log ERROR "Jointure domaine"
    }
}

# ------------------------------------------------------------
# ENTRA
# ------------------------------------------------------------

function Configure-EntraJoin {

    param(
        [hashtable]$Config
    )

    if (-not $Config.EntraJoin) {
        return
    }

    try {

        Start-Process "ms-settings:workplace"

        Write-Log OK "Assistant Entra lancé"
    }
    catch {

        Write-Log ERROR "Lancement assistant Entra"
    }
}

# ------------------------------------------------------------
# ETAPE JOIN
# ------------------------------------------------------------

function Invoke-JoinStep {

    param(
        [hashtable]$Config
    )

    Update-GlobalProgress "Join"

    Configure-DomainJoin $Config
    Configure-EntraJoin $Config
}

# ------------------------------------------------------------
# POST CONFIG
# ------------------------------------------------------------

function Invoke-PostConfig {

    param(
        [hashtable]$Config
    )

    Update-GlobalProgress "PostConfig"

    Write-Log INFO "Vérifications finales"

    if ($Config.Applications.Count -gt 0) {
        Write-Log OK "Applications"
    }

    if ($Config.DellUpdate) {
        Write-Log OK "Dell Update"
    }

    if ($Config.WindowsUpdate) {
        Write-Log OK "Windows Update"
    }

    if (
        -not :IsNullOrWhiteSpace(
            $Config.LocalAdminName
        )
    ) {

        if (
            Get-LocalUser `
                -Name $Config.LocalAdminName `
                -ErrorAction SilentlyContinue
        ) {

            Write-Log OK "Administrateur local"
        }
    }

    if (
        -not :IsNullOrWhiteSpace(
            $Config.ComputerName
        )
    ) {

        Write-Log OK "Renommage"
    }

    if (
        -not :IsNullOrWhiteSpace(
            $Config.DomainName
        )
    ) {

        Write-Log OK "Jointure domaine"
    }

    if ($Config.EntraJoin) {

        Write-Log OK "Entra ID"
    }

    Write-Log INFO "Fin des vérifications"
}

# ------------------------------------------------------------
# CLEANUP
# ------------------------------------------------------------

function Invoke-Cleanup {

    Update-GlobalProgress "Cleanup"

    Write-Log INFO "Nettoyage"

    Remove-ResumeTask

    Clear-State

    Write-Host ""
    Write-Host "========================================="
    Write-Host "AUDIT DEPLOY"
    Write-Host "========================================="
    Write-Host ""
    Write-Host "Erreurs : $ErrorCount"
    Write-Host ""
    Write-Host "Déploiement terminé."
    Write-Host ""

    Start-Sleep -Seconds 10

    Remove-Item `
        $RootFolder `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------
# MOTEUR PRINCIPAL
# ------------------------------------------------------------

function Start-AuditDeploy {

    Initialize-Environment

    if ($Resume) {

        Write-Log INFO "Reprise détectée"

        $State = Load-State

        if (-not $State) {

            Write-Log ERROR "Impossible de charger l'état"
            return
        }

        $Config = @{}

        $State.Config.PSObject.Properties | ForEach-Object {
            $Config[$_.Name] = $_.Value
        }

        $NextStep = $State.NextStep
    }
    else {

        if ($Silent) {

            $Config = New-Configuration
        }
        else {

            $Config = Show-GUI
        }

        if (-not $Config) {

            Write-Log INFO "Annulation utilisateur"
            return
        }

        $NextStep = "Applications"
    }

    switch ($NextStep) {

        "Applications" {

            Install-Applications $Config

            Invoke-DellUpdate $Config

            Invoke-WindowsUpdate $Config

            Configure-LocalAdmin $Config

            Configure-ComputerName $Config

            Invoke-JoinStep $Config

            if ($PendingReboot) {

                Invoke-Reboot `
                    -Config $Config `
                    -NextStep "PostConfig"

                return
            }

            Invoke-PostConfig $Config
            Invoke-Cleanup

            return
        }

        "PostConfig" {

            Invoke-PostConfig $Config
            Invoke-Cleanup

            return
        }

        default {

            Write-Log ERROR "Etape inconnue : $NextStep"
        }
    }
}

# ------------------------------------------------------------
# EXECUTION
# ------------------------------------------------------------

try {

    Start-AuditDeploy
}
catch {

    Write-Log ERROR $_.Exception.Message

    [System.Windows.Forms.MessageBox]::Show(
        $_.Exception.Message,
        "Audit Deploy"
    )
}

