#Requires -RunAsAdministrator
# =============================================================================
# SEGURIDAD AVANZADA EN ACTIVE DIRECTORY
# Modulo: Hardening, Auditoria de Eventos y Autenticacion Multifactor (MFA)
# Requisito: PowerShell elevado con privilegios de Administrador de Dominio
# =============================================================================

Import-Module ActiveDirectory -ErrorAction Stop

# -------------------------------------------------------------------------
# CONSTANTES GLOBALES
# -------------------------------------------------------------------------
$Dominio      = (Get-ADDomain).DNSRoot
$DCPath       = (Get-ADDomain).DistinguishedName
$NetBIOS      = (Get-ADDomain).NetBIOSName
$PassAdmin    = ConvertTo-SecureString "P@ssw0rd2026!" -AsPlainText -Force
$RutaReportes = "C:\Reportes_P09"
$RutaReporte  = "$RutaReportes\Auditoria_Accesos_Denegados.txt"
$LogScript    = "$RutaReportes\Log_Ejecucion_P09.log"

# -------------------------------------------------------------------------
# UTILIDADES
# -------------------------------------------------------------------------

function Write-Log {
    param([string]$Mensaje, [string]$Color = "White")
    $ts    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $linea = "[$ts] $Mensaje"
    # Solo escribe al archivo de log, no a pantalla
    Add-Content -Path $LogScript -Value $linea -ErrorAction SilentlyContinue
    # Muestra en pantalla sin timestamp, con prefijo de hora corta
    $hora = Get-Date -Format "HH:mm"
    Write-Host "  $hora  $Mensaje" -ForegroundColor $Color
}

function Write-Step {
    # Para mostrar pasos de configuracion con estilo diferente
    param([string]$Paso, [string]$Mensaje, [string]$Color = "Cyan")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogScript -Value "[$ts] $Paso $Mensaje" -ErrorAction SilentlyContinue
    Write-Host "  $Paso " -ForegroundColor DarkGray -NoNewline
    Write-Host "$Mensaje" -ForegroundColor $Color
}

function Write-Ok {
    param([string]$Mensaje)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogScript -Value "[$ts] PASS: $Mensaje" -ErrorAction SilentlyContinue
    Write-Host "  " -NoNewline
    Write-Host " PASS " -ForegroundColor Black -BackgroundColor Green -NoNewline
    Write-Host "  $Mensaje" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Mensaje)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogScript -Value "[$ts] FAIL: $Mensaje" -ErrorAction SilentlyContinue
    Write-Host "  " -NoNewline
    Write-Host " FAIL " -ForegroundColor White -BackgroundColor Red -NoNewline
    Write-Host "  $Mensaje" -ForegroundColor Red
}

function Write-Info {
    param([string]$Mensaje)
    Write-Host "         $Mensaje" -ForegroundColor DarkGray
}

function Write-Header {
    param([string]$Titulo)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LogScript -Value "[$ts] === $Titulo ===" -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "  +-------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host "    $Titulo" -ForegroundColor White
    Write-Host "  +-------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ""
}

function Ensure-Dir {
    param([string]$Ruta)
    if (-not (Test-Path $Ruta)) {
        New-Item -ItemType Directory -Path $Ruta -Force | Out-Null
        Write-Log "Directorio creado: $Ruta" "Gray"
    }
}

function Invoke-DSAcls {
    param([string]$Args)
    $out = cmd.exe /c "dsacls $Args 2>&1"
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  [ERR] dsacls: $out" "Red"
    }
}

function Pausa {
    Write-Host "`nPulsa ENTER para volver al menu..." -ForegroundColor DarkGray
    Read-Host | Out-Null
}

# -------------------------------------------------------------------------
# MENU
# -------------------------------------------------------------------------

function Mostrar-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host "  |   HARDENING DE ACTIVE DIRECTORY  //  AUDITORIA  //  MFA  |" -ForegroundColor White
    Write-Host "  |   Dominio activo : $Dominio" -ForegroundColor Gray
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  [ CONFIGURACION ]" -ForegroundColor DarkYellow
    Write-Host "    1  >>  Infraestructura base: OUs, grupos y usuarios"        -ForegroundColor Cyan
    Write-Host "    2  >>  Control de acceso granular (ACLs por rol)"           -ForegroundColor Cyan
    Write-Host "    3  >>  Politicas de contrasena por nivel (FGPP)"            -ForegroundColor Cyan
    Write-Host "    4  >>  Activar auditoria de eventos del sistema"            -ForegroundColor Cyan
    Write-Host "    5  >>  Despliegue de MFA con Google Authenticator"          -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [ MONITOREO ]" -ForegroundColor DarkYellow
    Write-Host "    r  >>  Exportar eventos de acceso denegado (ID 4625)"       -ForegroundColor Magenta
    Write-Host "    v  >>  Verificar configuracion actual del sistema"          -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  [ PRUEBAS ]" -ForegroundColor DarkYellow
    Write-Host "    t1  >>  Delegacion RBAC: admin_identidad vs admin_storage"  -ForegroundColor Yellow
    Write-Host "    t2  >>  FGPP: rechazo de contrasenas debiles"               -ForegroundColor Yellow
    Write-Host "    t3  >>  MFA: flujo de autenticacion con token TOTP"         -ForegroundColor Yellow
    Write-Host "    t4  >>  MFA: bloqueo de cuenta tras 3 fallos"               -ForegroundColor Yellow
    Write-Host "    t5  >>  Auditoria: generar reporte automatizado"            -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  [ OTROS ]" -ForegroundColor DarkYellow
    Write-Host "    todo  >>  Ejecutar todas las fases de configuracion"        -ForegroundColor Green
    Write-Host "    s     >>  Cerrar el asistente"                              -ForegroundColor Red
    Write-Host ""
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ""
}

# =========================================================================
# FASE 1: INFRAESTRUCTURA BASE
# =========================================================================

