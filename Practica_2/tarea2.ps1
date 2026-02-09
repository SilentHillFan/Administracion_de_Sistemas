if (!(Get-WindowsFeature DHCP).Installed) { Install-WindowsFeature DHCP -IncludeManagementTools }

$Nombre = Read-Host "Nombre del Ambito"

do {
    $Inicio = Read-Host "IP Inicial (192.168.100.50)"
    $Ultimo = ($Inicio -split '\.')[3]
} until ($Inicio -like "192.168.100.*" -and [int]$Ultimo -ge 50 -and [int]$Ultimo -le 150)

$Final = Read-Host "IP Final"
$DNS   = Read-Host "IP del DNS"

if (!(Get-DhcpServerv4Scope -ScopeId 192.168.100.0 -ErrorAction SilentlyContinue)) {
    Add-DhcpServerv4Scope -Name $Nombre -StartRange $Inicio -EndRange $Final -SubnetMask 255.255.255.0
    Set-DhcpServerv4OptionValue -OptionId 6 -Value $DNS
}

Get-DhcpServerv4Lease -ScopeId 192.168.100.0