# TiaUsersRoles.ps1 - Export / import des utilisateurs et roles du projet (UMAC)
#
# Les utilisateurs et roles du projet ne sont pas portes par Project mais par le service
# Siemens.Engineering.Umac.UmacConfigurator (project.GetService<UmacConfigurator>()).
# Les noms des compositions (ProjectUsers, CustomRoles...) et la signature des methodes
# Create varient selon la version de TIA Portal : tout passe donc par reflexion, et le
# bouton Diagnostic affiche le modele reel de l'installation.
#
# Ecriture possible a partir de V18. Le role UMAC de l'utilisateur connecte a TIA Portal
# doit porter la function right "Modify project via Openness API", sinon toute ecriture
# leve une EngineeringSecurityException.

$Script:UmacTypeName = "Siemens.Engineering.Umac.UmacConfigurator"
$Script:UmacMaxRelationItems = 2000
$Script:UmacFileFormat = "TiaOpennessTool.UsersRoles"
# Utilisateurs predefinis presents dans tout projet : jamais crees.
$Script:UmacBuiltinUsers = @("Anonymous")
$Script:UmacReloadLogged = $false

# Recepteur du journal, positionne par l'interface (scriptblock prenant un message).
$Script:UmacLogger = $null

function Write-UmacLog {
    param([string]$Message)
    if ($Script:UmacLogger) { & $Script:UmacLogger $Message }
}

function Format-UmacValue {
    # Valeur lisible d'une propriete d'exception (collections : elements, avec Text si present).
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return $Value }
    if (Test-UmacEnumerable $Value) {
        $texts = @()
        foreach ($d in $Value) {
            $txt = [string]$d
            $textProp = $d.GetType().GetProperty("Text")
            if ($textProp) { try { $txt = [string]$textProp.GetValue($d, $null) } catch {} }
            if ($txt) { $texts += $txt }
        }
        if ($texts.Length -eq 0) { return $null }
        return "[" + ($texts -join " ; ") + "]"
    }
    return [string]$Value
}

function Format-UmacException {
    # Message complet d'une exception Openness : pour chaque exception de la chaine (hors
    # enveloppes de reflexion), son type, son message et ses proprietes specifiques. Le
    # message de premier niveau est generique ("Error when calling method 'Create'...") ;
    # la cause eventuelle est dans les proprietes des exceptions Siemens.
    param([Exception]$Exception)
    $standard = @('Message', 'InnerException', 'StackTrace', 'TargetSite', 'Source', 'HelpLink',
                  'HResult', 'Data', 'ErrorRecord', 'WasThrownFromThrowStatement')
    $parts = @()
    $ex = $Exception
    while ($ex) {
        $wrapper = ($ex -is [System.Reflection.TargetInvocationException]) -or
                   ($ex -is [System.Management.Automation.MethodInvocationException])
        if (-not $wrapper) {
            $line = "$($ex.GetType().FullName): $($ex.Message)"
            foreach ($p in $ex.GetType().GetProperties()) {
                if ($standard -contains $p.Name -or $p.GetIndexParameters().Length -gt 0) { continue }
                $v = $null
                try { $v = Format-UmacValue ($p.GetValue($ex, $null)) } catch {}
                if ($v) { $line += " {$($p.Name)=$v}" }
            }
            $parts += $line
        }
        $ex = $ex.InnerException
    }
    return (@($parts | Select-Object -Unique) -join " <- ")
}

function Get-InnermostException {
    # Les appels par reflexion enveloppent la vraie cause dans TargetInvocationException.
    param([Exception]$Exception)
    $ex = $Exception
    while ($ex.InnerException) { $ex = $ex.InnerException }
    return $ex
}

function Find-LoadedType {
    param([string]$FullName)
    foreach ($asm in [AppDomain]::CurrentDomain.GetAssemblies()) {
        $t = $null
        try { $t = $asm.GetType($FullName, $false) } catch {}
        if ($t) { return $t }
    }
    return $null
}

function Get-UmacConfiguratorType {
    $type = Find-LoadedType -FullName $Script:UmacTypeName
    if ($type) { return $type }

    # Layout eclate (V20+) : le type peut vivre dans une assembly compagnon non encore chargee.
    $dllPath = (Get-AppState).DllPath
    if ($dllPath) {
        $dir = Split-Path -Parent $dllPath
        foreach ($f in @(Get-ChildItem -Path $dir -Filter "Siemens.Engineering*.dll" -ErrorAction SilentlyContinue)) {
            if ($f.Name -notmatch 'Umac|Base') { continue }
            try { [System.Reflection.Assembly]::LoadFrom($f.FullName) | Out-Null } catch {}
        }
        $type = Find-LoadedType -FullName $Script:UmacTypeName
    }
    return $type
}

function Get-ActiveProject {
    # TIA Portal peut remplacer l'objet Project (ecriture dans la gestion des utilisateurs) :
    # l'ancien leve alors "Access to a disposed object". On reprend le projet ouvert aupres de
    # l'instance TIA et on met l'etat a jour.
    $state = Get-AppState
    $project = $state.CurrentProject
    if (-not $project) { throw (T "MsgConnectFirst") }
    try {
        # Par reflexion : PowerShell avale les exceptions des accesseurs de propriete, un
        # simple $project.Name ne detecterait pas l'objet invalide.
        $nameProp = $project.GetType().GetProperty("Name")
        if ($nameProp) { [void]$nameProp.GetValue($project, $null) }
        return $project
    } catch {
        # Une seule mention par import : TIA remplace le projet apres chaque ecriture.
        if (-not $Script:UmacReloadLogged) { Write-UmacLog (T "LogUmacProjectReloaded") }
        $Script:UmacReloadLogged = $true
    }
    # L'instance TIA elle-meme peut avoir ete fermee (session Openness perdue).
    $projects = $null
    try { $projects = $state.TiaPortal.GetType().GetProperty("Projects").GetValue($state.TiaPortal, $null) } catch {}
    if ($null -eq $projects) { throw (T "MsgUmacSessionLost") }
    if (@($projects).Length -eq 0) { throw (T "MsgNoProject") }
    $project = $projects[0]
    Set-AppStateValue -Key "CurrentProject" -Value $project
    return $project
}

