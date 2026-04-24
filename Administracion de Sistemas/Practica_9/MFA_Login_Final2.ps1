$MaxIntentos  = 3
$BloqueoMin   = 30
$LogMFA       = "C:\Reportes_P09\MFA\Log_MFA.txt"
$BloqueoDir   = "C:\Reportes_P09\MFA\bloqueos"

$ClavesPorUsuario = @{
    "admin_identidad" = "5YTUOUE4BD45VEZDXKKMTJ2F6R5TA2XV"
    "admin_storage"   = "ISUABADLLQ3JBBIKETZGAHVZA4M5UWTV"
    "admin_politicas" = "Z2EE5D6YFBNBNL2X2WDLIDPPRCQIS7LV"
    "admin_auditoria" = "BO2MNS36JB7MQBQ7BSZT4DAW5DAJ2KX2"
    "juan"            = "43EQB5CEFOCYX5YRDNGLJYV3XNQZ5D3P"
    "pedro"           = "QUBYG7EP7FWBCMTDMMO77GTBO2BYDXME"
    "luis"            = "NOCWFI6CZBDPOROZFMLSMGB5YX2IUD3O"
    "carlos"          = "N7UGLLLIGRY5PJG7FXJE37U47UKTMEHU"
    "diego"           = "4PX23H4UT7XCGOFT3OP7AA7Q4L7RESPP"
    "maria"           = "XCWAPPOUSSWBFWW7YRBPYKQ2IZDJ2UL7"
    "ana"             = "O6SVMYIBY3CT2A7WETDHAAWJ4NELR6X3"
    "sofia"           = "ERIP3X3B4EB2DBQM4CK7SZ5T3M6AWSYL"
    "elena"           = "P66TM2BRWWA4O2EBIAHCMU6ZH4PJ7XQJ"
    "laura"           = "3ISCIPE6NMW45L4P33SKDTLH6R5LNGMB"
}

function ConvertFrom-Base32 {
    param([string]$Base32)
    $Base32 = $Base32.ToUpper().TrimEnd("=")
    $base32Chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    $bits = ""
    foreach ($c in $Base32.ToCharArray()) {
        $val = $base32Chars.IndexOf($c)
        if ($val -lt 0) { continue }
        $bits += [Convert]::ToString($val, 2).PadLeft(5, "0")
    }
    $bytes = New-Object byte[] ([Math]::Floor($bits.Length / 8))
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($bits.Substring($i * 8, 8), 2)
    }
    return $bytes
}

function Test-TOTPCode {
    param([string]$SecretBase32, [string]$CodigoIngresado)
    $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach ($offset in @(-1, 0, 1)) {
        $counter      = [Math]::Floor($epoch / 30) + $offset
        $counterBytes = [BitConverter]::GetBytes([long]$counter)
        if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($counterBytes) }
        $keyBytes = ConvertFrom-Base32 $SecretBase32
        $hmac     = New-Object System.Security.Cryptography.HMACSHA1
        $hmac.Key = $keyBytes
        $hash     = $hmac.ComputeHash($counterBytes)
        $off      = $hash[$hash.Length - 1] -band 0x0F
        $code     = (($hash[$off]     -band 0x7F) -shl 24) -bor
                    (($hash[$off + 1] -band 0xFF) -shl 16) -bor
                    (($hash[$off + 2] -band 0xFF) -shl 8)  -bor
                     ($hash[$off + 3] -band 0xFF)
        if ($CodigoIngresado -eq ($code % 1000000).ToString("000000")) { return $true }
    }
    return $false
}

function Write-MFALog {
    param([string]$Mensaje, [string]$Estado)
    $ts    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $linea = "[$ts] USER=$usuario | ESTADO=$Estado | $Mensaje"
    if (-not (Test-Path (Split-Path $LogMFA))) {
        New-Item -Path (Split-Path $LogMFA) -ItemType Directory -Force | Out-Null
    }
    Add-Content -Path $LogMFA -Value $linea -ErrorAction SilentlyContinue
}

if (-not (Test-Path $BloqueoDir)) {
    New-Item -ItemType Directory -Path $BloqueoDir -Force | Out-Null
}

$usuarioRaw = $env:USERNAME
$usuario    = ($usuarioRaw -replace ".*\\", "" -replace "@.*", "").ToLower()
$ClaveTOTP  = $ClavesPorUsuario[$usuario]
$archivoBloq = "$BloqueoDir\$usuario.bloqueado"

# Verificar si esta bloqueado
if (Test-Path $archivoBloq) {
    $bloqInfo   = Get-Content $archivoBloq
    $bloqTiempo = [datetime]::Parse($bloqInfo)
    $minutos    = (Get-Date) - $bloqTiempo | Select-Object -ExpandProperty TotalMinutes
    if ($minutos -lt $BloqueoMin) {
        $restantes = [math]::Ceiling($BloqueoMin - $minutos)
        Write-Host ""
        Write-Host "  CUENTA BLOQUEADA. Intenta en $restantes minutos." -ForegroundColor Red
        Write-MFALog "Intento con cuenta bloqueada. Faltan $restantes min." "BLOQUEADO"
        Stop-Process -Id $PID -Force
    } else {
        Remove-Item $archivoBloq -Force
    }
}