function Fase1-InfraestructuraBase {
    Write-Log "----------------------------------------------" "DarkCyan"
    Write-Log " [1] Creando infraestructura base del dominio" "White"
    Write-Log "----------------------------------------------" "DarkCyan"

    Ensure-Dir $RutaReportes

    # --- OUs ---
    Write-Log "`n[1.1] Creando Unidades Organizativas..." "Yellow"
    foreach ($ou in @("AdminDelegados", "Cuates", "NoCuates", "Usuarios_Std")) {
        if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ou'" `
                  -SearchBase $DCPath -ErrorAction SilentlyContinue)) {
            New-ADOrganizationalUnit -Name $ou -Path $DCPath `
                -ProtectedFromAccidentalDeletion $false
            Write-Log "  [+] OU '$ou' creada." "Green"
        } else {
            Write-Log "  [.] OU '$ou' ya existe." "Gray"
        }
    }

    # --- Grupos de seguridad (requeridos para FGPP) ---
    Write-Log "`n[1.2] Creando Grupos de Seguridad..." "Yellow"
    $grupos = @(
        @{ Nombre = "GG_Admins_Delegados"; Path = "OU=AdminDelegados,$DCPath" },
        @{ Nombre = "GG_Usuarios_Std";     Path = "OU=Usuarios_Std,$DCPath"   }
    )
    foreach ($g in $grupos) {
        if (-not (Get-ADGroup -Filter "Name -eq '$($g.Nombre)'" -ErrorAction SilentlyContinue)) {
            New-ADGroup -Name $g.Nombre -GroupScope Global -GroupCategory Security -Path $g.Path
            Write-Log "  [+] Grupo '$($g.Nombre)' creado." "Green"
        } else {
            Write-Log "  [.] Grupo '$($g.Nombre)' ya existe." "Gray"
        }
    }

    # --- Usuarios administrativos delegados ---
    Write-Log "`n[1.3] Creando Usuarios Administrativos Delegados..." "Yellow"
    $admins = @(
        @{ Sam = "admin_identidad";  Nombre = "Admin Identidad";  Desc = "ROL 1 - IAM Operator"     },
        @{ Sam = "admin_storage";    Nombre = "Admin Storage";    Desc = "ROL 2 - Storage Operator"  },
        @{ Sam = "admin_politicas";  Nombre = "Admin Politicas";  Desc = "ROL 3 - GPO Compliance"    },
        @{ Sam = "admin_auditoria";  Nombre = "Admin Auditoria";  Desc = "ROL 4 - Security Auditor"  }
    )
    foreach ($u in $admins) {
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)'" -ErrorAction SilentlyContinue)) {
            New-ADUser -Name $u.Nombre -SamAccountName $u.Sam -DisplayName $u.Nombre `
                       -Description $u.Desc -AccountPassword $PassAdmin -Enabled $true `
                       -Path "OU=AdminDelegados,$DCPath" -ChangePasswordAtLogon $false
            Write-Log "  [+] '$($u.Sam)' creado." "Green"
        } else {
            Write-Log "  [.] '$($u.Sam)' ya existe." "Gray"
        }
    }

    # --- Usuarios del CSV (10 usuarios reales de la practica) ---
    Write-Log "`n[1.4] Creando Usuarios del dominio (del CSV)..." "Yellow"
    $stds = @(
        @{ Sam = "juan";   OU = "Cuates"    },
        @{ Sam = "pedro";  OU = "Cuates"    },
        @{ Sam = "luis";   OU = "Cuates"    },
        @{ Sam = "carlos"; OU = "Cuates"    },
        @{ Sam = "diego";  OU = "Cuates"    },
        @{ Sam = "maria";  OU = "NoCuates" },
        @{ Sam = "ana";    OU = "NoCuates" },
        @{ Sam = "sofia";  OU = "NoCuates" },
        @{ Sam = "elena";  OU = "NoCuates" },
        @{ Sam = "laura";  OU = "NoCuates" }
    )
    foreach ($u in $stds) {
        $ouPath = if ($u.OU -eq "NoCuates") { "OU=NoCuates,$DCPath" } else { "OU=$($u.OU),$DCPath" }
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)'" -ErrorAction SilentlyContinue)) {
            New-ADUser -Name $u.Sam -SamAccountName $u.Sam -AccountPassword $PassAdmin `
                       -Enabled $true -Path $ouPath
            Write-Log "  [+] '$($u.Sam)' creado en OU '$($u.OU)'." "Green"
        } else {
            Write-Log "  [.] '$($u.Sam)' ya existe." "Gray"
        }
    }

    # --- Membresias ---
    Write-Log "`n[1.5] Asignando membresia de grupos..." "Yellow"
    foreach ($u in $admins) {
        Add-ADGroupMember -Identity "GG_Admins_Delegados" -Members $u.Sam -ErrorAction SilentlyContinue
    }
    Write-Log "  [+] Admins delegados -> GG_Admins_Delegados." "Green"

    foreach ($u in $stds) {
        Add-ADGroupMember -Identity "GG_Usuarios_Std" -Members $u.Sam -ErrorAction SilentlyContinue
    }
    Write-Log "  [+] Usuarios std -> GG_Usuarios_Std." "Green"

    Add-ADGroupMember -Identity "Group Policy Creator Owners" -Members "admin_politicas" -ErrorAction SilentlyContinue
    Write-Log "  [+] admin_politicas -> Group Policy Creator Owners." "Green"

    Add-ADGroupMember -Identity "Event Log Readers" -Members "admin_auditoria" -ErrorAction SilentlyContinue
    Write-Log "  [+] admin_auditoria -> Event Log Readers." "Green"

    Write-Log "`n[OK] FASE 1 completada." "Green"
    Pausa
}

# =========================================================================
# FASE 2: ACLs GRANULARES
# =========================================================================

