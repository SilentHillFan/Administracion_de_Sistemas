$FTP_ROOT = "C:\inetpub\ftproot"
$FTP_ANON = "C:\inetpub\ftpanon"
$GRUPOS = @("reprobados", "recursadores")

function Set-FolderACL {
    param([string]$Path, [array]$Rules)

    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)

    foreach ($rule in $Rules) {
        $identity = $rule.Identity
        try {
            if ($identity -eq "Administrators") {
                $resolved = New-Object System.Security.Principal.NTAccount("BUILTIN\Administrators")
            } elseif ($identity -in @("SYSTEM", "IUSR", "NETWORK SERVICE")) {
                $resolved = New-Object System.Security.Principal.NTAccount("NT AUTHORITY\$identity")
            } else {
                $resolved = New-Object System.Security.Principal.NTAccount("$env:COMPUTERNAME\$identity")
            }
            $resolved.Translate([System.Security.Principal.SecurityIdentifier]) | Out-Null
        } catch {
            Write-Host "  [ERROR] No se pudo resolver '$identity'"
            continue
        }
        $ace = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $resolved,
            [System.Security.AccessControl.FileSystemRights]$rule.Rights,
            "ContainerInherit,ObjectInherit",
            "None",
            "Allow"
        )
        $acl.AddAccessRule($ace)
    }
    try {
        Set-Acl -Path $Path -AclObject $acl -ErrorAction Stop
    } catch {
        Write-Host "  [ERROR] No se pudieron aplicar permisos a $Path"
    }
}