if (-not $ClaveTOTP) {
    Write-MFALog "Usuario sin clave MFA" "SIN_CLAVE"
    exit 0
}

Write-Host ""
Write-Host "  ==========================================" -ForegroundColor Cyan
Write-Host "      AUTENTICACION MFA REQUERIDA           " -ForegroundColor Yellow
Write-Host "      Usuario : $usuario                    " -ForegroundColor White
Write-Host "      Hora    : $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor White
Write-Host "  ==========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Abre Google Authenticator: $usuario@practica.local" -ForegroundColor Gray
Write-Host ""

$intentos        = 0
$accesoConcedido = $false

while ($intentos -lt $MaxIntentos) {
    $codigo = Read-Host "  Verification code"
    if (Test-TOTPCode -SecretBase32 $ClaveTOTP -CodigoIngresado $codigo) {
        $accesoConcedido = $true
        Write-Host "  [OK] Acceso concedido." -ForegroundColor Green
        Write-MFALog "Token valido. Acceso concedido." "OK"
        break
    } else {
        $intentos++
        $restantes = $MaxIntentos - $intentos
        Write-Host "  [X] Codigo incorrecto. Intentos restantes: $restantes" -ForegroundColor Red
        Write-MFALog "Codigo incorrecto. Intento $intentos de $MaxIntentos" "FALLO"
    }
}

if (-not $accesoConcedido) {
    Write-Host ""
    Write-Host "  ACCESO DENEGADO. Cuenta bloqueada por $BloqueoMin minutos." -ForegroundColor Red
    Write-MFALog "3 intentos fallidos. Cuenta bloqueada $BloqueoMin min." "BLOQUEADO"

    # Guardar bloqueo en archivo (mecanismo propio del script)
    (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") | Out-File $archivoBloq -Encoding UTF8

    # Bloquear la cuenta REALMENTE en Active Directory
    try {
        Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction SilentlyContinue
        Import-Module ActiveDirectory -ErrorAction SilentlyContinue
        $dominio = (Get-ADDomain).DNSRoot

        # Disparar intentos fallidos para activar el lockout de AD (necesita minimo LockoutThreshold intentos)
        1..4 | ForEach-Object {
            try {
                $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
                    [System.DirectoryServices.AccountManagement.ContextType]::Domain, $dominio)
                $ctx.ValidateCredentials($usuario, "WrongMFA_Bloqueo_$_") | Out-Null
            } catch {}
        }

        Start-Sleep -Seconds 2

        # Verificar si quedo bloqueado en AD
        $adUser = Get-ADUser -Identity $usuario -Properties LockedOut, BadLogonCount, Enabled -ErrorAction SilentlyContinue
        if ($adUser -and $adUser.LockedOut) {
            Write-Host ""
            Write-Host "  --- EVIDENCIA TEST 4 ---" -ForegroundColor Cyan
            Write-Host "  Usuario      : $($adUser.SamAccountName)" -ForegroundColor White
            Write-Host "  LockedOut    : $($adUser.LockedOut)"      -ForegroundColor Red
            Write-Host "  Enabled      : $($adUser.Enabled)"        -ForegroundColor Yellow
            Write-Host "  BadLogonCount: $($adUser.BadLogonCount)"  -ForegroundColor White
            Write-Host "  Timestamp    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
            Write-MFALog "Cuenta bloqueada en AD. BadLogonCount=$($adUser.BadLogonCount)" "BLOQUEADO_AD"
        } else {
            # Si no se activo el lockout automatico, deshabilitar la cuenta directamente
            Disable-ADAccount -Identity $usuario -ErrorAction SilentlyContinue
            $adUser = Get-ADUser -Identity $usuario -Properties LockedOut, Enabled -ErrorAction SilentlyContinue
            Write-Host ""
            Write-Host "  --- EVIDENCIA TEST 4 ---" -ForegroundColor Cyan
            Write-Host "  Usuario      : $($adUser.SamAccountName)" -ForegroundColor White
            Write-Host "  LockedOut    : $($adUser.LockedOut)"      -ForegroundColor Red
            Write-Host "  Enabled      : $($adUser.Enabled)"        -ForegroundColor Yellow
            Write-Host "  Timestamp    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
            Write-MFALog "Cuenta deshabilitada por MFA fallido" "DESHABILITADO"
        }
    } catch {
        Write-MFALog "Error al bloquear cuenta en AD: $_" "ERROR"
    }

    Write-Host ""
    Write-Host "  TOMA CAPTURA DE ESTA PANTALLA PARA EL REPORTE." -ForegroundColor Cyan
    Write-Host ""
    Read-Host "  Presiona ENTER para salir"
    Stop-Process -Id $PID -Force
}