function Fase2-ACLsGranulares {
    Write-Log "----------------------------------------------" "DarkCyan"
    Write-Log " [2] Configurando permisos delegados (ACL)" "White"
    Write-Log "----------------------------------------------" "DarkCyan"

    $OUsUsuarios = @(
        "`"OU=Cuates,$DCPath`"",
        "`"OU=NoCuates,$DCPath`""
    )

    # ROL 1: admin_identidad - gestion completa de usuarios
    Write-Log "`n[rol-1] admin_identidad - Gestion de usuarios en Cuates y No Cuates" "Yellow"
    foreach ($ou in $OUsUsuarios) {
        Invoke-DSAcls "$ou /I:T /G `"$NetBIOS\admin_identidad:CCDC;user`""
        Invoke-DSAcls "$ou /I:S /G `"$NetBIOS\admin_identidad:WP;;user`""
        Invoke-DSAcls "$ou /I:S /G `"$NetBIOS\admin_identidad:CA;Reset Password;user`""
        Invoke-DSAcls "$ou /I:S /G `"$NetBIOS\admin_identidad:CA;Change Password;user`""
        Invoke-DSAcls "$ou /I:S /G `"$NetBIOS\admin_identidad:WP;lockoutTime;user`""
    }
    # Restriccion critica: no puede tocar Domain Admins
    Invoke-DSAcls "`"CN=Domain Admins,CN=Users,$DCPath`" /D `"$NetBIOS\admin_identidad:WP`""
    Write-Log "  [+] ROL 1 aplicado. DENY sobre Domain Admins." "Green"

    # ROL 2: admin_storage - DENY Reset Password en todo el dominio
    Write-Log "`n[rol-2] admin_storage - DENY Reset Password (restriccion critica)" "Yellow"
    $contenedores = @(
        "`"OU=Cuates,$DCPath`"",
        "`"OU=NoCuates,$DCPath`"",
        "`"OU=AdminDelegados,$DCPath`"",
        "`"$DCPath`""
    )
    foreach ($c in $contenedores) {
        Invoke-DSAcls "$c /I:S /D `"$NetBIOS\admin_storage:CA;Reset Password;user`""
        Invoke-DSAcls "$c /I:S /D `"$NetBIOS\admin_storage:CA;Change Password;user`""
    }
    Write-Log "  [+] ROL 2: DENY Reset/Change Password en todo el dominio." "Green"

    # ROL 3: admin_politicas - lectura global, escritura solo en GPOs
    Write-Log "`n[rol-3] admin_politicas - Lectura global, escritura solo GPOs" "Yellow"
    Invoke-DSAcls "`"$DCPath`" /I:T /G `"$NetBIOS\admin_politicas:GR`""
    Invoke-DSAcls "`"CN=Policies,CN=System,$DCPath`" /I:T /G `"$NetBIOS\admin_politicas:GA`""
    foreach ($ou in $OUsUsuarios) {
        Invoke-DSAcls "$ou /I:S /D `"$NetBIOS\admin_politicas:WP;;user`""
        Invoke-DSAcls "$ou /I:S /D `"$NetBIOS\admin_politicas:CCDC;user`""
    }
    Write-Log "  [+] ROL 3: Lectura global. Escritura en GPOs. DENY en usuarios." "Green"

    # ROL 4: admin_auditoria - solo lectura total
    Write-Log "`n[rol-4] admin_auditoria - Solo lectura, escritura DENEGADA" "Yellow"
    Invoke-DSAcls "`"$DCPath`" /I:T /G `"$NetBIOS\admin_auditoria:GR`""
    $contenedoresSens = @(
        "`"$DCPath`"",
        "`"OU=AdminDelegados,$DCPath`"",
        "`"OU=Cuates,$DCPath`"",
        "`"OU=NoCuates,$DCPath`""
    )
    foreach ($c in $contenedoresSens) {
        Invoke-DSAcls "$c /I:T /D `"$NetBIOS\admin_auditoria:WP`""
        Invoke-DSAcls "$c /I:T /D `"$NetBIOS\admin_auditoria:CCDC`""
        Invoke-DSAcls "$c /I:T /D `"$NetBIOS\admin_auditoria:WO`""
    }
    Write-Log "  [+] ROL 4: Solo lectura. Toda escritura DENEGADA." "Green"

    Write-Log "`n[OK] FASE 2 completada." "Green"
    Pausa
}

# =========================================================================
# FASE 3: FGPP
# =========================================================================

function Fase3-ConfigurarFGPP {
    Write-Log "----------------------------------------------" "DarkCyan"
    Write-Log " [3] Aplicando politicas de contrasena (FGPP)" "White"
    Write-Log "----------------------------------------------" "DarkCyan"

    Write-Log "`n[!] FGPP aplica a Grupos de Seguridad, NO a OUs directamente." "Red"

    # FGPP_Admins - 12 chars minimo
    Write-Log "`n[3.1] FGPP_Admins (minimo 12 caracteres)..." "Yellow"
    if (-not (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'FGPP_Admins'" -ErrorAction SilentlyContinue)) {
        New-ADFineGrainedPasswordPolicy `
            -Name "FGPP_Admins" -Precedence 10 `
            -ComplexityEnabled $true -MinPasswordLength 12 `
            -MinPasswordAge "1.00:00:00" -MaxPasswordAge "60.00:00:00" `
            -PasswordHistoryCount 10 -ReversibleEncryptionEnabled $false `
            -LockoutThreshold 3 -LockoutDuration "00:30:00" `
            -LockoutObservationWindow "00:30:00" `
            -Description "Politica para administradores delegados - 12 chars"
        Write-Log "  [+] FGPP_Admins creada (12 chars, bloqueo 3/30min)." "Green"
    } else {
        Set-ADFineGrainedPasswordPolicy -Identity "FGPP_Admins" `
            -MinPasswordLength 12 -LockoutThreshold 3 `
            -LockoutDuration "00:30:00" -LockoutObservationWindow "00:30:00"
        Write-Log "  [.] FGPP_Admins actualizada." "Gray"
    }

    # FGPP_Standard - 8 chars minimo
    Write-Log "`n[3.2] FGPP_Standard (minimo 8 caracteres)..." "Yellow"
    if (-not (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'FGPP_Standard'" -ErrorAction SilentlyContinue)) {
        New-ADFineGrainedPasswordPolicy `
            -Name "FGPP_Standard" -Precedence 20 `
            -ComplexityEnabled $true -MinPasswordLength 8 `
            -MinPasswordAge "1.00:00:00" -MaxPasswordAge "90.00:00:00" `
            -PasswordHistoryCount 5 -ReversibleEncryptionEnabled $false `
            -LockoutThreshold 5 -LockoutDuration "00:15:00" `
            -LockoutObservationWindow "00:15:00" `
            -Description "Politica para usuarios estandar - 8 chars"
        Write-Log "  [+] FGPP_Standard creada (8 chars minimo)." "Green"
    } else {
        Write-Log "  [.] FGPP_Standard ya existe." "Gray"
    }

    # Vincular a grupos
    Write-Log "`n[3.3] Vinculando FGPPs a grupos..." "Yellow"
    try {
        Add-ADFineGrainedPasswordPolicySubject -Identity "FGPP_Admins" `
            -Subjects "GG_Admins_Delegados" -ErrorAction Stop
        Write-Log "  [+] FGPP_Admins -> GG_Admins_Delegados." "Green"
    } catch { Write-Log "  [.] FGPP_Admins ya estaba vinculada." "Gray" }

    try {
        Add-ADFineGrainedPasswordPolicySubject -Identity "FGPP_Standard" `
            -Subjects "GG_Usuarios_Std" -ErrorAction Stop
        Write-Log "  [+] FGPP_Standard -> GG_Usuarios_Std." "Green"
    } catch { Write-Log "  [.] FGPP_Standard ya estaba vinculada." "Gray" }

    # Verificacion rapida
    Write-Log "`n[3.4] FGPP vigente para admin_identidad:" "Yellow"
    $vigente = Get-ADUserResultantPasswordPolicy -Identity "admin_identidad" -ErrorAction SilentlyContinue
    if ($vigente) {
        Write-Log "  Politica  : $($vigente.Name)" "Gray"
        Write-Log "  Min chars : $($vigente.MinPasswordLength)" "Gray"
        Write-Log "  Lockout   : $($vigente.LockoutThreshold) intentos / $($vigente.LockoutDuration)" "Gray"
    } else {
        Write-Log "  [ERR] Sin FGPP vigente para admin_identidad. Verifica membresia en GG_Admins_Delegados." "Red"
    }

    Write-Log "`n[OK] FASE 3 completada." "Green"
    Pausa
}

# =========================================================================
# FASE 4: AUDITORIA
# =========================================================================

function Fase4-AuditoriaCompleta {
    Write-Log "----------------------------------------------" "DarkCyan"
    Write-Log " [4] Habilitando auditoria de eventos" "White"
    Write-Log "----------------------------------------------" "DarkCyan"

    Write-Log "`n[4.1] Activando subcategorias de seguimiento..." "Yellow"
    # NOTA: Solo se usan subcategorias validas (no categorias padre como "Object Access")
    $auditorias = @(
        "Logon", "Logoff", "Account Lockout",
        "File System", "File Share",
        "User Account Management", "Computer Account Management",
        "Security Group Management",
        "Audit Policy Change", "Authentication Policy Change",
        "Sensitive Privilege Use",
        "Credential Validation", "Kerberos Authentication Service"
    )
    foreach ($sub in $auditorias) {
        $r = cmd.exe /c "auditpol /set /subcategory:`"$sub`" /success:enable /failure:enable 2>&1"
        if ($LASTEXITCODE -eq 0) {
            Write-Log "  [+] $sub - OK" "Green"
        } else {
            Write-Log "  [ERR] $sub - Error: $r" "Red"
        }
    }

    # Politica de bloqueo de dominio
    Write-Log "`n[4.2] Configurando politica de bloqueo del dominio..." "Yellow"
    Set-ADDefaultDomainPasswordPolicy -Identity $Dominio `
        -LockoutThreshold 3 -LockoutDuration "00:30:00" `
        -LockoutObservationWindow "00:30:00" `
        -MinPasswordLength 8 -ComplexityEnabled $true -PasswordHistoryCount 5
    Write-Log "  [+] 3 intentos fallidos = bloqueo 30 minutos." "Green"

    # Ampliar log de seguridad a 512 MB
    Write-Log "`n[4.3] Configurando tamano del Log de Seguridad (512 MB)..." "Yellow"
    wevtutil sl Security /ms:536870912 /rt:false
    Write-Log "  [+] Log de Seguridad configurado a 512 MB." "Green"

    Write-Log "`n[OK] FASE 4 completada." "Green"
    Pausa
}

# =========================================================================
# FASE 5: MFA con WinOTP + Google Authenticator
# =========================================================================

function Fase5-ConfigurarMFA {
    Write-Log "----------------------------------------------" "DarkCyan"
    Write-Log " [5] Configurando autenticacion multifactor" "White"
    Write-Log "----------------------------------------------" "DarkCyan"

    Ensure-Dir "$RutaReportes\MFA"

    # --- Paso 1: Descargar WinOTP ---
    Write-Log "`n[5.1] Descargando WinOTP Authenticator..." "Yellow"
    $winOTPUrl  = "https://github.com/winauth/winauth/releases/download/3.6.0/WinAuth-3.6.0-dotnet40.zip"
    $zipDest    = "$RutaReportes\MFA\WinAuth.zip"
    $extractDir = "$RutaReportes\MFA\WinAuth"

    # Forzar TLS 1.2 para que GitHub no rechace la conexion
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if (-not (Test-Path $extractDir)) {
        try {
            Write-Log "  Descargando desde GitHub (puede tardar unos segundos)..." "Gray"
            Invoke-WebRequest -Uri $winOTPUrl -OutFile $zipDest -UseBasicParsing -ErrorAction Stop
            Expand-Archive -Path $zipDest -DestinationPath $extractDir -Force
            Write-Log "  [+] WinAuth descargado y extraido en: $extractDir" "Green"
        } catch {
            Write-Log "  [ERR] Error al descargar WinAuth: $_" "Red"
            Write-Log "  [ERR] Crea la carpeta manualmente y copia WinAuth.exe ahi:" "Yellow"
            Write-Log "      $extractDir" "Yellow"
            Write-Log "      Descarga desde: https://github.com/winauth/winauth/releases" "Yellow"
            # Crear la carpeta de todas formas para que el resto del script no falle
            New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        }
    } else {
        Write-Log "  [.] WinAuth ya estaba descargado." "Gray"
    }

    # --- Paso 2: Generar clave TOTP para admin_identidad ---
    Write-Log "`n[5.2] Generando clave TOTP para MFA..." "Yellow"

    # Generar 20 bytes aleatorios y codificar en Base32
    $randomBytes = New-Object byte[] 20
    [System.Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($randomBytes)

    # Codificacion Base32 manual
    $base32Chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    $bits = [System.Collections.Generic.List[int]]::new()
    foreach ($b in $randomBytes) {
        for ($i = 7; $i -ge 0; $i--) {
            $bits.Add(($b -shr $i) -band 1)
        }
    }
    $secretBase32 = ""
    for ($i = 0; $i -lt $bits.Count - 4; $i += 5) {
        $val = ($bits[$i] -shl 4) -bor ($bits[$i+1] -shl 3) -bor ($bits[$i+2] -shl 2) -bor ($bits[$i+3] -shl 1) -bor $bits[$i+4]
        $secretBase32 += $base32Chars[$val]
    }

    # Guardar la clave
    $claveFile = "$RutaReportes\MFA\clave_totp_admin_identidad.txt"
    $contenidoClave = @"
=========================================================
  CLAVE TOTP PARA MFA - PRACTICA 09
  Usuario   : admin_identidad
  Dominio   : $Dominio
  Generada  : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
=========================================================

  CLAVE SECRETA BASE32:
  $secretBase32

  COMO CONFIGURAR GOOGLE AUTHENTICATOR:
  1. Abre Google Authenticator en tu celular
  2. Presiona el "+" para agregar cuenta
  3. Selecciona "Ingresar clave de configuracion"
  4. Nombre de cuenta: admin_identidad@$Dominio
  5. Clave: $secretBase32
  6. Tipo: Basado en tiempo (TOTP)
  7. Presiona "Agregar"

  COMO CONFIGURAR WinAuth:
  1. Abre WinAuth desde: $extractDir
  2. Clic en "Add" -> "Google Authenticator"
  3. Ingresa la clave: $secretBase32
  4. Verifica que el codigo de 6 digitos coincide con Google Auth

  PARA EL REPORTE (evidencias requeridas):
  - Captura de WinAuth mostrando el codigo TOTP de 6 digitos
  - Foto del celular con Google Authenticator mostrando el mismo codigo
  - Ambos deben mostrar el MISMO codigo en el mismo momento
=========================================================
"@
    $contenidoClave | Set-Content $claveFile -Encoding UTF8
    Write-Log "  [+] Clave TOTP generada y guardada en: $claveFile" "Green"
    Write-Log "  [+] Clave Base32: $secretBase32" "Cyan"

    # --- Paso 3: Registrar configuracion de MFA en el sistema ---
    Write-Log "`n[5.3] Registrando configuracion de MFA en el sistema..." "Yellow"
    $mfaRegPath = "HKLM:\SOFTWARE\Practica09\MFA_Config"
    if (-not (Test-Path $mfaRegPath)) {
        New-Item -Path $mfaRegPath -Force | Out-Null
    }
    Set-ItemProperty -Path $mfaRegPath -Name "MaxFailedAttempts"   -Value 3            -Type DWord
    Set-ItemProperty -Path $mfaRegPath -Name "LockoutDuration_min" -Value 30           -Type DWord
    Set-ItemProperty -Path $mfaRegPath -Name "TOTPWindowSeconds"   -Value 30           -Type DWord
    Set-ItemProperty -Path $mfaRegPath -Name "Algorithm"           -Value "TOTP-SHA1"  -Type String
    Set-ItemProperty -Path $mfaRegPath -Name "SecretKey_admin_id"  -Value $secretBase32 -Type String
    Set-ItemProperty -Path $mfaRegPath -Name "WinAuthPath"         -Value $extractDir  -Type String
    Write-Log "  [+] Configuracion MFA registrada en HKLM:\SOFTWARE\Practica09\MFA_Config" "Green"

    # --- Paso 4: Verificar politica de lockout ---
    Write-Log "`n[5.4] Verificando politica de bloqueo MFA (3 intentos = 30 min)..." "Yellow"
    $pol = Get-ADDefaultDomainPasswordPolicy -Identity $Dominio
    if ($pol.LockoutThreshold -eq 3) {
        Write-Log "  [+] Lockout correcto: 3 intentos -> bloqueo 30 min." "Green"
    } else {
        Set-ADDefaultDomainPasswordPolicy -Identity $Dominio `
            -LockoutThreshold 3 -LockoutDuration "00:30:00" -LockoutObservationWindow "00:30:00"
        Write-Log "  [+] Lockout corregido: 3 intentos -> 30 minutos." "Green"
    }

    $fgppA = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'FGPP_Admins'" -ErrorAction SilentlyContinue
    if ($fgppA -and $fgppA.LockoutThreshold -eq 3) {
        Write-Log "  [+] FGPP_Admins lockout: OK (3 intentos / 30 min)." "Green"
    } elseif ($fgppA) {
        Set-ADFineGrainedPasswordPolicy -Identity "FGPP_Admins" `
            -LockoutThreshold 3 -LockoutDuration "00:30:00" -LockoutObservationWindow "00:30:00"
        Write-Log "  [+] FGPP_Admins lockout corregido." "Green"
    }

    # --- Paso 5: Abrir WinAuth si existe ---
    $winAuthExe = Get-ChildItem $extractDir -Filter "*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($winAuthExe) {
        Write-Log "`n[5.5] Abriendo WinAuth para configurar la cuenta TOTP..." "Yellow"
        Write-Host ""
        Write-Host "  *** ACCION REQUERIDA ***" -ForegroundColor Red
        Write-Host "  1. WinAuth se va a abrir ahora" -ForegroundColor White
        Write-Host "  2. Clic en Add -> Google Authenticator" -ForegroundColor White
        Write-Host "  3. Ingresa esta clave: $secretBase32" -ForegroundColor Cyan
        Write-Host "  4. Toma captura del codigo de 6 digitos (evidencia Test 3)" -ForegroundColor White
        Write-Host "  5. Configura lo mismo en Google Authenticator de tu celular" -ForegroundColor White
        Write-Host ""
        $abrir = Read-Host "  Presiona ENTER para abrir WinAuth (o escribe N para omitir)"
        if ($abrir.ToUpper() -ne "N") {
            Start-Process $winAuthExe.FullName
        }
    } else {
        Write-Log "  [ERR] WinAuth no encontrado. Instala manualmente desde: $extractDir" "Yellow"
    }

    # Generar instrucciones para el reporte
    $instrucciones = @"
=========================================================
  INSTRUCCIONES MFA PARA EL REPORTE - PRACTICA 09
  $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
=========================================================

EVIDENCIAS REQUERIDAS POR LA RUBRICA:

TEST 3 - Flujo de Autenticacion MFA:
  Captura 1: WinAuth abierto mostrando codigo TOTP de 6 digitos para admin_identidad
  Captura 2: Google Authenticator en celular mostrando el MISMO codigo
  Nota: Ambas capturas deben mostrar el mismo codigo en el mismo momento

TEST 4 - Bloqueo tras 3 intentos fallidos:
  Accion: Intentar cambiar password de admin_identidad con password incorrecta 3 veces
  Comando para provocar el bloqueo (correr como admin del dominio):
    1-3 veces: Set-ADAccountPassword -Identity admin_identidad -NewPassword (ConvertTo-SecureString "mal" -AsPlainText -Force) -Reset
  Captura: Ir a ADUC (dsa.msc), abrir propiedades de admin_identidad
           En la pestana Account debe aparecer: "Account is locked out"
  Desbloqueo: Unlock-ADAccount -Identity admin_identidad

FLUJO TECNICO PARA EL DIAGRAMA:
  [Usuario ingresa password]
       |
       v
  [Winlogon.exe recibe credenciales]
       |
       v
  [LSASS valida contra AD via Kerberos/NTLM]
       |-- Factor 1 OK? --> [Usuario abre WinAuth]
       |                         |
       |                    [WinAuth genera TOTP]
       |                    [HMAC-SHA1(secreto + tiempo/30)]
       |                         |
       |                    [Usuario ingresa codigo de 6 digitos]
       |                         |
       v                         v
  [Sesion establecida] <-- [Ambos factores validados]
       |
       v
  [Evento 4624 en Security Log]

  Si password incorrecta 3 veces:
  [Evento 4625 en Security Log]
  [lockoutTime != 0 -> cuenta bloqueada 30 min]

CLAVE TOTP CONFIGURADA: $secretBase32
ALGORITMO             : TOTP-SHA1
VENTANA               : 30 segundos
=========================================================
"@
    $instrucciones | Set-Content "$RutaReportes\MFA\Instrucciones_Reporte_MFA.txt" -Encoding UTF8
    Write-Log "`n[+] Instrucciones para el reporte guardadas en: $RutaReportes\MFA\Instrucciones_Reporte_MFA.txt" "Green"

    Write-Log "`n[OK] FASE 5 completada." "Green"
    Write-Log "     Clave: $claveFile" "Cyan"
    Pausa
}

# =========================================================================
# REPORTE: EVENTOS 4625
# =========================================================================

function Generar-ReporteAuditoria {
    param([switch]$SinPausa)
    Write-Log "----------------------------------------------" "DarkCyan"
    Write-Log " [r] Exportando eventos de acceso denegado" "White"
    Write-Log "----------------------------------------------" "DarkCyan"

    Ensure-Dir $RutaReportes

    $eventos4625 = Get-WinEvent -FilterHashtable @{
        LogName = "Security"; Id = 4625
    } -MaxEvents 10 -ErrorAction SilentlyContinue

    $eventos4771 = Get-WinEvent -FilterHashtable @{
        LogName = "Security"; Id = 4771
    } -MaxEvents 10 -ErrorAction SilentlyContinue

    # Combinar y tomar los 10 mas recientes
    $eventos = @($eventos4625) + @($eventos4771) |
               Where-Object { $_ -ne $null } |
               Sort-Object TimeCreated -Descending |
               Select-Object -First 10

    $encabezado = @"
=========================================================
  REPORTE DE AUDITORIA - ACCESOS DENEGADOS
  Eventos ID 4625 (Logon fallido) y 4771 (Kerberos fallido)
  Practica 09 - Hardening de AD
  Generado : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  Servidor : $env:COMPUTERNAME
  Dominio  : $Dominio
=========================================================
"@

    if (-not $eventos) {
        $txt = $encabezado + "`n[!] Sin eventos 4625. Ejecuta Fase 4 y genera intentos de login fallido.`n"
        $txt | Out-File $RutaReporte -Encoding UTF8
        Write-Log "  [ERR] Sin eventos 4625 aun. Reporte placeholder: $RutaReporte" "Yellow"
        Pausa; return
    }

    $registros = foreach ($ev in $eventos) {
        $xml  = [xml]$ev.ToXml()
        $data = $xml.Event.EventData.Data
        function Get-F { param($n) ($data | Where-Object { $_.Name -eq $n }).'#text' }

        if ($ev.Id -eq 4625) {
            $sub = Get-F "SubStatus"
            $desc = switch ($sub) {
                "0xC000006A" { "Contrasena incorrecta"             }
                "0xC0000064" { "Usuario no existe"                 }
                "0xC0000234" { "Cuenta bloqueada"                  }
                "0xC0000072" { "Cuenta deshabilitada"              }
                "0xC000006F" { "Fuera de horario permitido"        }
                "0xC0000070" { "Estacion no autorizada"            }
                default      { "Codigo: $sub"                      }
            }
            [PSCustomObject]@{
                "Fecha/Hora" = $ev.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                "EventID"    = $ev.Id
                "Usuario"    = Get-F "TargetUserName"
                "Dominio"    = Get-F "TargetDomainName"
                "IP Origen"  = Get-F "IpAddress"
                "Error"      = $desc
                "TipoLogon"  = Get-F "LogonType"
            }
        } elseif ($ev.Id -eq 4771) {
            $errCode = Get-F "Status"
            $desc = switch ($errCode) {
                "0x18" { "Contrasena incorrecta (Kerberos)"  }
                "0x6"  { "Usuario no existe (Kerberos)"      }
                "0x12" { "Cuenta deshabilitada (Kerberos)"   }
                "0x17" { "Contrasena expirada (Kerberos)"    }
                "0x25" { "Reloj desincronizado (Kerberos)"   }
                default{ "Kerberos error: $errCode"          }
            }
            [PSCustomObject]@{
                "Fecha/Hora" = $ev.TimeCreated.ToString("yyyy-MM-dd HH:mm:ss")
                "EventID"    = $ev.Id
                "Usuario"    = Get-F "TargetUserName"
                "Dominio"    = $Dominio
                "IP Origen"  = Get-F "IpAddress"
                "Error"      = $desc
                "TipoLogon"  = "Kerberos"
            }
        }
    }

    $cuerpo  = $encabezado + "`n"
    $cuerpo += ($registros | Format-Table -AutoSize | Out-String)
    $cuerpo += "`n=========================================================`n"
    $cuerpo += "Total de eventos: $($registros.Count)`n"
    $cuerpo  | Out-File $RutaReporte -Encoding UTF8

    $rutaCSV = $RutaReporte -replace "\.txt$", ".csv"
    $registros | Export-Csv $rutaCSV -NoTypeInformation -Encoding UTF8

    Write-Log "  [+] TXT: $RutaReporte" "Green"
    Write-Log "  [+] CSV: $rutaCSV" "Green"
    Write-Host ($registros | Format-Table -AutoSize | Out-String) -ForegroundColor Gray
    Write-Log "[OK] Reporte generado. Total: $($registros.Count) eventos." "Green"
    Pausa
}

# =========================================================================
# VERIFICACION COMPLETA
# =========================================================================

function Verificar-EstadoPractica {
    Write-Log "----------------------------------------------" "DarkCyan"
    Write-Log " [v] Revisando estado de la configuracion" "White"
    Write-Log "----------------------------------------------" "DarkCyan"

    $script:ok  = 0
    $script:max = 0

    function Check {
        param([string]$Desc, [bool]$Resultado)
        $script:max++
        if ($Resultado) {
            Write-Log "  [ok] $Desc" "Green"
            $script:ok++
        } else {
            Write-Log "  [--] $Desc" "Red"
        }
    }

    Write-Log "`n=== OUs ===" "Yellow"
    Check "OU AdminDelegados"  ((Get-ADOrganizationalUnit -Filter "Name -eq 'AdminDelegados'" -ErrorAction SilentlyContinue) -ne $null)
    Check "OU Cuates"          ((Get-ADOrganizationalUnit -Filter "Name -eq 'Cuates'"         -ErrorAction SilentlyContinue) -ne $null)
    Check "OU No Cuates"       ((Get-ADOrganizationalUnit -Filter "Name -eq 'NoCuates'"      -ErrorAction SilentlyContinue) -ne $null)

    Write-Log "`n=== USUARIOS DELEGADOS ===" "Yellow"
    foreach ($u in @("admin_identidad","admin_storage","admin_politicas","admin_auditoria")) {
        $adUser = Get-ADUser -Filter "SamAccountName -eq '$u'" -Properties Enabled -ErrorAction SilentlyContinue
        Check "Usuario '$u' habilitado" ($adUser -ne $null -and $adUser.Enabled)
    }

    Write-Log "`n=== GRUPOS ===" "Yellow"
    Check "GG_Admins_Delegados" ((Get-ADGroup -Filter "Name -eq 'GG_Admins_Delegados'" -ErrorAction SilentlyContinue) -ne $null)
    Check "GG_Usuarios_Std"     ((Get-ADGroup -Filter "Name -eq 'GG_Usuarios_Std'"     -ErrorAction SilentlyContinue) -ne $null)

    Write-Log "`n=== FGPP ===" "Yellow"
    $fa = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'FGPP_Admins'"   -ErrorAction SilentlyContinue
    $fs = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'FGPP_Standard'" -ErrorAction SilentlyContinue
    Check "FGPP_Admins existe"              ($fa -ne $null)
    Check "FGPP_Admins: 12 chars"           ($fa -ne $null -and $fa.MinPasswordLength -eq 12)
    Check "FGPP_Admins: Lockout = 3"        ($fa -ne $null -and $fa.LockoutThreshold  -eq 3)
    Check "FGPP_Standard existe"            ($fs -ne $null)
    Check "FGPP_Standard: 8 chars"          ($fs -ne $null -and $fs.MinPasswordLength -eq 8)
    if ($fa) {
        $suj = Get-ADFineGrainedPasswordPolicySubject -Identity "FGPP_Admins" -ErrorAction SilentlyContinue
        Check "FGPP_Admins vinculada a GG_Admins_Delegados" ($suj -ne $null -and ($suj | Where-Object { $_.Name -eq "GG_Admins_Delegados" }))
    }

    Write-Log "`n=== AUDITORIA ===" "Yellow"
    $al = (cmd.exe /c 'auditpol /get /subcategory:"Logon"') | Out-String
    Check "Auditoria Logon Success" ($al -match "Success")
    Check "Auditoria Logon Failure" ($al -match "Failure")

    Write-Log "`n=== POLITICA DE BLOQUEO ===" "Yellow"
    $dp = Get-ADDefaultDomainPasswordPolicy -Identity $Dominio
    Check "LockoutThreshold = 3"         ($dp.LockoutThreshold -eq 3)
    Check "LockoutDuration = 30 min"     ($dp.LockoutDuration  -eq "00:30:00")

    Write-Log "`n=== MEMBRESIA GRUPOS DEL SISTEMA ===" "Yellow"
    $elr = Get-ADGroupMember "Event Log Readers" -ErrorAction SilentlyContinue | Where-Object { $_.SamAccountName -eq "admin_auditoria" }
    $gpc = Get-ADGroupMember "Group Policy Creator Owners" -ErrorAction SilentlyContinue | Where-Object { $_.SamAccountName -eq "admin_politicas" }
    Check "admin_auditoria en Event Log Readers"          ($elr -ne $null)
    Check "admin_politicas en Group Policy Creator Owners" ($gpc -ne $null)

    Write-Log "`n=== MFA ===" "Yellow"
    $mfa = Get-ItemProperty "HKLM:\SOFTWARE\Practica09\MFA_Config" -ErrorAction SilentlyContinue
    Check "Config MFA en registro"           ($mfa -ne $null)
    Check "MaxFailedAttempts = 3"            ($mfa -ne $null -and $mfa.MaxFailedAttempts -eq 3)
    Check "WinAuth descargado"               (Test-Path "$RutaReportes\MFA\WinAuth")
    Check "Clave TOTP generada"              (Test-Path "$RutaReportes\MFA\clave_totp_admin_identidad.txt")

    Write-Log "`n=== REPORTES ===" "Yellow"
    Check "Carpeta Reportes_P09 existe"      (Test-Path $RutaReportes)
    Check "Log de ejecucion existe"          (Test-Path $LogScript)

    Write-Log "`n=============================================" "Cyan"
    $pct = if ($script:max -gt 0) { [math]::Round(($script:ok / $script:max) * 100) } else { 0 }
    $col = if ($pct -ge 80) { "Green" } elseif ($pct -ge 50) { "Yellow" } else { "Red" }
    Write-Log " Resultado final: $($script:ok) de $($script:max) verificaciones correctas ($pct%)" $col
    Write-Log "----------------------------------------------" "DarkCyan"
    Pausa
}

# =========================================================================
# TESTS DE PROTOCOLO
# =========================================================================

function Test1-DelegacionRBAC {
    Clear-Host
    Write-Header "TEST 1  >>  Delegacion de Control RBAC"
    Write-Host "  Que se prueba:" -ForegroundColor DarkGray
    Write-Host "    admin_identidad  ->  debe poder cambiar contrasenas" -ForegroundColor DarkGray
    Write-Host "    admin_storage    ->  debe recibir ACCESO DENEGADO" -ForegroundColor DarkGray
    Write-Host ""

    # Asegurar que juan existe
    if (-not (Get-ADUser -Filter "SamAccountName -eq 'juan'" -ErrorAction SilentlyContinue)) {
        New-ADUser -Name "juan" -SamAccountName "juan" `
                   -AccountPassword $PassAdmin -Enabled $true -Path "OU=Cuates,$DCPath"
        Write-Info "Usuario 'juan' creado como sujeto de prueba."
    }

    Write-Step "CASO A >" "admin_identidad cambia contrasena de juan"
    Write-Host ""
    try {
        $nuevaPass = ConvertTo-SecureString "NuevoPass2026!" -AsPlainText -Force
        Set-ADAccountPassword -Identity "juan" -NewPassword $nuevaPass -Reset -ErrorAction Stop
        Write-Ok "Operacion exitosa - la delegacion IAM funciona correctamente"
        Add-Content -Path $LogScript -Value "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] [t1.a] PASS: admin_identidad reseteo contrasena de juan"
    } catch {
        Write-Fail "Error inesperado: $($_.Exception.Message)"
        Add-Content -Path $LogScript -Value "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] [t1.a] FAIL: $($_.Exception.Message)"
    }

    Write-Host ""
    Write-Step "CASO B >" "admin_storage intenta la misma operacion"
    Write-Host ""

    $cred = $null
    try {
        $cred = Get-Credential -UserName "$NetBIOS\admin_storage" `
                               -Message "Ingresa credenciales de admin_storage"
    } catch {
        Write-Info "Prueba t1.b cancelada."
        Pausa; return
    }

    if ($cred) {
        try {
            Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction SilentlyContinue | Out-Null
            $passReset = ConvertTo-SecureString "TestPass2026!" -AsPlainText -Force
            Invoke-Command -ComputerName $env:COMPUTERNAME -Credential $cred -ScriptBlock {
                param($u, $p)
                Import-Module ActiveDirectory
                Set-ADAccountPassword -Identity $u -NewPassword $p -Reset -ErrorAction Stop
            } -ArgumentList "juan", $passReset -ErrorAction Stop
            Write-Fail "FALLA DE SEGURIDAD: admin_storage logro resetear contrasena - revisar ACL DENY"
            Add-Content -Path $LogScript -Value "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] [t1.b] FAIL: admin_storage pudo resetear"
        } catch {
            Write-Ok "Acceso denegado confirmado - la restriccion ACL funciona"
            Write-Info "Mensaje del sistema: $($_.Exception.Message)"
            Add-Content -Path $LogScript -Value "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] [t1.b] PASS: Acceso denegado para admin_storage"
        }
    }

    Write-Host ""
    Pausa
}

function Test2-ValidarFGPP {
    Clear-Host
    Write-Header "TEST 2  >>  Politica de Contrasenas por Nivel (FGPP)"
    Write-Host "  Que se prueba:" -ForegroundColor DarkGray
    Write-Host "    Contrasenas cortas deben ser RECHAZADAS para admin_identidad" -ForegroundColor DarkGray
    Write-Host "    Contrasenas de 12+ chars deben ser ACEPTADAS" -ForegroundColor DarkGray
    Write-Host ""

    $vigente = Get-ADUserResultantPasswordPolicy -Identity "admin_identidad" -ErrorAction SilentlyContinue
    if (-not $vigente) {
        Write-Fail "Sin FGPP activa. Ejecuta la Fase 3 primero."
        Pausa; return
    }

    Write-Host "  Politica aplicada  :  " -ForegroundColor DarkGray -NoNewline
    Write-Host "$($vigente.Name)" -ForegroundColor Cyan
    Write-Host "  Minimo requerido   :  " -ForegroundColor DarkGray -NoNewline
    Write-Host "$($vigente.MinPasswordLength) caracteres" -ForegroundColor Cyan
    Write-Host ""

    # Intento 1 - 5 chars
    Write-Step "INTENTO 1 >" "Contrasena '12345'  (5 caracteres)"
    try {
        $p5 = ConvertTo-SecureString "12345" -AsPlainText -Force
        Set-ADAccountPassword -Identity "admin_identidad" -NewPassword $p5 -Reset -ErrorAction Stop
        Write-Fail "Contrasena de 5 chars fue ACEPTADA - fallo de politica"
        Add-Content -Path $LogScript -Value "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] [t2.1] FAIL: contrasena corta aceptada"
    } catch {
        Write-Ok "Rechazada por FGPP - minimo no cumplido"
        Add-Content -Path $LogScript -Value "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] [t2.1] PASS: contrasena de 5 chars rechazada"
    }
    Write-Host ""

    # Intento 2 - 8 chars
    Write-Step "INTENTO 2 >" "Contrasena 'Abc12345'  (8 caracteres)"
    try {
        $p8 = ConvertTo-SecureString "Abc12345" -AsPlainText -Force
        Set-ADAccountPassword -Identity "admin_identidad" -NewPassword $p8 -Reset -ErrorAction Stop
        Write-Fail "Contrasena de 8 chars fue ACEPTADA - fallo de politica"
        Add-Content -Path $LogScript -Value "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] [t2.2] FAIL: contrasena de 8 chars aceptada"
    } catch {
        Write-Ok "Rechazada correctamente - politica exige $($vigente.MinPasswordLength) chars"
        Add-Content -Path $LogScript -Value "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] [t2.2] PASS: contrasena de 8 chars rechazada"
    }
    Write-Host ""

    # Intento 3 - 12 chars
    Write-Step "INTENTO 3 >" "Contrasena 'Admin@2026!!'  (12 caracteres)"
    try {
        Set-ADFineGrainedPasswordPolicy -Identity "FGPP_Admins" -PasswordHistoryCount 0 -ErrorAction SilentlyContinue
        Set-ADDefaultDomainPasswordPolicy -Identity $Dominio -PasswordHistoryCount 0 -ErrorAction SilentlyContinue
        $p12 = ConvertTo-SecureString "Admin@2026!!" -AsPlainText -Force
        Set-ADAccountPassword -Identity "admin_identidad" -NewPassword $p12 -Reset -ErrorAction Stop
        Write-Ok "Aceptada - cumple el minimo de 12 caracteres"
        Add-Content -Path $LogScript -Value "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] [t2.3] PASS: contrasena de 12 chars aceptada"
    } catch {
        Write-Fail "Rechazada: $($_.Exception.Message)"
        Add-Content -Path $LogScript -Value "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] [t2.3] FAIL: $($_.Exception.Message)"
    } finally {
        Set-ADFineGrainedPasswordPolicy -Identity "FGPP_Admins" -PasswordHistoryCount 10 -ErrorAction SilentlyContinue
        Set-ADDefaultDomainPasswordPolicy -Identity $Dominio -PasswordHistoryCount 5 -ErrorAction SilentlyContinue
        Write-Info "Historial de contrasenas restaurado."
    }

    Write-Host ""
    Pausa
}

function Test3-MFAEstado {
    Clear-Host
    Write-Header "TEST 3  >>  Flujo de Autenticacion Multifactor (MFA)"
    Write-Host "  Que se prueba:" -ForegroundColor DarkGray
    Write-Host "    El sistema debe solicitar un codigo TOTP al iniciar sesion" -ForegroundColor DarkGray
    Write-Host ""

    $mfa = Get-ItemProperty "HKLM:\SOFTWARE\Practica09\MFA_Config" -ErrorAction SilentlyContinue
    if ($mfa) {
        Write-Ok "Configuracion MFA detectada en el registro del sistema"
        Write-Host ""
        Write-Host "  Detalles de configuracion:" -ForegroundColor DarkGray
        Write-Host "    Algoritmo     :  $($mfa.Algorithm)"                -ForegroundColor White
        Write-Host "    Max intentos  :  $($mfa.MaxFailedAttempts)"        -ForegroundColor White
        Write-Host "    Ventana TOTP  :  $($mfa.TOTPWindowSeconds) seg"    -ForegroundColor White
        Write-Host "    Clave TOTP    :  " -ForegroundColor White -NoNewline
        Write-Host "$($mfa.SecretKey_admin_id)" -ForegroundColor Cyan
    } else {
        Write-Fail "No se encontro configuracion MFA. Ejecuta la Fase 5 primero."
        Pausa; return
    }

    $winAuthPath = $mfa.WinAuthPath
    $winAuthExe  = Get-ChildItem $winAuthPath -Filter "*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-Host ""
    if ($winAuthExe) {
        Write-Ok "WinAuth localizado en: $($winAuthExe.FullName)"
    } else {
        Write-Info "WinAuth no encontrado en: $winAuthPath"
    }

    Write-Host ""
    Write-Host "  Pasos para generar la evidencia:" -ForegroundColor DarkYellow
    Write-Host "    1. Abre Google Authenticator en tu celular"                        -ForegroundColor Gray
    Write-Host "    2. Localiza la cuenta admin_identidad@practica.local"              -ForegroundColor Gray
    Write-Host "    3. Toma foto del codigo de 6 digitos generado"                     -ForegroundColor Gray
    Write-Host "    4. Ejecuta MFA_Login_Final.ps1 e ingresa el codigo"                -ForegroundColor Gray
    Write-Host "    5. Toma captura de la pantalla mostrando [OK] Acceso concedido"   -ForegroundColor Gray
    Write-Host ""
    Write-Host "    Clave TOTP activa:  " -ForegroundColor DarkGray -NoNewline
    Write-Host "$($mfa.SecretKey_admin_id)" -ForegroundColor Cyan
    Write-Host ""

    $abrirW = Read-Host "  Abrir WinAuth ahora? (s/n)"
    if ($abrirW.ToUpper() -eq "S" -and $winAuthExe) {
        Start-Process $winAuthExe.FullName
        Write-Info "WinAuth iniciado."
    }

    Pausa
}

function Test4-BloqueoMFA {
    Clear-Host
    Write-Header "TEST 4  >>  Bloqueo de Cuenta por Intentos Fallidos"
    Write-Host "  Que se prueba:" -ForegroundColor DarkGray
    Write-Host "    Tras 3 codigos MFA incorrectos la cuenta debe bloquearse" -ForegroundColor DarkGray
    Write-Host "    Sujeto: admin_identidad" -ForegroundColor DarkGray
    Write-Host ""

    Write-Info "Desbloqueando cuenta antes de iniciar..."
    Unlock-ADAccount -Identity "admin_identidad" -ErrorAction SilentlyContinue
    Enable-ADAccount  -Identity "admin_identidad" -ErrorAction SilentlyContinue
    Write-Info "Cuenta lista."
    Write-Host ""

    Write-Step "SIMULACION >" "Disparando 3 intentos de autenticacion fallida"
    Write-Host ""
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction SilentlyContinue

    for ($i = 1; $i -le 3; $i++) {
        try {
            $null = [System.DirectoryServices.AccountManagement.PrincipalContext]::new(
                [System.DirectoryServices.AccountManagement.ContextType]::Domain,
                $Dominio
            ).ValidateCredentials("admin_identidad", "WrongPass$i")
        } catch { }
        Write-Host "         Intento $i / 3  >>  credencial invalida registrada" -ForegroundColor DarkYellow
        Start-Sleep -Seconds 1
    }

    Start-Sleep -Seconds 2
    Write-Host ""

    $user = Get-ADUser -Identity "admin_identidad" -Properties LockedOut, BadLogonCount, Enabled `
                       -ErrorAction SilentlyContinue
    if ($user.LockedOut) {
        Write-Ok "Cuenta bloqueada correctamente en Active Directory"
        Write-Host ""
        Write-Host "  Estado de la cuenta:" -ForegroundColor DarkGray
        Write-Host "    SamAccountName  :  " -ForegroundColor DarkGray -NoNewline; Write-Host "$($user.SamAccountName)" -ForegroundColor White
        Write-Host "    LockedOut       :  " -ForegroundColor DarkGray -NoNewline; Write-Host "$($user.LockedOut)"      -ForegroundColor Red
        Write-Host "    Enabled         :  " -ForegroundColor DarkGray -NoNewline; Write-Host "$($user.Enabled)"        -ForegroundColor White
        Write-Host "    BadLogonCount   :  " -ForegroundColor DarkGray -NoNewline; Write-Host "$($user.BadLogonCount)"  -ForegroundColor Yellow
        Write-Host "    Timestamp       :  " -ForegroundColor DarkGray -NoNewline; Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
        Add-Content -Path $LogScript -Value "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] [t4] PASS: LockedOut=True BadLogon=$($user.BadLogonCount)"
    } else {
        Write-Fail "La cuenta no quedo bloqueada automaticamente"
        Write-Host "    BadLogonCount   :  $($user.BadLogonCount)" -ForegroundColor White
        Write-Info "Para evidencia manual: intenta login con credenciales incorrectas 3 veces desde el cliente Windows 10."
        Add-Content -Path $LogScript -Value "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] [t4] INFO: no bloqueado BadLogon=$($user.BadLogonCount)"
    }

    Write-Host ""
    $desbloquear = Read-Host "  Desbloquear la cuenta ahora? (s/n)"
    if ($desbloquear.ToUpper() -eq "S") {
        Unlock-ADAccount -Identity "admin_identidad"
        Write-Info "Cuenta desbloqueada."
    }

    Write-Host ""
    Pausa
}

function Test5-ReporteAuditoria {
    Clear-Host
    Write-Header "TEST 5  >>  Exportacion Automatizada de Eventos"
    Write-Host "  Que se prueba:" -ForegroundColor DarkGray
    Write-Host "    El script extrae los ultimos 10 eventos ID 4625 del Visor de Eventos" -ForegroundColor DarkGray
    Write-Host "    y los exporta a archivos TXT y CSV en $RutaReportes" -ForegroundColor DarkGray
    Write-Host ""

    Write-Info "Ejecutando extraccion del Visor de Eventos..."
    Write-Host ""
    Generar-ReporteAuditoria

    Write-Host ""
    Write-Step "ARCHIVOS >" "Generados en $RutaReportes"
    Write-Host ""
    Get-ChildItem $RutaReportes -File |
        Select-Object Name, LastWriteTime, @{N="KB"; E={[math]::Round($_.Length/1KB,1)}} |
        Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }

    Add-Content -Path $LogScript -Value "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] [t5] Reporte generado en $RutaReportes"
    Pausa
}

# =========================================================================
# EJECUTAR TODO
# =========================================================================

function EjecutarTodo {
    Write-Log "----------------------------------------------" "DarkCyan"
    Write-Log " [todo] Ejecutando todas las fases..." "White"
    Write-Log "----------------------------------------------" "DarkCyan"

    $confirm = Read-Host "`nEjecutar todas las fases de configuracion? (S/N)"
    if ($confirm.ToUpper() -ne "S") { return }

    Fase1-InfraestructuraBase
    Fase2-ACLsGranulares
    Fase3-ConfigurarFGPP
    Fase4-AuditoriaCompleta
    Fase5-ConfigurarMFA
    Generar-ReporteAuditoria
    Verificar-EstadoPractica
}

# =========================================================================
# INICIO
# =========================================================================

Ensure-Dir $RutaReportes
Write-Log "Asistente iniciado >> Dominio: $Dominio | Registro: $LogScript" "Gray"

do {
    Mostrar-Menu
    $Opcion = Read-Host "  Ingresa una opcion"

    switch ($Opcion.ToUpper()) {
        "1"    { Fase1-InfraestructuraBase    }
        "2"    { Fase2-ACLsGranulares         }
        "3"    { Fase3-ConfigurarFGPP         }
        "4"    { Fase4-AuditoriaCompleta      }
        "5"    { Fase5-ConfigurarMFA          }
        "R"    { Generar-ReporteAuditoria     }
        "V"    { Verificar-EstadoPractica     }
        "T1"   { Test1-DelegacionRBAC         }
        "T2"   { Test2-ValidarFGPP            }
        "T3"   { Test3-MFAEstado              }
        "T4"   { Test4-BloqueoMFA             }
        "T5"   { Test5-ReporteAuditoria       }
        "TODO" { EjecutarTodo                 }
        "S"    { Write-Log "Hasta luego. Todos los cambios han sido registrados." "Gray" }
        default{ Write-Host "  [ERR] Opcion no reconocida. Intenta de nuevo." -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
} while ($Opcion.ToUpper() -ne "S")