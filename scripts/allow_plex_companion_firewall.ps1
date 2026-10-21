<#
.SYNOPSIS
  Lets Home Assistant and other Plex apps on your home network find and control Plezy.

.DESCRIPTION
  Plezy's Plex Companion feature needs two inbound Windows Firewall rules:
    UDP 32412  how Home Assistant finds Plezy (it broadcasts a search)
    TCP 32500  how Home Assistant controls Plezy
  Rules only apply to the network "profile" your connection uses. A home network that
  Windows labels "Public" ignores rules made for "Private", which makes Plezy
  invisible to Home Assistant until media plays. This script shows your profiles,
  can switch Public ones to Private, and (re)creates both rules.

  Run it from an ADMINISTRATOR PowerShell window.

.PARAMETER MakeNetworkPrivate
  Switch every connection currently marked Public to Private. Only do this for a
  network you trust, such as your home network.

.PARAMETER IncludePublic
  Also open the rules on Public networks (not recommended).

.PARAMETER AnyNetwork
  Allow connections from any address, not only your local subnet.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\allow_plex_companion_firewall.ps1 -MakeNetworkPrivate
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$MakeNetworkPrivate,
    [switch]$IncludePublic,
    [switch]$AnyNetwork
)

$ErrorActionPreference = 'Stop'
$tcpName = 'Plezy Plex Companion TCP'
$udpName = 'Plezy Plex Companion UDP'

Write-Host ''
Write-Host 'Your active network connections:'
$connections = @(Get-NetConnectionProfile)
foreach ($c in $connections) {
    Write-Host ('  {0}: {1}' -f $c.Name, $c.NetworkCategory)
}

$public = @($connections | Where-Object { $_.NetworkCategory -eq 'Public' })
if ($public.Count -gt 0) {
    if ($MakeNetworkPrivate) {
        foreach ($c in $public) {
            Set-NetConnectionProfile -InterfaceIndex $c.InterfaceIndex -NetworkCategory Private
            Write-Host ('  Switched "{0}" to Private.' -f $c.Name)
        }
    } else {
        Write-Warning ('One or more connections are marked Public. Plezy will stay invisible to Home Assistant on them. ' +
            'Re-run with -MakeNetworkPrivate if this is your home network.')
    }
}

$profiles = @('Private', 'Domain')
if ($IncludePublic) { $profiles += 'Public' }

foreach ($name in @($tcpName, $udpName)) {
    Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
}

$common = @{
    Direction = 'Inbound'
    Action    = 'Allow'
    Profile   = $profiles
}
if (-not $AnyNetwork) { $common['RemoteAddress'] = 'LocalSubnet' }

New-NetFirewallRule -DisplayName $tcpName -Protocol TCP -LocalPort 32500 @common | Out-Null
New-NetFirewallRule -DisplayName $udpName -Protocol UDP -LocalPort 32412 @common | Out-Null

Write-Host ''
Write-Host ('Created inbound rules for profiles: {0}' -f ($profiles -join ', '))
if (-not $AnyNetwork) { Write-Host 'Allowed sources: your local subnet only.' }
Get-NetFirewallRule -DisplayName $tcpName, $udpName | Select-Object DisplayName, Enabled, Direction, Action | Format-Table -AutoSize
Write-Host 'Done. Restart Plezy, then run scripts\plex_companion_check.py from another computer to confirm.'