function Get-UmacConfigurator {
    # Appelle Project.GetService<UmacConfigurator>() par reflexion (PowerShell 5.1 ne sait pas
    # appeler directement une methode generique sans parametre).
    $project = Get-ActiveProject

    $type = Get-UmacConfiguratorType
    if (-not $type) { throw (T "MsgUmacUnavailable") }

    $method = $project.GetType().GetMethods() |
        Where-Object { $_.Name -eq 'GetService' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Length -eq 0 } |
        Select-Object -First 1
    if (-not $method) { throw (T "MsgUmacUnavailable") }

    $cfg = $null
    try {
        $cfg = $method.MakeGenericMethod($type).Invoke($project, $null)
    } catch {
        throw ((T "MsgUmacServiceError") -f (Get-InnermostException $_.Exception).Message)
    }
    if ($null -eq $cfg) { throw (T "MsgUmacUnavailable") }
    return ,$cfg
}

function Get-UmacObjectName {
    param($Obj)
    try { $n = $Obj.GetAttribute("Name"); if ($n) { return [string]$n } } catch {}
    try {
        $p = $Obj.PSObject.Properties["Name"]
        if ($p -and $p.Value) { return [string]$p.Value }
    } catch {}
    return [string]$Obj
}

function Get-UmacKind {
    # Classe une composition d'apres son nom de propriete et de type.
    param([string]$Text)
    if ($Text -match 'SystemRole') { return 'SystemRole' }
    if ($Text -match 'Role') { return 'CustomRole' }
    if ($Text -match 'Group') { return 'Group' }
    if ($Text -match 'User') { return 'User' }
    # Droits runtime definis par l'utilisateur (a creer avant de les affecter aux roles).
    if ($Text -match 'CustomDeviceFunctionRight') { return 'CustomRight' }
    if ($Text -match 'Right') { return 'Right' }
    return 'Other'
}

function Get-UmacCompositions {
    # Proprietes du configurator : chaque composition (users, roles, function rights...)
    # avec sa valeur et sa categorie.
    param($Configurator)

    $result = @()
    foreach ($prop in $Configurator.GetType().GetProperties()) {
        if ($prop.GetIndexParameters().Length -gt 0) { continue }
        $value = $null
        $err = $null
        try { $value = $prop.GetValue($Configurator, $null) } catch { $err = (Get-InnermostException $_.Exception).Message }
        $result += @{
            Name     = $prop.Name
            TypeName = $prop.PropertyType.Name
            Kind     = Get-UmacKind "$($prop.Name) $($prop.PropertyType.Name)"
            Value    = $value
            Error    = $err
        }
    }
    return $result
}

function Test-UmacEnumerable {
    param($Value)
    return ($null -ne $Value) -and ($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])
}

function Read-UmacItem {
    # Lit un utilisateur / role : attributs Openness + relations (toute propriete
    # enumerable : roles affectes, function rights...), conservees par nom.
    param($Obj, [string]$Source, [string]$Kind)

    $attrs = [ordered]@{}
    try {
        foreach ($info in $Obj.GetAttributeInfos()) {
            try {
                $v = $Obj.GetAttribute($info.Name)
                $attrs[$info.Name] = if ($null -eq $v) { $null } else { [string]$v }
            } catch {
                $attrs[$info.Name] = "<non lisible>"
            }
        }
    } catch {}
    # Proprietes simples absentes des attributs Openness (ex. Group / Comment d'un droit
    # runtime personnalise, qui n'expose pas GetAttributeInfos).
    foreach ($prop in $Obj.GetType().GetProperties()) {
        if ($prop.GetIndexParameters().Length -gt 0 -or $attrs.Contains($prop.Name)) { continue }
        $pt = $prop.PropertyType
        if (-not ($pt -eq [string] -or $pt.IsPrimitive -or $pt.IsEnum)) { continue }
        try {
            $v = $prop.GetValue($Obj, $null)
            $attrs[$prop.Name] = if ($null -eq $v) { $null } else { [string]$v }
        } catch {}
    }

    $relations = [ordered]@{}
    foreach ($prop in $Obj.GetType().GetProperties()) {
        if ($prop.GetIndexParameters().Length -gt 0) { continue }
        if ($prop.PropertyType -eq [string]) { continue }
        if (-not [System.Collections.IEnumerable].IsAssignableFrom($prop.PropertyType)) { continue }
        try {
            $coll = $prop.GetValue($Obj, $null)
            if ($null -eq $coll) { continue }
            $names = @()
            foreach ($x in $coll) {
                $names += (Get-UmacObjectName $x)
                if ($names.Length -ge $Script:UmacMaxRelationItems) { break }
            }
            $relations[$prop.Name] = $names
        } catch {}
    }

    return @{
        Source     = $Source
        Kind       = $Kind
        Type       = $Obj.GetType().Name
        Name       = Get-UmacObjectName $Obj
        Attributes = $attrs
        Relations  = $relations
    }
}

function Get-UmacItems {
    # Liste les utilisateurs, groupes et roles du projet. Les catalogues de function rights
    # ne sont pas listes (ils sont fixes) : ils servent seulement a resoudre les affectations.
    $cfg = Get-UmacConfigurator
    $items = @()
    $devices = @(Get-UmacDevices)
    Write-UmacLog ((T "LogUmacDevices") -f $devices.Length, (($devices | ForEach-Object { $_.Key }) -join ", "))

    foreach ($comp in @(Get-UmacCompositions -Configurator $cfg)) {
        if ($comp.Kind -eq 'Right' -or $comp.Kind -eq 'Other') { continue }
        if ($comp.Error) {
            Write-UmacLog ((T "LogUmacCompError") -f $comp.Name, $comp.Error)
            continue
        }
        if (-not (Test-UmacEnumerable $comp.Value)) { continue }

        $count = 0
        try {
            foreach ($obj in $comp.Value) {
                $item = Read-UmacItem -Obj $obj -Source $comp.Name -Kind $comp.Kind
                if ($comp.Kind -eq 'CustomRole') {
                    $item.DeviceRights = Get-UmacRoleDeviceRights -Role $obj -Devices $devices
                }
                $items += $item
                $count++
            }
        } catch {
            Write-UmacLog ((T "LogUmacCompError") -f $comp.Name, (Get-InnermostException $_.Exception).Message)
        }
        Write-UmacLog ((T "LogUmacCompCount") -f $comp.Name, $count)
    }

    Set-AppStateValue -Key "UmacItems" -Value $items
    return $items
}

