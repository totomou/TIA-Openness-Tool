# TiaVersions.ps1 - Multi-version TIA Portal DLL detection and loading

# Sous-dossiers de framework cible sondes pour le nouveau layout Openness (V20+).
# Restreint a net48/net472 : l'outil tourne sous Windows PowerShell 5.1 (hote .NET
# Framework 4.x), qui ne peut charger que ces TFM -- pas les assemblies net6.0/net8.0.
$Script:OpennessTargetFrameworks = @('net48', 'net472')

# Assembly compagnon a charger en plus de Siemens.Engineering.Base.dll dans le nouveau
# layout : contient les types Step7 utilises par l'outil (SW.PlcSoftware, SW.Blocks.*).
$Script:OpennessCompanionAssemblies = @('Siemens.Engineering.Step7.dll')

function Resolve-OpennessDllPath {
    # Retourne le chemin de l'assembly d'entree Openness pour un dossier PublicAPI donne.
    # Retombe sur le nouveau layout (V20/V21+) -- ou Siemens a eclate l'API en plusieurs
    # assemblies rangees dans un sous-dossier de framework cible -- quand l'ancien fichier
    # mono-DLL Siemens.Engineering.dll (V15-V19) est absent.
    param([string]$PublicApiDir)

    $legacyDll = Join-Path $PublicApiDir "Siemens.Engineering.dll"
    if (Test-Path $legacyDll) { return $legacyDll }

    foreach ($tfm in $Script:OpennessTargetFrameworks) {
        $candidate = Join-Path $PublicApiDir "$tfm\Siemens.Engineering.Base.dll"
        if (Test-Path $candidate) { return $candidate }
    }

    return $null
}

function Get-InstalledTiaVersions {
    $versions = @()
    $basePath = "C:\Program Files\Siemens\Automation"

    if (Test-Path $basePath) {
        Get-ChildItem -Path $basePath -Directory -Filter "Portal V*" -ErrorAction SilentlyContinue | ForEach-Object {
            $dirName = $_.Name
            if ($dirName -match 'Portal V(\d+)') {
                $vNum = $Matches[1]
                $vLabel = "V$vNum"
                $publicApiDir = Join-Path $_.FullName "PublicAPI\V$vNum"
                $dllPath = Resolve-OpennessDllPath -PublicApiDir $publicApiDir
                if ($dllPath) {
                    $versions += @{
                        Version     = $vLabel
                        MajorNumber = [int]$vNum
                        DllPath     = $dllPath
                    }
                }
            }
        }
    }

    return $versions | Sort-Object { $_.MajorNumber }
}

