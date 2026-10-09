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

# Recepteur du journal, positionne par l'interface (scriptblock prenant un message).
$Script:UmacLogger = $null

function Write-UmacLog {
    param([string]$Message)
    if ($Script:UmacLogger) { & $Script:UmacLogger $Message }
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

function Get-UmacConfigurator {
    # Appelle Project.GetService<UmacConfigurator>() par reflexion (PowerShell 5.1 ne sait pas
    # appeler directement une methode generique sans parametre).
    $project = (Get-AppState).CurrentProject
    if (-not $project) { throw (T "MsgConnectFirst") }

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
                $items += Read-UmacItem -Obj $obj -Source $comp.Name -Kind $comp.Kind
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

        $first = $null
        if (Test-UmacEnumerable $value) {
            $n = 0
            foreach ($x in $value) { if ($null -eq $first) { $first = $x }; $n++ }
            [void]$sb.AppendLine("    elements : $n")
        }
        if ($null -ne $first) {
            [void]$sb.AppendLine("    element : $($first.GetType().FullName)")
            Add-UmacTypeMembers -Sb $sb -Type $first.GetType() -Indent "      "
        }
    }
    return $sb.ToString()
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
    # SecureString (mot de passe d'un utilisateur local) recoit le mot de passe initial.
    param($Composition, [string]$Name, [System.Security.SecureString]$Password)

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
            } elseif ($ps[$i].HasDefaultValue) {
                $callArgs[$i] = $ps[$i].DefaultValue
            } elseif ($pt.IsValueType) {
                $callArgs[$i] = [Activator]::CreateInstance($pt)
            } else {
                $callArgs[$i] = $null
            }
        }

        try { return ,$m.Invoke($Composition, $callArgs) }
        catch { throw (Get-InnermostException $_.Exception) }
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
        catch { throw (Get-InnermostException $_.Exception) }
    }
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

function Import-UmacConfig {
    # Importe les roles personnalises puis les utilisateurs (avec leurs relations) depuis un
    # fichier produit par Export-UmacConfig. Sans -Commit : simulation, rien n'est ecrit.
    # Avec -Commit : ecriture sous ExclusiveAccess + Transaction (annulee en cas d'erreur fatale).
    param(
        [string]$Path,
        [bool]$Commit,
        [System.Security.SecureString]$InitialPassword
    )

    $bundle = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $bundle.PSObject.Properties['items'] -or
        -not $bundle.PSObject.Properties['format'] -or $bundle.format -ne $Script:UmacFileFormat) {
        throw (T "MsgUmacBadFile")
    }

    $items = @($bundle.items)
    $roles = @($items | Where-Object { $_.kind -eq 'CustomRole' })
    $users = @($items | Where-Object { $_.kind -eq 'User' })
    $ignored = $items.Length - $roles.Length - $users.Length
    $systemRoles = @($items | Where-Object { $_.kind -eq 'SystemRole' } | ForEach-Object { [string]$_.name })
    $mode = if ($Commit) { T "LogUmacModeCommit" } else { T "LogUmacModeDryRun" }
    Write-UmacLog ((T "LogUmacImportStart") -f $roles.Length, $users.Length, $ignored, $mode)

    $summary = @{ Created = 0; Existing = 0; Failed = 0; Assigned = 0; AssignFailed = 0 }
    $planned = @()

    $ea = $null
    $tr = $null
    if ($Commit) {
        $state = Get-AppState
        $ea = $state.TiaPortal.ExclusiveAccess((T "UmacExclusiveAccess"))
        $tr = $ea.Transaction($state.CurrentProject, "Import users & roles")
    }
    try {
        $ctx = Get-UmacImportContext -Kind 'CustomRole' -Prefer 'Custom' -Planned $planned
        $userCtx = Get-UmacImportContext -Kind 'User' -Prefer 'Project' -Planned $planned
        Write-UmacLog ((T "LogUmacTargets") -f
            $(if ($null -ne $ctx.Comp) { $ctx.Comp.GetType().Name } else { "-" }),
            $(if ($null -ne $userCtx.Comp) { $userCtx.Comp.GetType().Name } else { "-" }))

        # Les roles d'abord : les utilisateurs y font reference.
        foreach ($group in @(@{ Items = $roles; Kind = 'CustomRole'; Prefer = 'Custom' },
                             @{ Items = $users; Kind = 'User'; Prefer = 'Project' })) {
            foreach ($item in $group.Items) {
                $name = [string]$item.name
                if (-not $name) { continue }

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
                    Write-UmacLog ((T "LogUmacWouldCreate") -f $item.kind, $name)
                } else {
                    try {
                        $target = Invoke-UmacCreate -Composition $ctx.Comp -Name $name -Password $InitialPassword
                        $summary.Created++
                        Write-UmacLog ((T "LogUmacCreated") -f $item.kind, $name)
                    } catch {
                        $summary.Failed++
                        Write-UmacLog ((T "LogUmacCreateFailed") -f $item.kind, $name, $_.Exception.Message)
                        continue
                    }
                }

                if ($Commit) {
                    # La creation a pu invalider les objets lus avant : relire cible et index.
                    $fresh = Get-UmacImportContext -Kind $group.Kind -Prefer $group.Prefer -Planned @()
                    $lookup = $fresh.Lookup
                    if ($fresh.Existing.ContainsKey($name)) { $target = $fresh.Existing[$name] }
                }
                $rel = Set-UmacRelations -Target $target -Item $item -Lookup $lookup -Commit $Commit -RefreshKind $group.Kind -RefreshPrefer $group.Prefer -SkipNames $systemRoles
                $summary.Assigned += $rel.Assigned
                $summary.AssignFailed += $rel.Failed
            }
        }

        if ($Commit) { $tr.CommitOnDispose() }
    } finally {
        if ($tr) { $tr.Dispose() }
        if ($ea) { $ea.Dispose() }
    }

    Write-UmacLog ((T "LogUmacImportDone") -f $summary.Created, $summary.Existing, $summary.Failed, $summary.Assigned, $summary.AssignFailed)
    return $summary
}
