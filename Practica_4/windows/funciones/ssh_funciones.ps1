# ssh_funciones.ps1

function Instalar-SSH {
    $estado = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0

    if ($estado.State -eq "Installed") {
        Write-Host "OpenSSH ya esta instalado."
        $respuesta = Read-Host "Deseas reinstalarlo? (s/n)"
        if ($respuesta -eq "s" -or $respuesta -eq "S") {
            Remove-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
            Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
            Write-Host "OpenSSH reinstalado correctamente."
        } else {
            Write-Host "Operacion cancelada."
        }
    } else {
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
        Write-Host "OpenSSH instalado correctamente."
    }
}

function Habilitar-SSH {
    Start-Service sshd
    Set-Service -Name sshd -StartupType Automatic
}

function Configurar-Firewall-SSH {
    $regla = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue

    if ($regla) {
        Write-Host "La regla del firewall para SSH ya existe."
    } else {
        New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" `
            -DisplayName "OpenSSH Server (sshd)" `
            -Enabled True `
            -Direction Inbound `
            -Protocol TCP `
            -Action Allow `
            -LocalPort 22
        Write-Host "Regla de firewall creada correctamente."
    }
}

function Configurar-Shell-Default {
    New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" `
        -Name DefaultShell `
        -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -PropertyType String `
        -Force
    Write-Host "PowerShell configurado como shell default para SSH."
}

function Verificar-SSH {
    Get-Service sshd
    netstat -an | Select-String ":22"
}
