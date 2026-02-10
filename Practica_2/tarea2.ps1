function Test-SegmentIP {
    param([string]$IP)
    return $IP -match "^192\.168\.100\.([1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4])$"
}

function Test-ValidIP {
    param([string]$IP)
    if ($IP -eq "0.0.0.0") { return $false }
    return $IP -as [ipaddress]
}

function Install-DHCPRole {
    Write-Host "Instalando Rol DHCP de forma desatendida..." -ForegroundColor Cyan
    Install-WindowsFeature DHCP -IncludeManagementTools | Out-Null
}

if ((Get-WindowsFeature DHCP).InstallState -ne "Installed") {
    Install-DHCPRole
}

# Variable de control para el bucle
$continuar = $true

do {
    Write-Host "`n=== MODULO DE MONITOREO Y CONFIGURACION (WINDOWS) ===" -ForegroundColor Yellow
    Write-Host "1. Configurar Ambito"
    Write-Host "2. Consultar estado del servicio y ambitos"
    Write-Host "3. Listar concesiones (leases) activas"
    Write-Host "4. Verificar o Reinstalar Rol"
    Write-Host "5. Salir"
    $opcion = Read-Host "Seleccione una opcion"

    switch ($opcion) {
        "1" {
            $Nombre = Read-Host "Nombre del Ambito"
            do { $Ini = Read-Host "IP Inicial (.100.x)"; $v1 = Test-SegmentIP $Ini } until ($v1)
            do { $Fin = Read-Host "IP Final (.100.x)"; $v2 = Test-SegmentIP $Fin } until ($v2)
            do { $GW = Read-Host "Gateway (.100.x)"; $v3 = Test-SegmentIP $GW } until ($v3)
            do { $DNS = Read-Host "IP DNS"; $v4 = Test-ValidIP $DNS } until ($v4)
            $Segundos = Read-Host "Tiempo de concesion (Segundos)"
            $Time = [TimeSpan]::FromSeconds($Segundos)

            Get-DhcpServerv4Scope -ScopeId 192.168.100.0 -ErrorAction SilentlyContinue | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue

            Add-DhcpServerv4Scope -Name $Nombre -StartRange $Ini -EndRange $Fin -SubnetMask 255.255.255.0 -LeaseDuration $Time
            Set-DhcpServerv4OptionValue -OptionId 3 -Value $GW
            Set-DhcpServerv4OptionValue -OptionId 6 -Value $DNS -Force
            
            Set-DhcpServerv4Binding -InterfaceAlias "Ethernet 2" -BindingState $true -ErrorAction SilentlyContinue
            Restart-Service DHCPServer
            Write-Host "Ambito configurado y servicio reiniciado." -ForegroundColor Green
        }
        "2" {
            Write-Host "`n--- ESTADO DEL SERVICIO ---" -ForegroundColor Cyan
            Get-Service DHCPServer | Select-Object Status, Name, DisplayName | Format-Table -AutoSize | Out-Host

            Write-Host "--- AMBITOS ACTIVOS ---" -ForegroundColor Cyan
            $scopes = Get-DhcpServerv4Scope
            if ($scopes) {
                $scopes | Select-Object ScopeId, State, StartRange, EndRange | Format-Table -AutoSize | Out-Host
            } else {
                Write-Host "No hay ambitos configurados." -ForegroundColor Red
            }
        }
        "3" {
            Write-Host "`n--- CONCESIONES ACTIVAS (LEASES) ---" -ForegroundColor Cyan
            $leases = Get-DhcpServerv4Lease -ScopeId 192.168.100.0 -ErrorAction SilentlyContinue
            if ($leases) { 
                $leases | Select-Object IPAddress, HostName, AddressState | Format-Table -AutoSize | Out-Host
            } else { 
                Write-Host "No hay concesiones activas en la red 192.168.100.0." -ForegroundColor Red
            }
        }
        "4" {
            if ((Get-WindowsFeature DHCP).InstallState -eq "Installed") {
                $ri = Read-Host "El Rol ya existe. Reinstalar? (s/n)"
                if ($ri -eq "s") {
                    Uninstall-WindowsFeature DHCP -Remove | Out-Null
                    Install-DHCPRole
                }
            } else {
                Install-DHCPRole
            }
        }
        "5" { 
            Write-Host "Saliendo del script..." -ForegroundColor Yellow
            $continuar = $false 
        }
        default { Write-Host "Opción no válida." -ForegroundColor Red }
    }
} while ($continuar)