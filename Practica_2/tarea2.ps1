$ProgressPreference = 'SilentlyContinue'

function Validar-IP {
    param([string]$ip)
    if ([string]::IsNullOrWhiteSpace($ip)) { return $false }
    if (-not ($ip -match '^([0-9]{1,3}\.){3}[0-9]{1,3}$')) { return $false }
    foreach ($o in $ip.Split('.')) {
        if ([int]$o -gt 255) { return $false }
    }
    return $true
}

function IP-a-Entero {
    param([string]$ip)
    $o = $ip.Split('.')
    return ([int]$o[0] -shl 24) -bor ([int]$o[1] -shl 16) -bor ([int]$o[2] -shl 8) -bor ([int]$o[3])
}

function Entero-a-IP {
    param([int]$n)
    return "$(($n -shr 24) -band 255).$((($n -shr 16) -band 255)).$((($n -shr 8) -band 255)).$($n -band 255)"
}

function Siguiente-IP {
    param([string]$ip)
    return Entero-a-IP ((IP-a-Entero $ip) + 1)
}

function Calcular-Mascara24 {
    return "255.255.255.0"
}

function Configurar-IPServidor {
    param([string]$ip)
    $mask = Calcular-Mascara24
    $prefix = 24
    $adapter = Get-NetAdapter -Name "Ethernet 2" -ErrorAction SilentlyContinue
    if (-not $adapter) {
        Write-Host "No se encontro interfaz Ethernet 2" -ForegroundColor Yellow
        return
    }
    Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -IPAddress $ip -PrefixLength $prefix -InterfaceIndex $adapter.InterfaceIndex -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Servidor configurado con IP $ip "
}

function Verificar-EstadoServicio {
    Write-Host "__________________________________"
    if ((Get-WindowsFeature DHCP).Installed) {
        Write-Host "DHCP esta instalado."
        $serv = Get-Service DHCPServer -ErrorAction SilentlyContinue
        if ($serv.Status -eq "Running") {
            Write-Host "     Estado: EN EJECUCION" -ForegroundColor Green
        } else {
            Write-Host "     Estado: DETENIDO" -ForegroundColor Yellow
        }
    } else {
        Write-Host "DHCP NO esta instalado." -ForegroundColor Red
    }
    Read-Host "Presiona Enter para continuar..."
}

function Instalar-DHCP {
    Write-Host "_______________________________________"
    if ((Get-WindowsFeature DHCP).Installed) {
        do { $r = Read-Host "Servicio instalado, quiere volver a instalarlo? (y/n)" } until ($r -in @("y","n"))
        if ($r -eq "n") { return }
        Uninstall-WindowsFeature DHCP -IncludeManagementTools | Out-Null
        Restart-Computer -Force
        return
    }
    Install-WindowsFeature DHCP -IncludeManagementTools | Out-Null
    Add-DhcpServerInDC | Out-Null
    Write-Host "DHCP instalado correctamente."
    Read-Host "Presiona Enter para continuar..."
}

function Limpiar-ScopesDHCP {
    Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue | Out-Null
}

function Forzar-InterfazDHCP {
    Set-DhcpServerv4Binding -InterfaceAlias "Ethernet 2" -BindingState $true -ErrorAction SilentlyContinue
    Restart-Service DHCPServer -Force
}

function Opcion-Configurar {
    Write-Host "+++++++++++++++++++++++++++++++++++++++++++++++++"
    Write-Host "      CONFIGURACION DEL AMBITO                   "
    Write-Host "+++++++++++++++++++++++++++++++++++++++++++++++++"
    if (-not ((Get-WindowsFeature DHCP).Installed)) {
        Write-Host "DHCP no instalado." -ForegroundColor Red
        Read-Host "Presiona Enter para continuar..."
        return
    }
    Limpiar-ScopesDHCP
    $scope = Read-Host "Nombre del ambito (Scope)"
    do { $start = Read-Host "IP inicial (del servidor)" } until (Validar-IP $start)
    do { $end = Read-Host "IP final" } until (Validar-IP $end)
    $leaseInput = Read-Host "Duracion de la concesion (en SEGUNDOS) [Ej: 3600]"
    if ([string]::IsNullOrWhiteSpace($leaseInput)) { $leaseInput = 691200 }
    $leaseTime = New-TimeSpan -Seconds ([int]$leaseInput)
    $poolStart = Siguiente-IP $start
    $mask = Calcular-Mascara24
    Write-Host "Aplicando cambios..."
    Configurar-IPServidor $start
    $scopeObj = Add-DhcpServerv4Scope -Name $scope -StartRange $poolStart -EndRange $end -SubnetMask $mask -LeaseDuration $leaseTime -State Active
    Forzar-InterfazDHCP
    $gateway = Read-Host "Gateway (opcional)"
    if (Validar-IP $gateway) {
        Set-DhcpServerv4OptionValue -ScopeId $scopeObj.ScopeId -Router $gateway -Force | Out-Null
    }
    $dns = Read-Host "DNS (opcional)"
    if (Validar-IP $dns) {
        Set-DhcpServerv4OptionValue -ScopeId $scopeObj.ScopeId -DnsServer $dns -Force | Out-Null
    }
    Write-Host ""
    Write-Host "DHCP configurado correctamente." -ForegroundColor Green
    Write-Host "      Servidor:   $start"
    Write-Host "      Pool desde: $poolStart"
    Write-Host "      Lease:      $leaseInput segundos"
    Read-Host "Presiona Enter para continuar..."
}

function Opcion-Monitoreo {
    if (-not ((Get-WindowsFeature DHCP).Installed)) {
        Write-Host "DHCP no instalado." -ForegroundColor Red
        Read-Host "Presiona Enter para continuar..."
        return
    }
    Write-Host "________________________________________"
    Write-Host "CTRL + C para salir del monitoreo"
    Start-Sleep -Seconds 1
    while ($true) {
        Clear-Host
        Write-Host "+++ MONITOREO DHCP +++"
        Get-Service DHCPServer | Select-Object Status, Name
        Write-Host ""
        $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
        foreach ($s in $scopes) {
            Write-Host "Ambito: $($s.Name) [$($s.ScopeId)]" -ForegroundColor Cyan
            $leases = Get-DhcpServerv4Lease -ScopeId $s.ScopeId -ErrorAction SilentlyContinue
            if ($leases) { $leases | Format-Table -AutoSize }
            else { Write-Host "   No hay registro de leases." }
            Write-Host ""
        }
        Start-Sleep 5
    }
}

while ($true) {
    Write-Host "`n+++++++++++++++++++++++++++++++++++++++++"
    Write-Host "      SISTEMA DHCP"
    Write-Host "+++++++++++++++++++++++++++++++++++++++++++"
    Write-Host "1) Verificar instalacion "
    Write-Host "2) Instalar DHCP"
    Write-Host "3) Configurar Ambito "
    Write-Host "4) Monitorear Leases"
    Write-Host "5) Salir"
    Write-Host "____________________________________________"
    $opt = Read-Host "Selecciona una opcion"
    switch ($opt) {
        "1" { Verificar-EstadoServicio }
        "2" { Instalar-DHCP }
        "3" { Opcion-Configurar }
        "4" { Opcion-Monitoreo }
        "5" { exit }
    }
}