function Format-UmacSignature {
    param([System.Reflection.MethodInfo]$Method)
    $params = @($Method.GetParameters() | ForEach-Object { "$($_.ParameterType.Name) $($_.Name)" })
    return "$($Method.Name)($($params -join ', ')) : $($Method.ReturnType.Name)"
}

function Add-UmacTypeMembers {
    param([System.Text.StringBuilder]$Sb, [Type]$Type, [string]$Indent)
    foreach ($p in ($Type.GetProperties() | Sort-Object Name)) {
        [void]$Sb.AppendLine("$Indent" + "P $($p.Name) : $($p.PropertyType.Name)")
    }
    $flags = [System.Reflection.BindingFlags]'Public, Instance, DeclaredOnly'
    foreach ($m in ($Type.GetMethods($flags) | Where-Object { -not $_.IsSpecialName } | Sort-Object Name)) {
        [void]$Sb.AppendLine("$Indent" + "M " + (Format-UmacSignature $m))
    }
}

function Get-UmacDiagnostic {
    # Modele objet UMAC reel de l'installation : racine, compositions, signatures Create,
    # et membres des elements (pour l'affectation des roles et des function rights).
    $cfg = Get-UmacConfigurator
    $sb = New-Object System.Text.StringBuilder

    [void]$sb.AppendLine("Racine UMAC : $($cfg.GetType().FullName)")
    Add-UmacTypeMembers -Sb $sb -Type $cfg.GetType() -Indent "  "

    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("===== Compositions =====")
    foreach ($comp in @(Get-UmacCompositions -Configurator $cfg)) {
        $value = $comp.Value
        $typeName = if ($null -ne $value) { $value.GetType().FullName } else { "null" }
        [void]$sb.AppendLine("$($comp.Name) [$($comp.Kind)] : $typeName")
        if ($comp.Error) { [void]$sb.AppendLine("    erreur : $($comp.Error)") }
        if ($null -eq $value) { continue }

        foreach ($m in ($value.GetType().GetMethods() | Where-Object { $_.Name -eq 'Create' })) {
            [void]$sb.AppendLine("    " + (Format-UmacSignature $m))
        }

        # Type des elements : d'apres IEnumerable<T> (connu meme si la composition est vide),
        # a defaut d'apres le premier element.
        $itemType = $value.GetType().GetInterfaces() |
            Where-Object { $_.IsGenericType -and $_.GetGenericTypeDefinition() -eq [System.Collections.Generic.IEnumerable`1] } |
            ForEach-Object { $_.GetGenericArguments()[0] } | Select-Object -First 1
        if (Test-UmacEnumerable $value) {
            $n = 0
            foreach ($x in $value) { if ($null -eq $itemType) { $itemType = $x.GetType() }; $n++ }
            [void]$sb.AppendLine("    elements : $n")
        }
        if ($null -ne $itemType) {
            [void]$sb.AppendLine("    element : $($itemType.FullName)")
            Add-UmacTypeMembers -Sb $sb -Type $itemType -Indent "      "
        }
    }

    # Appareils porteurs de droits runtime (UmacDevice via GetService) et leurs droits.
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("===== Appareils (UmacDevice) =====")
    try {
        foreach ($d in @(Get-UmacDevices)) {
            $avail = @()
            try { foreach ($r in $d.Device.AvailableDeviceFunctionRights) { $avail += $r } } catch {}
            [void]$sb.AppendLine("$($d.Key) [$($d.HolderType)] : $($avail.Length) droit(s) disponible(s)")
            foreach ($r in ($avail | Select-Object -First 15)) {
                $grp = ""; try { $grp = [string]$r.GetType().GetProperty("Group").GetValue($r, $null) } catch {}
                [void]$sb.AppendLine("    $(Get-UmacRightIdentifier $r) | $(Get-UmacObjectName $r) | $grp")
            }
        }
    } catch {
        [void]$sb.AppendLine("  erreur : $(Format-UmacException $_.Exception)")
    }

    # Tous les types publics de l'espace Umac (UmacDevice, associations de droits...).
    $umacTypes = @()
    foreach ($asm in [AppDomain]::CurrentDomain.GetAssemblies()) {
        if ($asm.GetName().Name -notlike "Siemens.Engineering*") { continue }
        try { $umacTypes += @($asm.GetExportedTypes() | Where-Object { $_.Namespace -eq "Siemens.Engineering.Umac" }) } catch {}
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("===== Types Siemens.Engineering.Umac =====")
    foreach ($t in ($umacTypes | Sort-Object FullName -Unique)) {
        if ($t.IsEnum) {
            [void]$sb.AppendLine("$($t.Name) (enum) : $([Enum]::GetNames($t) -join ', ')")
            continue
        }
        [void]$sb.AppendLine($t.Name)
        Add-UmacTypeMembers -Sb $sb -Type $t -Indent "  "
    }

    # Ou obtenir un UmacDevice (droits runtime par appareil) : membres qui en renvoient un.
    $deviceType = $umacTypes | Where-Object { $_.Name -eq "UmacDevice" } | Select-Object -First 1
    if ($deviceType) {
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("===== Membres renvoyant un UmacDevice =====")
        foreach ($asm in [AppDomain]::CurrentDomain.GetAssemblies()) {
            if ($asm.GetName().Name -notlike "Siemens.Engineering*") { continue }
            $types = @()
            try { $types = @($asm.GetExportedTypes()) } catch { continue }
            foreach ($t in $types) {
                foreach ($m in $t.GetMethods()) {
                    if ($m.ReturnType -eq $deviceType -or ($m.ReturnType.IsGenericType -and $m.ReturnType.GetGenericArguments() -contains $deviceType)) {
                        [void]$sb.AppendLine("  $($t.FullName).$(Format-UmacSignature $m)")
                    }
                }
            }
        }
    }
    return $sb.ToString()
}

# =================== DROITS RUNTIME PAR APPAREIL ===================
# En V21, les droits runtime d'un role sont affectes par appareil (IHM, automate) :
# CustomRole.GetAssignedDeviceFunctionRights(UmacDevice) / AssignDeviceFunctionRight(UmacDevice,
# DeviceFunctionRight). Aucune methode ne renvoie un UmacDevice : il s'obtient par
# GetService<UmacDevice>() sur l'appareil, un de ses device items ou son logiciel.

function Get-UmacServiceOf {
    # Obj.GetService<Type>() par reflexion ; $null si non supporte.
    param($Obj, [Type]$Type)
    if ($null -eq $Obj) { return $null }
    $m = $Obj.GetType().GetMethods() |
        Where-Object { $_.Name -eq 'GetService' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Length -eq 0 } |
        Select-Object -First 1
    if (-not $m) { return $null }
    $r = $null
    try { $r = $m.MakeGenericMethod($Type).Invoke($Obj, $null) } catch {}
    if ($null -eq $r) { return $null }
    return ,$r
}

function Get-UmacDeviceHolders {
    # Device items d'un appareil, recursivement.
    param($Items)
    $result = @()
    foreach ($it in $Items) {
        $result += $it
        try { $result += @(Get-UmacDeviceHolders -Items $it.DeviceItems) } catch {}
    }
    return $result
}

function Get-UmacDevices {
    # Appareils du projet porteurs de droits runtime : @{ Key; HolderType; Device }.
    # Cle = "<appareil>" ou "<appareil>/<device item>" : stable d'un projet a sa copie.
    $type = Find-LoadedType -FullName "Siemens.Engineering.Umac.UmacDevice"
    if (-not $type) { return @() }
    $project = Get-ActiveProject
    $result = @()
    $swType = Find-LoadedType -FullName "Siemens.Engineering.HW.Features.SoftwareContainer"
    $allDevices = @()
    try { $allDevices = @(Get-AllProjectDevices -Project $project) }
    catch { Write-UmacLog ((T "LogUmacDeviceReadError") -f "-", "-", (Format-UmacException $_.Exception)); return @() }
    foreach ($device in $allDevices) {
        $deviceName = [string](Get-UmacObjectName $device)
        $candidates = @(@{ Key = $deviceName; Obj = $device })
        foreach ($di in @(Get-UmacDeviceHolders -Items $device.DeviceItems)) {
            $key = "$deviceName/$(Get-UmacObjectName $di)"
            $candidates += @{ Key = $key; Obj = $di }
            if ($swType) {
                $sc = Get-UmacServiceOf -Obj $di -Type $swType
                if ($null -ne $sc) {
                    $sw = $null
                    try { $sw = $sc.GetType().GetProperty("Software").GetValue($sc, $null) } catch {}
                    if ($null -ne $sw) { $candidates += @{ Key = "$key/$(Get-UmacObjectName $sw)"; Obj = $sw } }
                }
            }
        }
        foreach ($cand in $candidates) {
            $umacDevice = Get-UmacServiceOf -Obj $cand.Obj -Type $type
            if ($null -ne $umacDevice) {
                $result += @{ Key = $cand.Key; HolderType = $cand.Obj.GetType().Name; Device = $umacDevice }
            }
        }
    }
    return $result
}

function Get-UmacAvailableRights {
    # UmacDevice.AvailableDeviceFunctionRights par reflexion : un acces direct a la propriete
    # renverrait $null sur un objet invalide (PowerShell avale l'exception de l'accesseur)
    # au lieu de lever "disposed", ce qui empecherait la relecture.
    param($Device)
    return ,($Device.GetType().GetProperty("AvailableDeviceFunctionRights").GetValue($Device, $null))
}

function Find-UmacDeviceRight {
    # Droit disponible sur l'appareil : par identifiant, sinon par nom pour un droit runtime
    # personnalise (son identifiant peut differer dans le projet cible).
    param($Available, [string]$Identifier, [hashtable]$CustomNames)
    $right = $Available.Find($Identifier)
    if ($null -eq $right -and $CustomNames -and $CustomNames.ContainsKey($Identifier)) {
        $wantedName = $CustomNames[$Identifier]
        foreach ($r in $Available) { if ((Get-UmacObjectName $r) -eq $wantedName) { $right = $r; break } }
    }
    return $right
}

function Get-UmacRightIdentifier {
    param($Right)
    try { $id = $Right.GetType().GetProperty("Identifier").GetValue($Right, $null); if ($id) { return [string]$id } } catch {}
    return Get-UmacObjectName $Right
}

function Get-UmacRoleDeviceRights {
    # Droits runtime affectes a un role personnalise, par appareil : { cle: [identifiants] }.
    param($Role, [array]$Devices)
    $result = [ordered]@{}
    foreach ($d in $Devices) {
        try {
            $ids = @()
            foreach ($r in $Role.GetAssignedDeviceFunctionRights($d.Device)) { $ids += (Get-UmacRightIdentifier $r) }
            if ($ids.Length -gt 0) { $result[$d.Key] = $ids }
        } catch {
            Write-UmacLog ((T "LogUmacDeviceReadError") -f (Get-UmacObjectName $Role), $d.Key, (Format-UmacException $_.Exception))
        }
    }
    return $result
}

function Set-UmacDeviceRights {
    # Rejoue les droits runtime exportes d'un role personnalise (ou les simule). Role et
    # appareil sont relus si une ecriture les a invalides ("disposed"), une fois par droit.
    # $CustomNames : identifiant source -> nom des droits runtime personnalises du fichier ;
    # $PlannedRights : identifiants des droits perso. qui seraient crees (simulation).
    # $DeviceMap : appareil du fichier -> appareil du projet ("" = ignorer), quand les noms different.
    param([string]$RoleName, $Item, [bool]$Commit, [hashtable]$CustomNames, [array]$PlannedRights, [hashtable]$DeviceMap)

    $stats = @{ Assigned = 0; Failed = 0 }
    if (-not $Item.PSObject.Properties['deviceRights'] -or -not $Item.deviceRights) { return $stats }
    $wantedByDevice = @($Item.deviceRights.PSObject.Properties | Where-Object { @($_.Value).Length -gt 0 })
    if ($wantedByDevice.Length -eq 0) { return $stats }

    $devices = @(Get-UmacDevices)
    foreach ($entry in $wantedByDevice) {
        $wanted = @($entry.Value | Where-Object { $_ })
        $targetKey = $entry.Name
        $label = $entry.Name
        if ($DeviceMap -and $DeviceMap.ContainsKey($entry.Name)) {
            $targetKey = [string]$DeviceMap[$entry.Name]
            if (-not $targetKey) {
                Write-UmacLog ((T "LogUmacDeviceIgnored") -f $RoleName, $entry.Name, $wanted.Length)
                continue
            }
            $label = "$($entry.Name) -> $targetKey"
        }
        $dev = $devices | Where-Object { $_.Key -eq $targetKey } | Select-Object -First 1
        if (-not $dev) {
            # Appareil absent du projet cible : droits ignores (signales), pas un echec.
            Write-UmacLog ((T "LogUmacDeviceMissing") -f $RoleName, $entry.Name, $wanted.Length)
            continue
        }

        $ctx = Get-UmacImportContext -Kind 'CustomRole' -Prefer 'Custom' -Planned @()
        $role = if ($ctx.Existing.ContainsKey($RoleName)) { $ctx.Existing[$RoleName] } else { $null }
        $assigned = @()
        if ($null -ne $role) {
            try { foreach ($r in $role.GetAssignedDeviceFunctionRights($dev.Device)) { $assigned += (Get-UmacRightIdentifier $r) } } catch {}
        }
        # Comparaison sur l'identifiant resolu dans ce projet (un droit perso. retrouve par son
        # nom peut y avoir un autre identifiant) : evite de reaffecter un droit deja present.
        $available = Get-UmacAvailableRights $dev.Device
        $todo = @($wanted | Where-Object {
            $resolved = Find-UmacDeviceRight -Available $available -Identifier $_ -CustomNames $CustomNames
            $effectiveId = if ($null -ne $resolved) { Get-UmacRightIdentifier $resolved } else { $_ }
            $assigned -notcontains $effectiveId })
        if ($todo.Length -eq 0) { continue }
        $unknown = @($todo | Where-Object {
            $null -eq (Find-UmacDeviceRight -Available $available -Identifier $_ -CustomNames $CustomNames) -and
            @($PlannedRights) -notcontains $_ })

        if (-not $Commit) {
            Write-UmacLog ((T "LogUmacDevicePlan") -f $RoleName, $label, $todo.Length, $unknown.Length)
            continue
        }

        $errors = @()
        foreach ($id in $todo) {
            $done = $false
            for ($attempt = 1; $attempt -le 2 -and -not $done; $attempt++) {
                try {
                    if ($attempt -gt 1) {
                        # Objets invalides par l'ecriture precedente : relecture role + appareil.
                        $ctx = Get-UmacImportContext -Kind 'CustomRole' -Prefer 'Custom' -Planned @()
                        $role = $ctx.Existing[$RoleName]
                        $dev = @(Get-UmacDevices) | Where-Object { $_.Key -eq $targetKey } | Select-Object -First 1
                    }
                    $right = Find-UmacDeviceRight -Available (Get-UmacAvailableRights $dev.Device) -Identifier $id -CustomNames $CustomNames
                    if ($null -eq $right) { throw (T "MsgUmacNotFound") }
                    $role.AssignDeviceFunctionRight($dev.Device, $right)
                    $done = $true
                    $stats.Assigned++
                } catch {
                    $msg = Format-UmacException $_.Exception
                    if ($attempt -eq 1 -and $msg -match 'disposed') { continue }
                    $stats.Failed++
                    $errors += "$id : $msg"
                    $done = $true
                }
            }
        }
        Write-UmacLog ((T "LogUmacDeviceDone") -f $RoleName, $label, ($todo.Length - $errors.Length), $errors.Length)
        foreach ($e in ($errors | Select-Object -First 5)) { Write-UmacLog "      $e" }
    }
    return $stats
}

# Reglages restaures apres creation (le nom et le mot de passe sont donnes a Create).
$Script:UmacSettings = @('Comment', 'AliasName', 'SessionTimeOut', 'IsActive', 'IsRuntimeSessionTimeoutActive')

function Set-UmacSettings {
    # Reapplique les reglages exportes (commentaire, alias, delai de session, actif...) sur
    # l'element cible, via les methodes dediees de l'API (SetAliasName, Activate...) ou la
    # propriete. En simulation, liste seulement les reglages qui changeraient.
    param($Target, $Item, [bool]$Commit)

    $stats = @{ Assigned = 0; Failed = 0 }
    if (-not $Item.PSObject.Properties['attributes'] -or -not $Item.attributes) { return $stats }
    $changes = @()
    foreach ($name in $Script:UmacSettings) {
        $attr = $Item.attributes.PSObject.Properties[$name]
        if (-not $attr -or $null -eq $attr.Value) { continue }
        $current = $null
        $prop = $null
        if ($null -ne $Target) {
            $prop = $Target.GetType().GetProperty($name)
            if (-not $prop) { continue }
            try { $current = $prop.GetValue($Target, $null) } catch {}
            if ([string]$current -eq [string]$attr.Value) { continue }
        }
        $changes += @{ Name = $name; Value = [string]$attr.Value; Prop = $prop }
    }
    if ($changes.Length -eq 0) { return $stats }
    if (-not $Commit -or $null -eq $Target) {
        Write-UmacLog ((T "LogUmacSettingsPlan") -f $Item.name, (($changes | ForEach-Object { $_.Name }) -join ", "))
        return $stats
    }

    $errors = @()
    foreach ($ch in $changes) {
        try {
            $value = $ch.Value
            switch ($ch.Name) {
                'IsActive' {
                    if ($value -eq 'True') { $Target.Activate() } else { $Target.Deactivate() }
                }
                'IsRuntimeSessionTimeoutActive' {
                    if ($value -eq 'True') { $Target.ActivateRuntimeSessionTimeout() } else { $Target.DeactivateRuntimeSessionTimeout() }
                }
                'AliasName' { $Target.SetAliasName($value) }
                default {
                    $pt = $ch.Prop.PropertyType
                    $typed = if ($pt -eq [string]) { $value } else { [Convert]::ChangeType($value, $pt, [Globalization.CultureInfo]::InvariantCulture) }
                    if ($ch.Prop.CanWrite) { $ch.Prop.SetValue($Target, $typed, $null) }
                    else { $Target.SetAttribute($ch.Name, $typed) }
                }
            }
            $stats.Assigned++
        } catch {
            $stats.Failed++
            $errors += "$($ch.Name) : $(Format-UmacException $_.Exception)"
        }
    }
    Write-UmacLog ((T "LogUmacSettingsDone") -f $Item.name, ($changes.Length - $errors.Length), $errors.Length)
    foreach ($e in $errors) { Write-UmacLog "      $e" }
    return $stats
}

function Export-UmacConfig {
    param([string]$Path)

    $items = @(Get-UmacItems)
    $state = Get-AppState
    $bundle = [ordered]@{
        format     = $Script:UmacFileFormat
        version    = 1
        project    = $state.ProjectName
        tiaVersion = $state.SelectedVersion
        exportedAt = (Get-Date).ToString("s")
        items      = @($items | ForEach-Object {
            [ordered]@{
                source     = $_.Source
                kind       = $_.Kind
                type       = $_.Type
                name       = $_.Name
                attributes = $_.Attributes
                relations  = $_.Relations
                # Droits runtime par appareil : { "<appareil>": [identifiants] }
                deviceRights = $(if ($_.ContainsKey('DeviceRights')) { $_.DeviceRights } else { [ordered]@{} })
            }
        })
    }

    $json = ConvertTo-Json -InputObject $bundle -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
    Write-UmacLog ((T "LogUmacExported") -f $items.Length, $Path)
    return $items.Length
}

function New-UmacLookup {
    # Index nom -> objets, sur toutes les compositions du configurator (roles, function
    # rights...) : sert a resoudre les relations exportees par nom.
    param([array]$Compositions)

    $lookup = @{}
    foreach ($comp in $Compositions) {
        if (-not (Test-UmacEnumerable $comp.Value)) { continue }
        try {
            foreach ($obj in $comp.Value) {
                $name = Get-UmacObjectName $obj
                if (-not $lookup.ContainsKey($name)) { $lookup[$name] = @() }
                $lookup[$name] += $obj
            }
        } catch {}
    }
    return $lookup
}

function Invoke-UmacCreate {
    # Appelle la surcharge Create(string, ...) la plus courte de la composition. Un parametre
    # SecureString (mot de passe d'un utilisateur local) recoit le mot de passe initial ; un
    # parametre texte (ex. Create(name, comment) des roles en V21) recoit l'attribut exporte
    # de meme nom, sinon une chaine vide : TIA Portal plante (NonRecoverableException) sur null.
    param($Composition, [string]$Name, [System.Security.SecureString]$Password, $Attributes)

    $methods = @($Composition.GetType().GetMethods() |
        Where-Object { $_.Name -eq 'Create' } |
        Sort-Object { $_.GetParameters().Length })

    foreach ($m in $methods) {
        $ps = $m.GetParameters()
        if ($ps.Length -lt 1 -or $ps[0].ParameterType -ne [string]) { continue }

        $callArgs = New-Object object[] $ps.Length
        $callArgs[0] = $Name
        for ($i = 1; $i -lt $ps.Length; $i++) {
            $pt = $ps[$i].ParameterType
            if ($pt -eq [System.Security.SecureString]) {
                if (-not $Password) { throw (T "MsgUmacPasswordRequired") }
                $callArgs[$i] = $Password.Copy()
            } elseif ($pt -eq [string]) {
                $value = ""
                if ($null -ne $Attributes) {
                    $attr = $Attributes.PSObject.Properties | Where-Object { $_.Name -eq $ps[$i].Name } | Select-Object -First 1
                    if ($attr -and $null -ne $attr.Value) { $value = [string]$attr.Value }
                }
                $callArgs[$i] = $value
            } elseif ($ps[$i].HasDefaultValue) {
                $callArgs[$i] = $ps[$i].DefaultValue
            } elseif ($pt.IsValueType) {
                $callArgs[$i] = [Activator]::CreateInstance($pt)
            } else {
                $callArgs[$i] = $null
            }
        }

        try { return ,$m.Invoke($Composition, $callArgs) }
        catch { throw (Format-UmacException $_.Exception) }
    }
    throw ((T "MsgUmacNoCreate") -f $Composition.GetType().Name)
}

function Add-UmacRelationMember {
    # Ajoute un element a une relation (roles d'un utilisateur, function rights d'un role...)
    # via la premiere methode Add/Assign/Create/Include a un parametre compatible.
    param($Collection, [string]$Name, [array]$Candidates)

    $methods = @($Collection.GetType().GetMethods() |
        Where-Object { $_.Name -match '^(Add|Assign|Create|Include)$' -and $_.GetParameters().Length -eq 1 })

    foreach ($m in $methods) {
        $pt = $m.GetParameters()[0].ParameterType
        $arg = $null
        if ($pt -eq [string]) {
            $arg = $Name
        } else {
            $arg = $Candidates | Where-Object { $pt.IsInstanceOfType($_) } | Select-Object -First 1
        }
        if ($null -eq $arg) { continue }
        # Le pipeline enveloppe les objets dans un PSObject, que MethodInfo.Invoke refuse.
        $callArgs = New-Object object[] 1
        $callArgs[0] = $arg.PSObject.BaseObject
        try { [void]$m.Invoke($Collection, $callArgs); return }
        catch { throw (Format-UmacException $_.Exception) }
    }
    if (@($Candidates | Where-Object { $null -ne $_ }).Length -eq 0) { throw (T "MsgUmacNotFound") }
    throw ((T "MsgUmacNoAssign") -f $Collection.GetType().Name)
}

function Set-UmacRelations {
    # Rejoue les relations exportees d'un element sur l'objet cible (ou les simule).
    # En ecriture, si -RefreshKind est donne, l'etat (cible + index) est relu avant chaque
    # affectation : une ecriture peut invalider la cible et les objets resolus juste avant.
    param($Target, $Item, [hashtable]$Lookup, [bool]$Commit, [string]$RefreshKind, [string]$RefreshPrefer, [array]$SkipNames)

    $stats = @{ Assigned = 0; Failed = 0 }
    if (-not $Item.PSObject.Properties['relations'] -or -not $Item.relations) { return $stats }

    foreach ($rel in $Item.relations.PSObject.Properties) {
        $wanted = @($rel.Value | Where-Object { $_ })
        # Les roles systeme ne sont jamais ecrits (ni crees, ni affectes).
        $skipped = @($wanted | Where-Object { @($SkipNames) -contains $_ })
        if ($skipped.Length -gt 0) {
            Write-UmacLog ((T "LogUmacRelSkipSystem") -f $Item.name, $rel.Name, ($skipped -join ", "))
            $wanted = @($wanted | Where-Object { @($SkipNames) -notcontains $_ })
        }
        if ($wanted.Length -eq 0) { continue }

        $existing = @()
        $coll = $null
        if ($null -ne $Target) {
            $prop = $Target.GetType().GetProperty($rel.Name)
            if (-not $prop) {
                Write-UmacLog ((T "LogUmacRelMissing") -f $Item.name, $rel.Name)
                continue
            }
            try { $coll = $prop.GetValue($Target, $null) } catch {}
            if (Test-UmacEnumerable $coll) {
                foreach ($x in $coll) { $existing += (Get-UmacObjectName $x) }
            }
        }

        $todo = @($wanted | Where-Object { $existing -notcontains $_ })
        if ($todo.Length -eq 0) { continue }
        $unresolved = @($todo | Where-Object { -not $Lookup.ContainsKey($_) })
        if (-not $Commit) {
            Write-UmacLog ((T "LogUmacRelPlan") -f $Item.name, $rel.Name, $todo.Length, $unresolved.Length)
            continue
        }
        if ($null -eq $coll) {
            Write-UmacLog ((T "LogUmacRelMissing") -f $Item.name, $rel.Name)
            continue
        }

        $errors = @()
        foreach ($name in $todo) {
            try {
                $currentLookup = $Lookup
                $currentColl = $coll
                if ($Commit -and $RefreshKind) {
                    $fresh = Get-UmacImportContext -Kind $RefreshKind -Prefer $RefreshPrefer -Planned @()
                    $currentLookup = $fresh.Lookup
                    $freshTarget = $fresh.Existing[[string]$Item.name]
                    if ($null -ne $freshTarget) {
                        $currentColl = $freshTarget.GetType().GetProperty($rel.Name).GetValue($freshTarget, $null)
                    }
                }
                $candidates = if ($currentLookup.ContainsKey($name)) { @($currentLookup[$name]) } else { @() }
                Add-UmacRelationMember -Collection $currentColl -Name $name -Candidates $candidates
                $stats.Assigned++
            } catch {
                $stats.Failed++
                $errors += "$name : $($_.Exception.Message)"
            }
        }
        Write-UmacLog ((T "LogUmacRelDone") -f $Item.name, $rel.Name, ($todo.Length - $errors.Length), $errors.Length)
        foreach ($e in ($errors | Select-Object -First 5)) { Write-UmacLog "      $e" }
    }
    return $stats
}

function Find-UmacComposition {
    # Les compositions sont enumerables : la virgule empeche PowerShell de les deballer au
    # retour (une composition vide deviendrait $null).
    param([array]$Compositions, [string]$Kind, [string]$Prefer)
    $candidates = @($Compositions | Where-Object { $_.Kind -eq $Kind -and $null -ne $_.Value })
    $preferred = @($candidates | Where-Object { $_.Name -match $Prefer })
    if ($preferred.Length -gt 0) { return ,$preferred[0].Value }
    if ($candidates.Length -gt 0) { return ,$candidates[0].Value }
    return $null
}

function Get-UmacImportContext {
    # Etat courant pour importer un element : composition cible, index nom -> objets de toutes
    # les compositions, et elements deja presents dans la cible.
    param([string]$Kind, [string]$Prefer, [array]$Planned)

    $comps = @(Get-UmacCompositions -Configurator (Get-UmacConfigurator))
    $comp = Find-UmacComposition -Compositions $comps -Kind $Kind -Prefer $Prefer
    $lookup = New-UmacLookup -Compositions $comps
    # En simulation, les roles qui seraient crees comptent comme resolvables.
    foreach ($p in @($Planned)) { if ($p -and -not $lookup.ContainsKey($p)) { $lookup[$p] = @() } }
    $existing = @{}
    if ($null -ne $comp) {
        foreach ($o in $comp) { $existing[(Get-UmacObjectName $o)] = $o }
    }
    return @{ Comp = $comp; Lookup = $lookup; Existing = $existing }
}

function Get-UmacFileDevices {
    # Appareils references par les droits runtime d'un fichier d'export.
    param([string]$Path)
    $bundle = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $keys = @()
    foreach ($it in @($bundle.items)) {
        if (-not $it.PSObject.Properties['deviceRights'] -or -not $it.deviceRights) { continue }
        foreach ($p in $it.deviceRights.PSObject.Properties) { if (@($p.Value).Length -gt 0) { $keys += $p.Name } }
    }
    return @($keys | Sort-Object -Unique)
}

function Import-UmacConfig {
    # Importe les roles personnalises puis les utilisateurs (avec leurs relations) depuis un
    # fichier produit par Export-UmacConfig. Sans -Commit : simulation, rien n'est ecrit.
    # Avec -Commit : ecriture sous ExclusiveAccess + Transaction (annulee en cas d'erreur fatale).
    param(
        [string]$Path,
        [bool]$Commit,
        [System.Security.SecureString]$InitialPassword,
        # Sans transaction : chaque ecriture est immediate (pas d'annulation globale si echec).
        [bool]$UseTransaction = $true,
        # Correspondance des appareils : nom dans le fichier -> nom dans ce projet ("" = ignorer).
        [hashtable]$DeviceMap = @{}
    )

    $bundle = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $bundle.PSObject.Properties['items'] -or
        -not $bundle.PSObject.Properties['format'] -or $bundle.format -ne $Script:UmacFileFormat) {
        throw (T "MsgUmacBadFile")
    }

    $items = @($bundle.items)
    $roles = @($items | Where-Object { $_.kind -eq 'CustomRole' })
    $users = @($items | Where-Object { $_.kind -eq 'User' })
    $rights = @($items | Where-Object { $_.kind -eq 'CustomRight' })
    $ignored = $items.Length - $roles.Length - $users.Length - $rights.Length
    $systemRoles = @($items | Where-Object { $_.kind -eq 'SystemRole' } | ForEach-Object { [string]$_.name })
    # Droits runtime perso. du fichier : identifiant source -> nom (resolution par nom).
    $customNames = @{}
    foreach ($r in $rights) {
        $idAttr = $r.attributes.PSObject.Properties['Identifier']
        if ($idAttr -and $idAttr.Value) { $customNames[[string]$idAttr.Value] = [string]$r.name }
    }
    $plannedRights = @()
    $mode = if ($Commit) { T "LogUmacModeCommit" } else { T "LogUmacModeDryRun" }
    Write-UmacLog ((T "LogUmacImportStart") -f $rights.Length, $roles.Length, $users.Length, $ignored, $mode)

    $summary = @{ Created = 0; Existing = 0; Failed = 0; Assigned = 0; AssignFailed = 0 }
    $planned = @()

    $Script:UmacReloadLogged = $false
    $ea = $null
    $tr = $null
    # Etape en cours, reportee dans l'erreur pour localiser un echec cote TIA Portal.
    $step = "ExclusiveAccess"
    try {
        if ($Commit) {
            $ea = (Get-AppState).TiaPortal.ExclusiveAccess((T "UmacExclusiveAccess"))
            if ($UseTransaction) {
                $step = "Transaction"
                $tr = $ea.Transaction((Get-ActiveProject), "Import users & roles")
            } else {
                Write-UmacLog (T "LogUmacNoTransaction")
            }
        }
        $step = "lecture initiale"
        $ctx = Get-UmacImportContext -Kind 'CustomRole' -Prefer 'Custom' -Planned $planned
        $userCtx = Get-UmacImportContext -Kind 'User' -Prefer 'Project' -Planned $planned
        Write-UmacLog ((T "LogUmacTargets") -f
            $(if ($null -ne $ctx.Comp) { $ctx.Comp.GetType().Name } else { "-" }),
            $(if ($null -ne $userCtx.Comp) { $userCtx.Comp.GetType().Name } else { "-" }))

        # Ordre de dependance : droits runtime perso. (affectes aux roles), roles (affectes
        # aux utilisateurs), puis utilisateurs.
        foreach ($group in @(@{ Items = $rights; Kind = 'CustomRight'; Prefer = 'CustomDevice' },
                             @{ Items = $roles; Kind = 'CustomRole'; Prefer = 'Custom' },
                             @{ Items = $users; Kind = 'User'; Prefer = 'Project' })) {
            foreach ($item in $group.Items) {
                $name = [string]$item.name
                if (-not $name) { continue }
                if ($Script:UmacBuiltinUsers -contains $name) {
                    Write-UmacLog ((T "LogUmacBuiltinSkipped") -f $name)
                    continue
                }
                $step = "$($item.kind) '$name' : lecture"

                # Compositions relues a chaque element : TIA Portal invalide les objets
                # Openness obtenus avant une ecriture ("Access to a disposed object").
                # L'index relu rend aussi resolvables les roles crees juste avant.
                $ctx = Get-UmacImportContext -Kind $group.Kind -Prefer $group.Prefer -Planned $planned
                if ($null -eq $ctx.Comp) {
                    Write-UmacLog (T "LogUmacNoTarget")
                    $summary.Failed++
                    continue
                }
                $lookup = $ctx.Lookup

                $target = $null
                if ($ctx.Existing.ContainsKey($name)) {
                    $target = $ctx.Existing[$name]
                    $summary.Existing++
                    Write-UmacLog ((T "LogUmacExists") -f $item.kind, $name)
                } elseif (-not $Commit) {
                    $planned += $name
                    if ($group.Kind -eq 'CustomRight') {
                        $plannedRights += @($customNames.Keys | Where-Object { $customNames[$_] -eq $name })
                    }
                    Write-UmacLog ((T "LogUmacWouldCreate") -f $item.kind, $name)
                } else {
                    $step = "$($item.kind) '$name' : creation"
                    try {
                        $target = Invoke-UmacCreate -Composition $ctx.Comp -Name $name -Password $InitialPassword `
                            -Attributes $(if ($item.PSObject.Properties['attributes']) { $item.attributes } else { $null })
                        $summary.Created++
                        Write-UmacLog ((T "LogUmacCreated") -f $item.kind, $name)
                    } catch {
                        $summary.Failed++
                        Write-UmacLog ((T "LogUmacCreateFailed") -f $item.kind, $name, $_.Exception.Message)
                        continue
                    }
                }

                $step = "$($item.kind) '$name' : affectations"
                if ($Commit) {
                    # La creation a pu invalider les objets lus avant : relire cible et index.
                    $fresh = Get-UmacImportContext -Kind $group.Kind -Prefer $group.Prefer -Planned @()
                    $lookup = $fresh.Lookup
                    if ($fresh.Existing.ContainsKey($name)) { $target = $fresh.Existing[$name] }
                }
                $rel = Set-UmacRelations -Target $target -Item $item -Lookup $lookup -Commit $Commit -RefreshKind $group.Kind -RefreshPrefer $group.Prefer -SkipNames $systemRoles
                $summary.Assigned += $rel.Assigned
                $summary.AssignFailed += $rel.Failed

                # Reglages (commentaire, alias, delai de session...) sur la cible relue.
                $step = "$($item.kind) '$name' : reglages"
                if ($Commit) {
                    $fresh = Get-UmacImportContext -Kind $group.Kind -Prefer $group.Prefer -Planned @()
                    if ($fresh.Existing.ContainsKey($name)) { $target = $fresh.Existing[$name] }
                }
                if ($group.Kind -ne 'CustomRight') {
                    $set = Set-UmacSettings -Target $target -Item $item -Commit $Commit
                    $summary.Assigned += $set.Assigned
                    $summary.AssignFailed += $set.Failed
                }

                # Droits runtime par appareil des roles personnalises.
                if ($group.Kind -eq 'CustomRole') {
                    $step = "$($item.kind) '$name' : droits runtime"
                    $dr = Set-UmacDeviceRights -RoleName $name -Item $item -Commit $Commit `
                        -CustomNames $customNames -PlannedRights $plannedRights -DeviceMap $DeviceMap
                    $summary.Assigned += $dr.Assigned
                    $summary.AssignFailed += $dr.Failed
                }
            }
        }

        $step = "validation de la transaction"
        if ($tr) { $tr.CommitOnDispose() }
    } catch {
        $msg = (Get-InnermostException $_.Exception).Message
        if ($msg -match 'disposed') { $msg += "`n`n" + (T "MsgUmacSessionLost") }
        throw ((T "MsgUmacStepError") -f $step, $msg)
    } finally {
        # Une erreur a la fermeture ne doit pas masquer la cause : elle est seulement journalisee.
        if ($tr) { try { $tr.Dispose() } catch { Write-UmacLog "  [!] Transaction.Dispose : $((Get-InnermostException $_.Exception).Message)" } }
        if ($ea) { try { $ea.Dispose() } catch { Write-UmacLog "  [!] ExclusiveAccess.Dispose : $((Get-InnermostException $_.Exception).Message)" } }
    }

    Write-UmacLog ((T "LogUmacImportDone") -f $summary.Created, $summary.Existing, $summary.Failed, $summary.Assigned, $summary.AssignFailed)
    return $summary
}
