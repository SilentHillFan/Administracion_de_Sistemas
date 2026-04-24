#Requires -RunAsAdministrator

Import-Module ActiveDirectory -ErrorAction Stop

$Dominio = (Get-ADDomain).DNSRoot
$NetBIOS = (Get-ADDomain).NetBIOSName

function Mostrar-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "     TESTS RAW - PRACTICA 09" -ForegroundColor Yellow
    Write-Host "     Dominio: $Dominio" -ForegroundColor Gray
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "  [1] Test 1 - Delegacion RBAC (admin_identidad vs admin_storage)"
    Write-Host "  [2] Test 2 - FGPP rechaza contrasena corta"
    Write-Host "  [3] Test 3 - Estado MFA"
    Write-Host "  [4] Test 4 - Bloqueo de cuenta tras 3 fallos"
    Write-Host "  [S] Salir"
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Test1 {
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "  TEST 1 - Delegacion RBAC" -ForegroundColor Yellow
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "  --- ACCION A: admin_identidad resetea contrasena de juan (debe FUNCIONAR) ---" -ForegroundColor Yellow
    Write-Host ""
    $passId = ConvertTo-SecureString "Contrasena123" -AsPlainText -Force
    $credId = New-Object System.Management.Automation.PSCredential("$NetBIOS\admin_identidad", $passId)
    Invoke-Command -ComputerName localhost -Credential $credId -ScriptBlock {
        Import-Module ActiveDirectory
        Set-ADAccountPassword -Identity "juan" -Reset -NewPassword (ConvertTo-SecureString "Contrasena123" -AsPlainText -Force)
        Write-Host "  [OK] Contrasena de juan cambiada exitosamente." -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "  --- ACCION B: admin_storage resetea contrasena de juan (debe FALLAR) ---" -ForegroundColor Yellow
    Write-Host ""
    $passSt = ConvertTo-SecureString "Contrasena123" -AsPlainText -Force
    $credSt = New-Object System.Management.Automation.PSCredential("$NetBIOS\admin_storage", $passSt)
    Invoke-Command -ComputerName localhost -Credential $credSt -ScriptBlock {
        Import-Module ActiveDirectory
        Set-ADAccountPassword -Identity "juan" -Reset -NewPassword (ConvertTo-SecureString "Contrasena123" -AsPlainText -Force)
        Write-Host "  [!] Contrasena cambiada - ACL no esta aplicada correctamente." -ForegroundColor Red
    }

    Write-Host ""
    Read-Host "  Presiona ENTER para volver al menu"
}

function Test2 {
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "  TEST 2 - FGPP (Fine-Grained Password Policy)" -ForegroundColor Yellow
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "  --- INTENTO 1: Contrasena '12345' (5 chars) para admin_identidad (debe FALLAR) ---" -ForegroundColor Yellow
    Write-Host ""
    Set-ADAccountPassword -Identity "admin_identidad" -Reset -NewPassword (ConvertTo-SecureString "12345" -AsPlainText -Force)

    Write-Host ""
    Write-Host "  --- INTENTO 2: Contrasena 'Abc12345' (8 chars) para admin_identidad (debe FALLAR) ---" -ForegroundColor Yellow
    Write-Host ""
    Set-ADAccountPassword -Identity "admin_identidad" -Reset -NewPassword (ConvertTo-SecureString "Abc12345" -AsPlainText -Force)

    Write-Host ""
    Write-Host "  --- INTENTO 3: Contrasena 'Contrasena123456' (16 chars) para admin_identidad (debe FUNCIONAR) ---" -ForegroundColor Yellow
    Write-Host ""
    Set-ADFineGrainedPasswordPolicy -Identity "FGPP_Admins" -PasswordHistoryCount 0 -ErrorAction SilentlyContinue
    Set-ADDefaultDomainPasswordPolicy -Identity $Dominio -PasswordHistoryCount 0 -ErrorAction SilentlyContinue
    Set-ADAccountPassword -Identity "admin_identidad" -Reset -NewPassword (ConvertTo-SecureString "Contrasena123456" -AsPlainText -Force)
    if ($?) {
        Write-Host "  [OK] Contrasena de 16 chars aceptada correctamente." -ForegroundColor Green
    }
    Set-ADFineGrainedPasswordPolicy -Identity "FGPP_Admins" -PasswordHistoryCount 10 -ErrorAction SilentlyContinue
    Set-ADDefaultDomainPasswordPolicy -Identity $Dominio -PasswordHistoryCount 5 -ErrorAction SilentlyContinue

    Write-Host ""
    Read-Host "  Presiona ENTER para volver al menu"
}

function Test3 {
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "  TEST 3 - Estado MFA" -ForegroundColor Yellow
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "  --- GPO MFA_LogonScript ---" -ForegroundColor Yellow
    Write-Host ""
    Get-GPO -Name "MFA_LogonScript" -ErrorAction SilentlyContinue | Select-Object DisplayName, GpoStatus, CreationTime, ModificationTime | Format-List

    Write-Host "  --- Script MFA en SYSVOL ---" -ForegroundColor Yellow
    Write-Host ""
    $scriptPath = "C:\Windows\SYSVOL\sysvol\$Dominio\scripts\MFA_Login_Final2.ps1"
    if (Test-Path $scriptPath) {
        Write-Host "  [OK] Script encontrado: $scriptPath" -ForegroundColor Green
        $info = Get-Item $scriptPath
        Write-Host "  Ultima modificacion: $($info.LastWriteTime)" -ForegroundColor Gray
        Write-Host "  Tamano: $($info.Length) bytes" -ForegroundColor Gray
    } else {
        Write-Host "  [!] Script NO encontrado en SYSVOL." -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "  --- Configuracion MFA en Registro ---" -ForegroundColor Yellow
    Write-Host ""
    $mfa = Get-ItemProperty "HKLM:\SOFTWARE\Practica09\MFA_Config" -ErrorAction SilentlyContinue
    if ($mfa) {
        Write-Host "  Algoritmo    : $($mfa.Algorithm)" -ForegroundColor White
        Write-Host "  Max intentos : $($mfa.MaxFailedAttempts)" -ForegroundColor White
        Write-Host "  Bloqueo      : $($mfa.LockoutDuration_min) minutos" -ForegroundColor White
        Write-Host "  Clave TOTP   : $($mfa.SecretKey_admin_id)" -ForegroundColor Cyan
    } else {
        Write-Host "  [!] Sin configuracion MFA en registro." -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "  --- Log MFA (ultimas 10 lineas) ---" -ForegroundColor Yellow
    Write-Host ""
    $logMFA = "C:\Reportes_P09\MFA\Log_MFA.txt"
    if (Test-Path $logMFA) {
        Get-Content $logMFA -Tail 10
    } else {
        Write-Host "  [!] Sin log MFA todavia. Inicia sesion con algun usuario primero." -ForegroundColor Red
    }

    Write-Host ""
    Read-Host "  Presiona ENTER para volver al menu"
}

function Test4 {
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "  TEST 4 - Bloqueo de cuenta tras 3 fallos" -ForegroundColor Yellow
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "  --- Desbloqueando admin_identidad antes del test ---" -ForegroundColor Yellow
    Unlock-ADAccount -Identity "admin_identidad"
    Write-Host "  [OK] Cuenta desbloqueada." -ForegroundColor Green
    Write-Host ""

    Write-Host "  --- Simulando 3 intentos fallidos ---" -ForegroundColor Yellow
    Write-Host ""

    Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction SilentlyContinue
    for ($i = 1; $i -le 3; $i++) {
        try {
            $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
                [System.DirectoryServices.AccountManagement.ContextType]::Domain, $Dominio)
            $ctx.ValidateCredentials("admin_identidad", "WrongPass$i") | Out-Null
        } catch {}
        Write-Host "  Intento $i de 3 completado." -ForegroundColor Gray
        Start-Sleep -Seconds 1
    }

    Start-Sleep -Seconds 3
    Write-Host ""
    Write-Host "  --- Estado de la cuenta ---" -ForegroundColor Yellow
    Write-Host ""
    Get-ADUser -Identity "admin_identidad" -Properties LockedOut, BadLogonCount, BadPwdCount |
        Select-Object SamAccountName, Enabled, LockedOut, BadLogonCount | Format-List

    $u = Get-ADUser -Identity "admin_identidad" -Properties LockedOut
    if ($u.LockedOut) {
        Write-Host "  [OK] Cuenta BLOQUEADA correctamente." -ForegroundColor Green
    } else {
        Write-Host "  [!] Cuenta no bloqueada automaticamente." -ForegroundColor Red
        Write-Host "      Intenta manualmente desde Win10 con contrasena incorrecta 3 veces." -ForegroundColor Gray
    }

    Write-Host ""
    $des = Read-Host "  Desbloquear admin_identidad ahora? (S/N)"
    if ($des.ToUpper() -eq "S") {
        Unlock-ADAccount -Identity "admin_identidad"
        Write-Host "  [OK] Cuenta desbloqueada." -ForegroundColor Green
    }

    Write-Host ""
    Read-Host "  Presiona ENTER para volver al menu"
}

do {
    Mostrar-Menu
    $op = Read-Host "  Selecciona opcion"
    switch ($op.ToUpper()) {
        "1" { Test1 }
        "2" { Test2 }
        "3" { Test3 }
        "4" { Test4 }
        "S" { Write-Host "  Saliendo..." -ForegroundColor Gray }
        default { Write-Host "  Opcion no valida." -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
} while ($op.ToUpper() -ne "S")
