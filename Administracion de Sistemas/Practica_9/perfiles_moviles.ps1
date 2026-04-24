#Requires -RunAsAdministrator

Import-Module ActiveDirectory -ErrorAction Stop

$Dominio  = (Get-ADDomain).DNSRoot
$DCPath   = (Get-ADDomain).DistinguishedName
$NetBIOS  = (Get-ADDomain).NetBIOSName
$RutaPerfiles = "C:\Perfiles"

function Write-Log {
    param([string]$Mensaje, [string]$Color = "White")
    $hora = Get-Date -Format "HH:mm"
    Write-Host "  $hora  $Mensaje" -ForegroundColor $Color
}

function Configurar-PerfilesMoviles {
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "     PERFILES MOVILES - Dominio: $Dominio" -ForegroundColor Yellow
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""

    # 1. Crear carpeta raiz de perfiles
    Write-Log "[1] Creando carpeta raiz de perfiles: $RutaPerfiles" "Yellow"
    if (-not (Test-Path $RutaPerfiles)) {
        New-Item -ItemType Directory -Path $RutaPerfiles -Force | Out-Null
        Write-Log "  [+] Carpeta creada: $RutaPerfiles" "Green"
    } else {
        Write-Log "  [.] Ya existe: $RutaPerfiles" "Gray"
    }

    # 2. Compartir la carpeta como recurso de red
    Write-Log "[2] Compartiendo carpeta como Perfiles$..." "Yellow"
    $share = Get-SmbShare -Name "Perfiles$" -ErrorAction SilentlyContinue
    if (-not $share) {
        New-SmbShare -Name "Perfiles$" -Path $RutaPerfiles `
            -FullAccess "Everyone" -Description "Perfiles Moviles del Dominio" | Out-Null
        Write-Log "  [+] Recurso compartido: \\$env:COMPUTERNAME\Perfiles$" "Green"
    } else {
        Write-Log "  [.] Ya compartido: \\$env:COMPUTERNAME\Perfiles$" "Gray"
    }

    # 3. Permisos NTFS en la carpeta raiz
    Write-Log "[3] Configurando permisos NTFS en $RutaPerfiles..." "Yellow"
    $acl = Get-Acl $RutaPerfiles
    $acl.SetAccessRuleProtection($false, $true)

    $reglaAuthUsers = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "Authenticated Users",
        "Modify",
        "ContainerInherit,ObjectInherit",
        "None",
        "Allow"
    )
    $acl.AddAccessRule($reglaAuthUsers)
    Set-Acl -Path $RutaPerfiles -AclObject $acl
    Write-Log "  [+] Permisos NTFS aplicados (Authenticated Users - Modify)." "Green"

    # 4. Obtener todos los usuarios del dominio (excepto cuentas de sistema)
    Write-Log "[4] Obteniendo usuarios del dominio..." "Yellow"
    $usuarios = Get-ADUser -Filter {Enabled -eq $true} -Properties ProfilePath |
        Where-Object { $_.SamAccountName -notin @("Administrator","Guest","krbtgt","winserv") }

    Write-Log "  [+] $($usuarios.Count) usuarios encontrados." "Green"

    # 5. Crear carpeta y asignar perfil movil a cada usuario
    Write-Log "[5] Creando carpetas de perfil y asignando ruta en AD..." "Yellow"
    foreach ($u in $usuarios) {
        $rutaPerfil = "$RutaPerfiles\$($u.SamAccountName)"

        if (-not (Test-Path $rutaPerfil)) {
            New-Item -ItemType Directory -Path $rutaPerfil -Force | Out-Null

            # Permisos: solo el usuario y Administradores
            $aclU = Get-Acl $rutaPerfil
            $aclU.SetAccessRuleProtection($true, $false)

            $reglaAdmin = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "Administrators", "FullControl",
                "ContainerInherit,ObjectInherit", "None", "Allow"
            )
            $reglaUsuario = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "$NetBIOS\$($u.SamAccountName)", "FullControl",
                "ContainerInherit,ObjectInherit", "None", "Allow"
            )
            $aclU.AddAccessRule($reglaAdmin)
            $aclU.AddAccessRule($reglaUsuario)
            Set-Acl -Path $rutaPerfil -AclObject $aclU
            Write-Log "  [+] Carpeta creada: $rutaPerfil" "Green"
        } else {
            Write-Log "  [.] Ya existe: $rutaPerfil" "Gray"
        }

        # Asignar ruta de perfil movil en AD (Windows agrega .V6 automaticamente)
        $rutaAD = "\\$env:COMPUTERNAME\Perfiles$\$($u.SamAccountName)"
        Set-ADUser -Identity $u.SamAccountName -ProfilePath $rutaAD
        Write-Log "  [+] ProfilePath asignado: $rutaAD" "Cyan"
    }

    Write-Log "" "White"
    Write-Log "[OK] Perfiles moviles configurados." "Green"
    Write-Log "     Carpeta raiz  : $RutaPerfiles" "Gray"
    Write-Log "     Recurso red   : \\$env:COMPUTERNAME\Perfiles$" "Gray"
    Write-Log "     Sufijo Windows: .V6 (se agrega automaticamente en Win10/11)" "Gray"
    Write-Host ""
}

function Verificar-PerfilesMoviles {
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "     VERIFICACION DE PERFILES MOVILES" -ForegroundColor Yellow
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""

    Write-Log "[V1] Carpetas en $RutaPerfiles :" "Yellow"
    if (Test-Path $RutaPerfiles) {
        Get-ChildItem $RutaPerfiles -Directory | ForEach-Object {
            $archivos = (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue).Count
            Write-Log "  $($_.Name)  ($archivos archivos)" "Gray"
        }
    } else {
        Write-Log "  [!] Carpeta no existe. Ejecuta opcion 1 primero." "Red"
    }

    Write-Host ""
    Write-Log "[V2] ProfilePath en Active Directory:" "Yellow"
    Get-ADUser -Filter {Enabled -eq $true} -Properties ProfilePath |
        Where-Object { $_.SamAccountName -notin @("Administrator","Guest","krbtgt","winserv") } |
        Select-Object SamAccountName, ProfilePath |
        Format-Table -AutoSize | Out-String | Write-Host

    Write-Host ""
}

function Agregar-UsuarioPerfil {
    $sam = Read-Host "  Nombre de usuario (SamAccountName)"
    $u = Get-ADUser -Filter "SamAccountName -eq '$sam'" -Properties ProfilePath -ErrorAction SilentlyContinue
    if (-not $u) {
        Write-Log "  [!] Usuario '$sam' no encontrado en AD." "Red"
        return
    }

    $rutaPerfil = "$RutaPerfiles\$sam"
    if (-not (Test-Path $rutaPerfil)) {
        New-Item -ItemType Directory -Path $rutaPerfil -Force | Out-Null

        $aclU = Get-Acl $rutaPerfil
        $aclU.SetAccessRuleProtection($true, $false)
        $reglaAdmin = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "Administrators", "FullControl",
            "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $reglaUsuario = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "$NetBIOS\$sam", "FullControl",
            "ContainerInherit,ObjectInherit", "None", "Allow"
        )
        $aclU.AddAccessRule($reglaAdmin)
        $aclU.AddAccessRule($reglaUsuario)
        Set-Acl -Path $rutaPerfil -AclObject $aclU
        Write-Log "  [+] Carpeta creada: $rutaPerfil" "Green"
    }

    $rutaAD = "\\$env:COMPUTERNAME\Perfiles$\$sam"
    Set-ADUser -Identity $sam -ProfilePath $rutaAD
    Write-Log "  [+] ProfilePath asignado a '$sam': $rutaAD" "Green"
}

do {
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "     PERFILES MOVILES - $Dominio" -ForegroundColor Yellow
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "  [1] Configurar perfiles moviles para TODOS los usuarios"
    Write-Host "  [2] Verificar estado actual"
    Write-Host "  [3] Agregar perfil movil a un usuario especifico"
    Write-Host "  [S] Salir"
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""

    $op = Read-Host "  Selecciona opcion"

    switch ($op.ToUpper()) {
        "1" { Configurar-PerfilesMoviles }
        "2" { Verificar-PerfilesMoviles }
        "3" { Agregar-UsuarioPerfil }
        "S" { break }
        default { Write-Host "  Opcion no valida." -ForegroundColor Red }
    }

    if ($op.ToUpper() -ne "S") {
        Read-Host "`n  Presiona ENTER para continuar"
    }

} while ($op.ToUpper() -ne "S")