function Register-OpennessAssemblyResolver {
    # Enregistre (une seule fois) un handler AssemblyResolve qui sonde le dossier de l'API
    # Openness. Indispensable pour le nouveau layout (V20+), ou les assemblies compagnons
    # se referencent entre elles et ne sont pas dans le GAC : sans resolver, .NET echoue a
    # localiser Siemens.Engineering.Base a partir de Step7 (et inversement).
    param([string]$ProbeDir)

    if (-not $ProbeDir) { return }
    $already = [bool](Get-Variable -Name OpennessResolverRegistered -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    if ($already) { return }

    $resolver = {
        param($sender, $eventArgs)
        $simpleName = ($eventArgs.Name -split ',')[0].Trim()
        $candidate = Join-Path $ProbeDir ($simpleName + '.dll')
        if (Test-Path $candidate) {
            try { return [System.Reflection.Assembly]::LoadFrom($candidate) } catch { return $null }
        }
        return $null
    }.GetNewClosure()

    [System.AppDomain]::CurrentDomain.add_AssemblyResolve($resolver)
    Set-Variable -Name OpennessResolverRegistered -Scope Script -Value $true
}

function Initialize-TiaOpenness {
    param([string]$DllPath)

    $state = Get-AppState

    # If DLL already loaded for a different version, warn
    if ($state.DllLoaded -and $state.DllPath -ne $DllPath) {
        return @{ Success = $false; Message = T "MsgRestartRequired" }
    }

    # If already loaded same path, skip
    if ($state.DllLoaded -and $state.DllPath -eq $DllPath) {
        return @{ Success = $true; Message = "" }
    }

    # Sonde le dossier de l'assembly d'entree pour resoudre les dependances inter-assemblies
    # du nouveau layout ; sans effet sur l'ancien layout mono-DLL (aucune dependance a sonder).
    $probeDir = Split-Path -Parent $DllPath
    Register-OpennessAssemblyResolver -ProbeDir $probeDir

    try {
        [System.Reflection.Assembly]::LoadFrom($DllPath) | Out-Null
        # Nouveau layout : l'API est eclatee, il faut charger explicitement les compagnons
        # (types Step7). Absents de l'ancien layout mono-DLL -> boucle sans effet.
        foreach ($companion in $Script:OpennessCompanionAssemblies) {
            $companionPath = Join-Path $probeDir $companion
            if (Test-Path $companionPath) {
                try { [System.Reflection.Assembly]::LoadFrom($companionPath) | Out-Null } catch {}
            }
        }
        Set-AppStateValue -Key "DllPath" -Value $DllPath
        Set-AppStateValue -Key "DllLoaded" -Value $true
        return @{ Success = $true; Message = "" }
    } catch {
        try {
            Add-Type -LiteralPath $DllPath -ErrorAction Stop
            Set-AppStateValue -Key "DllPath" -Value $DllPath
            Set-AppStateValue -Key "DllLoaded" -Value $true
            return @{ Success = $true; Message = "" }
        } catch {
            return @{ Success = $false; Message = $_.Exception.Message }
        }
    }
}

function Get-TiaVersionFromProcess {
    param([int]$ProcessId)
    try {
        $wmiResult = Get-WmiObject -Query "SELECT ExecutablePath FROM Win32_Process WHERE ProcessId = $ProcessId" -ErrorAction SilentlyContinue
        if ($wmiResult -and $wmiResult.ExecutablePath -match 'Portal V(\d+)') {
            return "V$($Matches[1])"
        }
    } catch {}
    return $null
}

function Get-RunningTiaPortalVersions {
    # Detecte les instances TIA Portal reellement en cours d'execution, via WMI, en se
    # basant sur le chemin de l'executable (Portal Vxx). Independant de l'API Openness,
    # qui ne voit que les instances de la version de DLL chargee : sert donc a choisir
    # le bon defaut de version au demarrage et a diagnostiquer un scan vide.
    $running = @()
    try {
        $procs = Get-WmiObject -Query "SELECT ProcessId, ExecutablePath FROM Win32_Process WHERE Name = 'Siemens.Automation.Portal.exe'" -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            if ($p.ExecutablePath -match 'Portal V(\d+)') {
                $running += @{
                    ProcessId   = [int]$p.ProcessId
                    Version     = "V$($Matches[1])"
                    MajorNumber = [int]$Matches[1]
                }
            }
        }
    } catch {}
    return $running
}

function Resolve-SelectedDllPath {
    # Retourne le chemin de la DLL Openness correspondant a la version actuellement
    # selectionnee dans l'interface (sans la charger).
    $state = Get-AppState
    if (-not $state.SelectedVersion) { return $null }
    $match = $state.InstalledVersions | Where-Object { $_.Version -eq $state.SelectedVersion } | Select-Object -First 1
    if ($match) { return $match.DllPath }
    return $null
}

function Confirm-TiaDllLoaded {
    # Charge (paresseusement) la DLL Openness de la version selectionnee si ce n'est pas
    # deja fait. Le chargement est differe jusqu'au scan/connexion : tant qu'aucune DLL
    # n'est chargee, l'utilisateur peut librement changer de version. Une fois une version
    # chargee, .NET ne permet pas d'en charger une autre dans le meme processus -- il faut
    # alors redemarrer l'outil.
    if ((Get-AppState).DllLoaded) { return @{ Success = $true; Message = "" } }
    $dllPath = Resolve-SelectedDllPath
    if (-not $dllPath) { return @{ Success = $false; Message = T "MsgDllRequired" } }
    return Initialize-TiaOpenness -DllPath $dllPath
}