function Set-FtpAuthRules {
    param([string]$SiteName, [array]$Rules, [string]$Location = "")

    $configPath = "$env:SystemRoot\System32\inetsrv\config\applicationHost.config"

    Stop-Service -Name "W3SVC"  -Force -ErrorAction SilentlyContinue
    Stop-Service -Name "FTPSVC" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    [xml]$config = Get-Content $configPath

    $locationAttr = if ($Location -eq "") { $SiteName } else { "$SiteName/$Location" }
    $locationNode = $config.configuration.SelectSingleNode("location[@path='$locationAttr']")

    if (-not $locationNode) {
        $locationNode = $config.CreateElement("location")
        $locationNode.SetAttribute("path", $locationAttr)
        $locationNode.SetAttribute("overrideMode", "Allow")
        $config.configuration.AppendChild($locationNode) | Out-Null
    }

    $ftpNode = $locationNode.SelectSingleNode("system.ftpServer")
    if (-not $ftpNode) {
        $ftpNode = $config.CreateElement("system.ftpServer")
        $locationNode.AppendChild($ftpNode) | Out-Null
    }
    $secNode = $ftpNode.SelectSingleNode("security")
    if (-not $secNode) {
        $secNode = $config.CreateElement("security")
        $ftpNode.AppendChild($secNode) | Out-Null
    }
    $authNode = $secNode.SelectSingleNode("authorization")
    if (-not $authNode) {
        $authNode = $config.CreateElement("authorization")
        $secNode.AppendChild($authNode) | Out-Null
    }
    $authNode.RemoveAll()

    foreach ($rule in $Rules) {
        $addNode = $config.CreateElement("add")
        $addNode.SetAttribute("accessType",  "Allow")
        $addNode.SetAttribute("users",        $rule.users)
        $addNode.SetAttribute("roles",        $rule.roles)
        $addNode.SetAttribute("permissions",  $rule.permissions)
        $authNode.AppendChild($addNode) | Out-Null
    }

    $config.Save($configPath)

    Start-Service -Name "W3SVC"  -ErrorAction SilentlyContinue
    Start-Service -Name "FTPSVC" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Set-FtpUserIsolation {
    param([string]$SiteName, [string]$Mode)

    $configPath = "$env:SystemRoot\System32\inetsrv\config\applicationHost.config"

    Stop-Service -Name "FTPSVC" -Force -ErrorAction SilentlyContinue
    Stop-Service -Name "W3SVC"  -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    [xml]$config = Get-Content $configPath
    $site = $config.configuration.'system.applicationHost'.sites.site |
            Where-Object { $_.name -eq $SiteName }

    $ftpServer = $site.SelectSingleNode("ftpServer")
    if (-not $ftpServer) {
        $ftpServer = $config.CreateElement("ftpServer")
        $site.AppendChild($ftpServer) | Out-Null
    }

    $userIsolation = $ftpServer.SelectSingleNode("userIsolation")
    if (-not $userIsolation) {
        $userIsolation = $config.CreateElement("userIsolation")
        $ftpServer.AppendChild($userIsolation) | Out-Null
    }

    $userIsolation.SetAttribute("mode", $Mode)
    $config.Save($configPath)
    Write-Host "    [OK] Modo de aislamiento configurado: $Mode"

    Start-Service -Name "W3SVC"  -ErrorAction SilentlyContinue
    Start-Service -Name "FTPSVC" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Crear-Estructura-Base {
    # IIS FTP con IsolateAllDirectories y usuarios locales busca el home en:
    # <FtpRoot>\<COMPUTERNAME>\<usuario>  (NO en LocalUser)
    # LocalUser se mantiene solo para anonymous (Public)
    foreach ($dir in @(
        "$FTP_ROOT\general", "$FTP_ROOT\reprobados", "$FTP_ROOT\recursadores",
        "$FTP_ROOT\personal",
        "$FTP_ANON\LocalUser", "$FTP_ANON\LocalUser\Public",
        "$FTP_ANON\$env:COMPUTERNAME"
    )) {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }

    foreach ($grupo in $GRUPOS) {
        if (-not (Get-LocalGroup -Name $grupo -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $grupo | Out-Null
            Write-Host "Grupo '$grupo' creado."
        }
    }

    Set-FolderACL -Path "$FTP_ROOT\general" -Rules @(
        @{ Identity = "SYSTEM";         Rights = "FullControl"    },
        @{ Identity = "Administrators"; Rights = "FullControl"    },
        @{ Identity = "IUSR";           Rights = "ReadAndExecute" },
        @{ Identity = "reprobados";     Rights = "Modify"         },
        @{ Identity = "recursadores";   Rights = "Modify"         }
    )

    foreach ($grupo in $GRUPOS) {
        Set-FolderACL -Path "$FTP_ROOT\$grupo" -Rules @(
            @{ Identity = "SYSTEM";         Rights = "FullControl" },
            @{ Identity = "Administrators"; Rights = "FullControl" },
            @{ Identity = $grupo;           Rights = "Modify"      }
        )
    }

    Set-FolderACL -Path $FTP_ANON -Rules @(
        @{ Identity = "SYSTEM";          Rights = "FullControl"    },
        @{ Identity = "Administrators";  Rights = "FullControl"    },
        @{ Identity = "IUSR";            Rights = "ReadAndExecute" },
        @{ Identity = "NETWORK SERVICE"; Rights = "ReadAndExecute" }
    )

    Set-FolderACL -Path "$FTP_ANON\LocalUser" -Rules @(
        @{ Identity = "SYSTEM";          Rights = "FullControl"    },
        @{ Identity = "Administrators";  Rights = "FullControl"    },
        @{ Identity = "IUSR";            Rights = "ReadAndExecute" },
        @{ Identity = "NETWORK SERVICE"; Rights = "ReadAndExecute" }
    )

    Set-FolderACL -Path "$FTP_ANON\LocalUser\Public" -Rules @(
        @{ Identity = "SYSTEM";         Rights = "FullControl"    },
        @{ Identity = "Administrators"; Rights = "FullControl"    },
        @{ Identity = "IUSR";           Rights = "ReadAndExecute" }
    )

    Set-FolderACL -Path "$FTP_ANON\$env:COMPUTERNAME" -Rules @(
        @{ Identity = "SYSTEM";          Rights = "FullControl"    },
        @{ Identity = "Administrators";  Rights = "FullControl"    },
        @{ Identity = "IUSR";            Rights = "ReadAndExecute" },
        @{ Identity = "NETWORK SERVICE"; Rights = "ReadAndExecute" }
    )

    $anonJunction = "$FTP_ANON\LocalUser\Public\general"
    if (Test-Path $anonJunction) {
        $item = Get-Item $anonJunction -ErrorAction SilentlyContinue
        if (-not ($item.Attributes -match "ReparsePoint")) {
            Remove-Item $anonJunction -Force -Recurse
            cmd /c "mklink /J `"$anonJunction`" `"$FTP_ROOT\general`"" | Out-Null
        }
    } else {
        cmd /c "mklink /J `"$anonJunction`" `"$FTP_ROOT\general`"" | Out-Null
    }
}

function Opcion-Instalar-FTP {
    Write-Host "__________________________________________"
    Write-Host "Instalando componentes IIS FTP..."

    $features = @("Web-Server", "Web-Ftp-Server", "Web-Ftp-Service", "Web-Mgmt-Console")
    foreach ($feature in $features) {
        if ((Get-WindowsFeature -Name $feature).InstallState -ne "Installed") {
            Install-WindowsFeature -Name $feature -IncludeManagementTools | Out-Null
            Write-Host "$feature instalado."
        } else {
            Write-Host "$feature ya estaba instalado."
        }
    }

    Set-Service -Name "FTPSVC" -StartupType Automatic
    
    Write-Host "Instalacion completada."
    Write-Host "Ahora ve a la opcion 'Configurar FTP' para establecer la configuracion inicial."
    Read-Host "Presiona Enter para continuar"
}

function Opcion-Configurar-FTP {
    Write-Host "__________________________________________"
    Write-Host "Configurando sitio FTP..."
    
    $ftpInstalled = (Get-WindowsFeature -Name "Web-Ftp-Server").Installed
    if (-not $ftpInstalled) {
        Write-Host "[ERROR] Los componentes FTP no estan instalados."
        Write-Host "Primero debes usar la opcion 'Instalar componentes FTP' (opcion 1)."
        Read-Host "Presiona Enter para continuar"
        return
    }
    
    Import-Module WebAdministration -Force

    $sitioExistente = Get-WebSite -Name "FTP Site" -ErrorAction SilentlyContinue
    if ($sitioExistente) {
        Write-Host "Ya existe una configuracion de FTP."
        $respuesta = Read-Host "Deseas reconfigurar? Se borrara todo lo existente (s/n)"
        if ($respuesta -ne "s" -and $respuesta -ne "S") {
            Write-Host "Operacion cancelada."
            Read-Host "Presiona Enter para continuar"
            return
        }
        
        Stop-Service -Name "W3SVC" -Force -ErrorAction SilentlyContinue
        Stop-Service -Name "FTPSVC" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        
        Remove-WebSite -Name "FTP Site"
        
        $borrarEstructura = Read-Host "Deseas borrar tambien toda la estructura de carpetas? (s/n)"
        if ($borrarEstructura -eq "s" -or $borrarEstructura -eq "S") {
            if (Test-Path $FTP_ROOT) { Remove-Item $FTP_ROOT -Recurse -Force }
            if (Test-Path $FTP_ANON) { Remove-Item $FTP_ANON -Recurse -Force }
            Write-Host "Estructura de carpetas eliminada."
        }
    }

    if (-not (Test-Path $FTP_ROOT) -or -not (Test-Path $FTP_ANON)) {
        Crear-Estructura-Base
    } else {
        Write-Host "La estructura de carpetas ya existe."
        $recrear = Read-Host "Deseas recrear las ACLs y junctions? (s/n)"
        if ($recrear -eq "s" -or $recrear -eq "S") {
            Crear-Estructura-Base
        }
    }

    Stop-Service -Name "W3SVC" -Force -ErrorAction SilentlyContinue
    Stop-Service -Name "FTPSVC" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    Start-Service -Name "W3SVC" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    New-WebFtpSite -Name "FTP Site" -Port 21 -PhysicalPath $FTP_ANON | Out-Null
    
    Start-Sleep -Seconds 5

    Set-ItemProperty "IIS:\Sites\FTP Site" -Name ftpServer.security.ssl.controlChannelPolicy -Value 0
    Set-ItemProperty "IIS:\Sites\FTP Site" -Name ftpServer.security.ssl.dataChannelPolicy -Value 0
    Set-ItemProperty "IIS:\Sites\FTP Site" -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $true
    Set-ItemProperty "IIS:\Sites\FTP Site" -Name ftpServer.security.authentication.anonymousAuthentication.userName -Value "IUSR"
    Set-ItemProperty "IIS:\Sites\FTP Site" -Name ftpServer.security.authentication.basicAuthentication.enabled -Value $true

    Start-Sleep -Seconds 3

    Set-FtpUserIsolation -SiteName "FTP Site" -Mode "IsolateAllDirectories"

    Set-FtpAuthRules -SiteName "FTP Site" -Rules @(
        @{ users = "?"; roles = ""; permissions = "Read" },
        @{ users = "*"; roles = ""; permissions = "Read,Write" }
    )

    if (-not (Get-NetFirewallRule -DisplayName "FTP" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "FTP" -Direction Inbound -Protocol TCP -LocalPort 21 -Action Allow | Out-Null
        Write-Host "Regla de firewall creada."
    }

    Start-Service -Name "FTPSVC" -ErrorAction SilentlyContinue

    $state = (Get-WebSite -Name "FTP Site").State
    if ($state -eq "Started") {
        Write-Host "FTP configurado correctamente."
    } else {
        Write-Host "[ERROR] El sitio FTP no pudo iniciarse."
    }

    Read-Host "Presiona Enter para continuar"
}

function Opcion-Estado-FTP {
    Write-Host "__________________________________________"
    Write-Host "ESTADO DEL SERVICIO FTP:"
    Write-Host ""
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $sitio = Get-WebSite -Name "FTP Site" -ErrorAction SilentlyContinue
    if ($sitio) {
        Write-Host "  Nombre : $($sitio.Name)"
        Write-Host "  Estado : $($sitio.State)"
        Write-Host "  Puerto : 21"
        Write-Host "  Ruta   : $FTP_ANON"
        
        $servicio = Get-Service -Name "FTPSVC" -ErrorAction SilentlyContinue
        Write-Host "  Servicio FTPSVC: $($servicio.Status)"
    } else {
        Write-Host "El sitio FTP no existe. Configuralo primero."
    }
    Write-Host ""
    Read-Host "Presiona Enter para continuar"
}

function Opcion-Reiniciar-FTP {
    Write-Host "__________________________________________"
    Write-Host "Reiniciando FTP..."
    Restart-Service -Name "FTPSVC" -Force -ErrorAction SilentlyContinue
    $svc = Get-Service -Name "FTPSVC"
    if ($svc.Status -eq "Running") {
        Write-Host "FTP reiniciado correctamente."
    } else {
        Write-Host "[ERROR] FTP no pudo reiniciarse."
    }
    Read-Host "Presiona Enter para continuar"
}

function Verificar-FTP-Configurado {
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $ftpInstalled = (Get-WindowsFeature -Name "Web-Ftp-Server").Installed
    $sitio = Get-WebSite -Name "FTP Site" -ErrorAction SilentlyContinue
    if (-not $ftpInstalled) {
        Write-Host "IIS FTP no esta instalado. Ve a 'Instalar FTP' primero."
        Read-Host "Presiona Enter para continuar"
        return $false
    }
    if (-not $sitio) {
        Write-Host "El sitio FTP no esta configurado. Ve a 'Configurar FTP' primero."
        Read-Host "Presiona Enter para continuar"
        return $false
    }
    if ($sitio.State -ne "Started") {
        Write-Host "El sitio FTP no esta iniciado. Ve a 'Reiniciar servicio'."
        Read-Host "Presiona Enter para continuar"
        return $false
    }
    return $true
}

function Opcion-Crear-Usuarios {
    if (-not (Verificar-FTP-Configurado)) { return }
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    Write-Host "++++++++++++++++++++++++++++++++++++++++++++++++++"
    Write-Host "            CREAR USUARIOS FTP"
    Write-Host "++++++++++++++++++++++++++++++++++++++++++++++++++"

    $N = Read-Host "Cuantos usuarios deseas crear (max 10)"
    if (-not ($N -match '^\d+$') -or [int]$N -lt 1) {
        Write-Host "Numero invalido."
        Read-Host "Presiona Enter para continuar"
        return
    }
    if ([int]$N -gt 10) {
        Write-Host "No puedes crear mas de 10 usuarios a la vez."
        Read-Host "Presiona Enter para continuar"
        return
    }

    for ($i = 1; $i -le [int]$N; $i++) {
        Write-Host ""
        Write-Host "--- Usuario $i de $N ---"

        do {
            $USERNAME = Read-Host "Nombre de usuario"
            if ([string]::IsNullOrWhiteSpace($USERNAME)) {
                Write-Host "El nombre de usuario no puede estar vacio. Intenta de nuevo."
            }
        } while ([string]::IsNullOrWhiteSpace($USERNAME))

        if (Get-LocalUser -Name $USERNAME -ErrorAction SilentlyContinue) {
            Write-Host "El usuario '$USERNAME' ya existe, saltando..."
            continue
        }

        do {
            $PASSWORD = Read-Host "Contrasena" -AsSecureString
            $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PASSWORD)
            $PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
            
            if ([string]::IsNullOrWhiteSpace($PlainPassword)) {
                Write-Host "La contrasena no puede estar vacia. Intenta de nuevo."
            }
        } while ([string]::IsNullOrWhiteSpace($PlainPassword))

        Write-Host "Grupo:"
        Write-Host "  1) reprobados"
        Write-Host "  2) recursadores"
        do {
            $GRUPO_SEL = Read-Host "Selecciona (1 o 2)"
            if ($GRUPO_SEL -eq "1") { 
                $GRUPO = "reprobados"
                break
            }
            elseif ($GRUPO_SEL -eq "2") { 
                $GRUPO = "recursadores"
                break
            }
            else {
                Write-Host "Opcion invalida. Debe ser 1 o 2."
            }
        } while ($true)

        try {
            New-LocalUser -Name $USERNAME -Password $PASSWORD -PasswordNeverExpires -ErrorAction Stop | Out-Null
        } catch {
            Write-Host "[ERROR] No se pudo crear '$USERNAME'. La contrasena debe tener mayusculas, minusculas, numeros y simbolos."
            continue
        }

        if (-not (Get-LocalUser -Name $USERNAME -ErrorAction SilentlyContinue)) {
            Write-Host "[ERROR] No se pudo crear '$USERNAME'."
            continue
        }

        Add-LocalGroupMember -Group $GRUPO -Member $USERNAME -ErrorAction SilentlyContinue

        # IIS FTP con IsolateAllDirectories y usuarios locales busca el home en:
        # <FtpRoot>\<COMPUTERNAME>\<usuario>  (NO en LocalUser\<usuario>)
        $USER_FTP_DIR = "$FTP_ANON\$env:COMPUTERNAME\$USERNAME"
        if (Test-Path $USER_FTP_DIR) {
            Remove-Item $USER_FTP_DIR -Recurse -Force
        }
        New-Item -ItemType Directory -Path $USER_FTP_DIR -Force | Out-Null

        $personalDir = "$FTP_ROOT\personal\$USERNAME"
        if (-not (Test-Path $personalDir)) {
            New-Item -ItemType Directory -Path $personalDir -Force | Out-Null
        }

        Set-FolderACL -Path $personalDir -Rules @(
            @{ Identity = "SYSTEM";         Rights = "FullControl" },
            @{ Identity = "Administrators"; Rights = "FullControl" },
            @{ Identity = $USERNAME;        Rights = "Modify"      }
        )

        $generalJunction = "$USER_FTP_DIR\general"
        if (Test-Path $generalJunction) {
            Remove-Item $generalJunction -Force -Recurse
        }
        cmd /c "mklink /J `"$generalJunction`" `"$FTP_ROOT\general`"" | Out-Null

        $grupoJunction = "$USER_FTP_DIR\$GRUPO"
        if (Test-Path $grupoJunction) {
            Remove-Item $grupoJunction -Force -Recurse
        }
        cmd /c "mklink /J `"$grupoJunction`" `"$FTP_ROOT\$GRUPO`"" | Out-Null

        $personalJunction = "$USER_FTP_DIR\$USERNAME"
        if (Test-Path $personalJunction) {
            Remove-Item $personalJunction -Force -Recurse
        }
        cmd /c "mklink /J `"$personalJunction`" `"$FTP_ROOT\personal\$USERNAME`"" | Out-Null

        Set-FolderACL -Path $USER_FTP_DIR -Rules @(
            @{ Identity = "SYSTEM";          Rights = "FullControl"    },
            @{ Identity = "Administrators";  Rights = "FullControl"    },
            @{ Identity = $USERNAME;         Rights = "Modify"         },
            @{ Identity = "IUSR";            Rights = "ReadAndExecute" },
            @{ Identity = "NETWORK SERVICE"; Rights = "ReadAndExecute" }
        )

        # Agregar regla de autorizacion FTP a nivel de sitio para este usuario
        # (IsolateAllDirectories no usa sub-locations; la auth es a nivel de sitio)
        $configPath = "$env:SystemRoot\System32\inetsrv\config\applicationHost.config"
        [xml]$config = Get-Content $configPath
        $locationNode = $config.configuration.SelectSingleNode("location[@path='FTP Site']")
        if (-not $locationNode) {
            $locationNode = $config.CreateElement("location")
            $locationNode.SetAttribute("path", "FTP Site")
            $locationNode.SetAttribute("overrideMode", "Allow")
            $config.configuration.AppendChild($locationNode) | Out-Null
        }
        $ftpNode = $locationNode.SelectSingleNode("system.ftpServer")
        if (-not $ftpNode) {
            $ftpNode = $config.CreateElement("system.ftpServer")
            $locationNode.AppendChild($ftpNode) | Out-Null
        }
        $secNode = $ftpNode.SelectSingleNode("security")
        if (-not $secNode) {
            $secNode = $config.CreateElement("security")
            $ftpNode.AppendChild($secNode) | Out-Null
        }
        $authNode = $secNode.SelectSingleNode("authorization")
        if (-not $authNode) {
            $authNode = $config.CreateElement("authorization")
            $secNode.AppendChild($authNode) | Out-Null
        }
        # Verificar que no exista ya una regla para este usuario
        $existingRule = $authNode.SelectSingleNode("add[@users='$USERNAME']")
        if (-not $existingRule) {
            $addNode = $config.CreateElement("add")
            $addNode.SetAttribute("accessType",  "Allow")
            $addNode.SetAttribute("users",        $USERNAME)
            $addNode.SetAttribute("roles",        "")
            $addNode.SetAttribute("permissions",  "Read, Write")
            $authNode.AppendChild($addNode) | Out-Null
            $config.Save($configPath)
        }

        Write-Host "Usuario '$USERNAME' creado en grupo '$GRUPO'."
        Write-Host "  Home FTP: $USER_FTP_DIR"
    }

    Read-Host "Presiona Enter para continuar"
}

function Opcion-Ver-Usuarios {
    if (-not (Verificar-FTP-Configurado)) { return }
    Write-Host "__________________________________________"
    Write-Host "USUARIOS FTP REGISTRADOS:"
    Write-Host ""

    $encontrado = $false
    $i = 1
    foreach ($grupo in $GRUPOS) {
        $miembros = Get-LocalGroupMember -Group $grupo -ErrorAction SilentlyContinue
        foreach ($miembro in $miembros) {
            $nombre = $miembro.Name.Split("\")[-1]
            $ftpDir    = "$FTP_ANON\$env:COMPUTERNAME\$nombre"
            $homeExists = Test-Path $ftpDir
            $homeStatus = if ($homeExists) { "OK" } else { "SIN HOME" }
            Write-Host "  $i) $nombre [grupo: $grupo] [$homeStatus]"
            $i++
            $encontrado = $true
        }
    }

    if (-not $encontrado) { Write-Host "No hay usuarios registrados." }
    Write-Host ""
    Read-Host "Presiona Enter para continuar"
}

function Opcion-Eliminar-Usuario {
    if (-not (Verificar-FTP-Configurado)) { return }
    Write-Host "__________________________________________"

    $lista = @()
    foreach ($grupo in $GRUPOS) {
        $miembros = Get-LocalGroupMember -Group $grupo -ErrorAction SilentlyContinue
        foreach ($miembro in $miembros) {
            $nombre = $miembro.Name.Split("\")[-1]
            $lista += [PSCustomObject]@{ Nombre = $nombre; Grupo = $grupo }
        }
    }

    if ($lista.Count -eq 0) {
        Write-Host "No hay usuarios registrados."
        Read-Host "Presiona Enter para continuar"
        return
    }

    Write-Host "Usuarios registrados:"
    Write-Host ""
    for ($i = 0; $i -lt $lista.Count; $i++) {
        Write-Host "  $($i+1)) $($lista[$i].Nombre)  [grupo: $($lista[$i].Grupo)]"
    }
    Write-Host "  0) Cancelar"
    Write-Host ""

    do {
        $SEL = Read-Host "Selecciona el numero del usuario a eliminar"
        if ($SEL -eq "0") {
            Write-Host "Operacion cancelada."
            Read-Host "Presiona Enter para continuar"
            return
        }
    } while (-not ($SEL -match '^\d+$') -or [int]$SEL -lt 1 -or [int]$SEL -gt $lista.Count)

    $USERNAME = $lista[[int]$SEL - 1].Nombre
    $GRUPO    = $lista[[int]$SEL - 1].Grupo

    $CONFIRM = Read-Host "Confirmas eliminar '$USERNAME'? (s/n)"
    if ($CONFIRM -ne "s" -and $CONFIRM -ne "S") {
        Write-Host "Operacion cancelada."
        Read-Host "Presiona Enter para continuar"
        return
    }

    Remove-LocalGroupMember -Group $GRUPO -Member $USERNAME -ErrorAction SilentlyContinue
    Remove-LocalUser -Name $USERNAME -ErrorAction SilentlyContinue

    $USER_FTP_DIR = "$FTP_ANON\$env:COMPUTERNAME\$USERNAME"
    $personalDir  = "$FTP_ROOT\personal\$USERNAME"
    if (Test-Path $USER_FTP_DIR) { Remove-Item $USER_FTP_DIR -Recurse -Force }
    if (Test-Path $personalDir)  { Remove-Item $personalDir  -Recurse -Force }

    Write-Host "Usuario '$USERNAME' eliminado correctamente."
    Read-Host "Presiona Enter para continuar"
}

function Opcion-Cambiar-Grupo {
    if (-not (Verificar-FTP-Configurado)) { return }
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    Write-Host "__________________________________________"

    $lista = @()
    foreach ($grupo in $GRUPOS) {
        $miembros = Get-LocalGroupMember -Group $grupo -ErrorAction SilentlyContinue
        foreach ($miembro in $miembros) {
            $nombre = $miembro.Name.Split("\")[-1]
            $lista += [PSCustomObject]@{ Nombre = $nombre; Grupo = $grupo }
        }
    }

    if ($lista.Count -eq 0) {
        Write-Host "No hay usuarios registrados."
        Read-Host "Presiona Enter para continuar"
        return
    }

    Write-Host "Usuarios registrados:"
    Write-Host ""
    for ($i = 0; $i -lt $lista.Count; $i++) {
        Write-Host "  $($i+1)) $($lista[$i].Nombre)  [grupo actual: $($lista[$i].Grupo)]"
    }
    Write-Host "  0) Cancelar"
    Write-Host ""

    do {
        $SEL = Read-Host "Selecciona el numero del usuario a cambiar de grupo"
        if ($SEL -eq "0") {
            Write-Host "Operacion cancelada."
            Read-Host "Presiona Enter para continuar"
            return
        }
    } while (-not ($SEL -match '^\d+$') -or [int]$SEL -lt 1 -or [int]$SEL -gt $lista.Count)

    $USERNAME     = $lista[[int]$SEL - 1].Nombre
    $GRUPO_ACTUAL = $lista[[int]$SEL - 1].Grupo

    Write-Host ""
    Write-Host "Nuevo grupo para '$USERNAME':"
    Write-Host "  1) reprobados"
    Write-Host "  2) recursadores"
    do {
        $GRUPO_SEL = Read-Host "Selecciona (1 o 2)"
        if ($GRUPO_SEL -eq "1") { 
            $NUEVO_GRUPO = "reprobados"
            break
        }
        elseif ($GRUPO_SEL -eq "2") { 
            $NUEVO_GRUPO = "recursadores"
            break
        }
        else {
            Write-Host "Opcion invalida. Debe ser 1 o 2."
        }
    } while ($true)

    if ($NUEVO_GRUPO -eq $GRUPO_ACTUAL) {
        Write-Host "El usuario ya pertenece a ese grupo."
        Read-Host "Presiona Enter para continuar"
        return
    }

    $USER_FTP_DIR = "$FTP_ANON\$env:COMPUTERNAME\$USERNAME"
    $oldJunction  = "$USER_FTP_DIR\$GRUPO_ACTUAL"
    if (Test-Path $oldJunction) {
        cmd /c "rmdir `"$oldJunction`"" | Out-Null
    }

    Remove-LocalGroupMember -Group $GRUPO_ACTUAL -Member $USERNAME -ErrorAction SilentlyContinue
    Add-LocalGroupMember -Group $NUEVO_GRUPO -Member $USERNAME -ErrorAction SilentlyContinue

    $newJunction = "$USER_FTP_DIR\$NUEVO_GRUPO"
    if (-not (Test-Path $newJunction)) {
        cmd /c "mklink /J `"$newJunction`" `"$FTP_ROOT\$NUEVO_GRUPO`"" | Out-Null
    }

    Write-Host "Usuario '$USERNAME' cambiado de '$GRUPO_ACTUAL' a '$NUEVO_GRUPO'."
    Read-Host "Presiona Enter para continuar"
}