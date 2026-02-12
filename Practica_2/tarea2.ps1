$ProgressPreference = 'SilentlyContinue'

function Convertir-IPaEntero($Direccion) {
    try {
        $partes = $Direccion.Split('.')
        return ([int64]$partes[0] -shl 24) + ([int64]$partes[1] -shl 16) + ([int64]$partes[2] -shl 8) + [int64]$partes[3]
    } catch { return 0 }
}

function EsDireccionValida($Direccion) {
    if ($Direccion -notmatch '^([0-9]{1,3}\.){3}[0-9]{1,3}$') { return $false }
    $partes = $Direccion.Split('.')
    foreach ($segmento in $partes) { if ([int]$segmento -lt 0 -or [int]$segmento -gt 255) { return $false } }
    if ($Direccion -eq "127.0.0.1" -or $Direccion -eq "0.0.0.0" -or $Direccion -eq "255.255.255.255") { return $false }
    if ([int]$partes[2] -eq 0 -and [int]$partes[3] -eq 0) { return $false }
    return $true
}

function Revisar-Instalacion {
    Write-Host "====================================================="
    Write-Host "Comprobando estado del rol DHCP en el servidor"
    Write-Host "====================================================="
    $estado = Get-WindowsFeature -Name DHCP
    if ($estado.Installed) {
        Write-Host "El rol DHCP se encuentra instalado."
        Get-Service DHCPServer | Select-Object -ExpandProperty Status
    } else {
        Write-Host "El rol DHCP no esta instalado."
    }
    Read-Host "Pulsa Enter para regresar"
}

function Ejecutar-Instalacion {
    Write-Host "====================================================="
    $estado = Get-WindowsFeature -Name DHCP
    if (-not $estado.Installed) {
        Write-Host "Iniciando proceso de instalacion del rol DHCP"
        Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
        Write-Host "Instalacion finalizada."
    } else {
        Write-Host "El rol ya estaba instalado en el sistema."
    }
    Read-Host "Pulsa Enter para regresar"
}

function Configurar-Ambito {
    Write-Host "====================================================="
    Write-Host "        CONFIGURADOR DE AMBITO DHCP"
    Write-Host "====================================================="
    $NombreAmbito = Read-Host "Nombre del nuevo ambito"

    while ($true) { 
        $IPInicio = Read-Host "Direccion IP inicial"
        if (EsDireccionValida $IPInicio) { break } 
    }

    while ($true) {
        $IPFin = Read-Host "Direccion IP final"
        if (EsDireccionValida $IPFin) {
            if ((Convertir-IPaEntero $IPFin) -le (Convertir-IPaEntero $IPInicio)) {
                Write-Host "La direccion final debe ser mayor que la inicial." -ForegroundColor Red
            } else { break }
        }
    }

    $PuertaEnlace = Read-Host "Puerta de enlace (opcional)"
    $ServidorDNS = Read-Host "Servidor DNS (opcional)"
    $TiempoConcesion = Read-Host "Tiempo de concesion en segundos"
    if ([string]::IsNullOrWhiteSpace($TiempoConcesion)) { $TiempoConcesion = 600 }

    $oct = $IPInicio.Split('.')
    $BaseRed = "$($oct[0]).$($oct[1]).$($oct[2])"
    $IdRed = "$BaseRed.0"
    $IPServidor = "$BaseRed.1"

    Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False

    $Adaptador = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
    if ($Adaptador) {
        Write-Host "Subred detectada: $IdRed"
        $Existe = Get-NetIPAddress -InterfaceAlias $Adaptador.Name -IPAddress $IPServidor -ErrorAction SilentlyContinue
        if (-not $Existe) {
            Get-NetIPAddress -InterfaceAlias $Adaptador.Name -AddressFamily IPv4 |
                Where-Object { $_.IPAddress -like "$BaseRed.*" } |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

            New-NetIPAddress -InterfaceAlias $Adaptador.Name -IPAddress $IPServidor -PrefixLength 24 -SkipAsSource $true -ErrorAction SilentlyContinue | Out-Null
        }
    }

    try {
        Start-Service DHCPServer -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

        Remove-DhcpServerv4Scope -ScopeId $IdRed -Force -ErrorAction SilentlyContinue | Out-Null

        Add-DhcpServerv4Scope -Name $NombreAmbito -StartRange $IPInicio -EndRange $IPFin -SubnetMask 255.255.255.0 -State Active -LeaseDuration (New-TimeSpan -Seconds $TiempoConcesion) -ErrorAction Stop | Out-Null

        if (-not [string]::IsNullOrWhiteSpace($PuertaEnlace)) {
            Set-DhcpServerv4OptionValue -ScopeId $IdRed -OptionId 3 -Value $PuertaEnlace -Force | Out-Null
        }

        if (-not [string]::IsNullOrWhiteSpace($ServidorDNS)) {
            if (Test-Connection -ComputerName $ServidorDNS -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                Write-Host "Servidor DNS accesible."
            }
            Set-DhcpServerv4OptionValue -ScopeId $IdRed -OptionId 6 -Value $ServidorDNS -Force | Out-Null
        }

        Restart-Service DHCPServer -Force
        Write-Host "Ambito configurado y servicio reiniciado correctamente."
    } catch {
        Write-Host "====================================================="
        Write-Host "Error en la configuracion del ambito." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Yellow
    }

    Read-Host "Pulsa Enter para regresar"
}

function Mostrar-Conexiones {
    Write-Host "====================================================="
    Write-Host "        REGISTRO DE CLIENTES DHCP"
    Write-Host "====================================================="
    $registros = Get-DhcpServerv4Scope | Get-DhcpServerv4Lease -ErrorAction SilentlyContinue
    if ($registros) { $registros | Format-Table -AutoSize }
    else { Write-Host "No existen concesiones registradas." }
    Read-Host "Pulsa Enter para regresar"
}

while ($true) {
    Write-Host "`n*****************************************************"
    Write-Host "          ADMINISTRADOR DEL SERVICIO DHCP"
    Write-Host "*****************************************************"
    Write-Host "1) Revisar instalacion del rol"
    Write-Host "2) Instalar rol DHCP"
    Write-Host "3) Crear o modificar ambito"
    Write-Host "4) Consultar clientes activos"
    Write-Host "5) Salir del sistema"
    Write-Host "-----------------------------------------------------"

    $opcion = Read-Host "Seleccione una opcion"

    switch ($opcion) {
        "1" { Revisar-Instalacion }
        "2" { Ejecutar-Instalacion }
        "3" { Configurar-Ambito }
        "4" { Mostrar-Conexiones }
        "5" { exit }
    }
}
