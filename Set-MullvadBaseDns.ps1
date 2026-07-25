#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
Configures Mullvad Base DNS-over-HTTPS on every physical Ethernet and Wi-Fi adapter.

.USAGE
  .\Set-MullvadBaseDns.ps1 --set
  .\Set-MullvadBaseDns.ps1 --reset-default

.NOTES
Mullvad Base blocks ads, trackers, and malware.
DoH fallback to unencrypted UDP DNS is disabled.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Mullvad = [ordered]@{
    IPv4       = '194.242.2.4'
    IPv6       = '2a07:e340::4'
    DohTemplate = 'https://base.dns.mullvad.net/dns-query'
}

function Show-Usage {
    Write-Host 'Usage:'
    Write-Host '  .\Set-MullvadBaseDns.ps1 --set'
    Write-Host '  .\Set-MullvadBaseDns.ps1 --reset-default'
}

function Get-TargetAdapter {
    # IANA interface types: 6 = Ethernet, 71 = IEEE 802.11 Wi-Fi.
    @(Get-NetAdapter -Physical -ErrorAction Stop |
        Where-Object { ([uint32]$_.InterfaceType) -in @(6, 71) } |
        Sort-Object -Property ifIndex -Unique)
}

function Assert-DohCmdletsAvailable {
    $requiredCommands = @(
        'Get-DnsClientDohServerAddress',
        'Add-DnsClientDohServerAddress',
        'Set-DnsClientDohServerAddress'
    )

    $missing = @(
        foreach ($command in $requiredCommands) {
            if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
                $command
            }
        }
    )

    if ($missing.Count -gt 0) {
        throw "System-wide DNS-over-HTTPS is not available on this Windows installation. Missing command(s): $($missing -join ', '). Windows 11 or another supported Windows release is required."
    }
}

function Assert-NotActiveDirectoryDomainJoined {
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if ($computerSystem.PartOfDomain) {
        throw 'Refusing to replace DNS on an Active Directory domain-joined computer. Public DNS would normally break AD name resolution, logon, Group Policy, and service discovery.'
    }
}

function Set-DohResolverRegistration {
    param(
        [Parameter(Mandatory)]
        [string]$ServerAddress,

        [Parameter(Mandatory)]
        [string]$DohTemplate
    )

    $existing = Get-DnsClientDohServerAddress -ServerAddress $ServerAddress -ErrorAction SilentlyContinue

    if ($null -eq $existing) {
        Add-DnsClientDohServerAddress `
            -ServerAddress $ServerAddress `
            -DohTemplate $DohTemplate `
            -AutoUpgrade $true `
            -AllowFallbackToUdp $false `
            -ErrorAction Stop
    }
    else {
        Set-DnsClientDohServerAddress `
            -ServerAddress $ServerAddress `
            -DohTemplate $DohTemplate `
            -AutoUpgrade $true `
            -AllowFallbackToUdp $false `
            -ErrorAction Stop
    }
}

function Set-AdapterMullvadDns {
    param(
        [Parameter(Mandatory)]
        [object]$Adapter
    )

    $ipv4Config = Get-DnsClientServerAddress `
        -InterfaceIndex $Adapter.ifIndex `
        -AddressFamily IPv4 `
        -ErrorAction Stop

    $ipv6Config = Get-DnsClientServerAddress `
        -InterfaceIndex $Adapter.ifIndex `
        -AddressFamily IPv6 `
        -ErrorAction Stop

    if ($null -ne $ipv4Config) {
        Set-DnsClientServerAddress `
            -InputObject $ipv4Config `
            -ServerAddresses $Mullvad.IPv4 `
            -ErrorAction Stop
    }

    if ($null -ne $ipv6Config) {
        Set-DnsClientServerAddress `
            -InputObject $ipv6Config `
            -ServerAddresses $Mullvad.IPv6 `
            -ErrorAction Stop
    }
}

function Reset-AdapterDns {
    param(
        [Parameter(Mandatory)]
        [object]$Adapter
    )

    Set-DnsClientServerAddress `
        -InterfaceIndex $Adapter.ifIndex `
        -ResetServerAddresses `
        -ErrorAction Stop
}

function Show-Result {
    param(
        [Parameter(Mandatory)]
        [object[]]$Adapters
    )

    $indexes = @($Adapters | ForEach-Object { [uint32]$_.ifIndex })

    Get-DnsClientServerAddress -InterfaceIndex $indexes -ErrorAction Stop |
        Sort-Object -Property InterfaceIndex, AddressFamily |
        Select-Object InterfaceAlias, InterfaceIndex, AddressFamily, ServerAddresses |
        Format-Table -AutoSize
}

if ($args.Count -ne 1 -or $args[0] -notin @('--set', '--reset-default')) {
    Show-Usage
    exit 64
}

$mode = [string]$args[0]

try {
    Import-Module DnsClient -ErrorAction Stop
    Import-Module NetAdapter -ErrorAction Stop

    $adapters = @(Get-TargetAdapter)
    if ($adapters.Count -eq 0) {
        throw 'No physical Ethernet or Wi-Fi adapters were found.'
    }

    Write-Host 'Target adapters:' -ForegroundColor Cyan
    $adapters |
        Select-Object Name, ifIndex, Status, InterfaceDescription |
        Format-Table -AutoSize

    switch ($mode) {
        '--set' {
            Assert-DohCmdletsAvailable
            Assert-NotActiveDirectoryDomainJoined

            Set-DohResolverRegistration `
                -ServerAddress $Mullvad.IPv4 `
                -DohTemplate $Mullvad.DohTemplate

            Set-DohResolverRegistration `
                -ServerAddress $Mullvad.IPv6 `
                -DohTemplate $Mullvad.DohTemplate

            $failures = @()
            foreach ($adapter in $adapters) {
                try {
                    Set-AdapterMullvadDns -Adapter $adapter
                    Write-Host "Configured: $($adapter.Name)" -ForegroundColor Green
                }
                catch {
                    $failures += "[$($adapter.Name)] $($_.Exception.Message)"
                    Write-Warning "Failed to configure '$($adapter.Name)': $($_.Exception.Message)"
                }
            }

            Clear-DnsClientCache -ErrorAction SilentlyContinue
            Show-Result -Adapters $adapters

            if ($failures.Count -gt 0) {
                throw "One or more adapters failed:`n$($failures -join [Environment]::NewLine)"
            }

            $upAdapters = @($adapters | Where-Object Status -eq 'Up')
            if ($upAdapters.Count -gt 0) {
                try {
                    $null = Resolve-DnsName `
                        -Name 'mullvad.net' `
                        -Type A `
                        -DnsOnly `
                        -NoHostsFile `
                        -QuickTimeout `
                        -ErrorAction Stop

                    Write-Host 'DNS resolution test succeeded.' -ForegroundColor Green
                }
                catch {
                    Write-Warning "The configuration was applied, but the DNS resolution test failed: $($_.Exception.Message)"
                }
            }

            Write-Host 'Mullvad Base DoH is configured with unencrypted fallback disabled.' -ForegroundColor Green
        }

        '--reset-default' {
            $failures = @()
            foreach ($adapter in $adapters) {
                try {
                    Reset-AdapterDns -Adapter $adapter
                    Write-Host "Reset: $($adapter.Name)" -ForegroundColor Green
                }
                catch {
                    $failures += "[$($adapter.Name)] $($_.Exception.Message)"
                    Write-Warning "Failed to reset '$($adapter.Name)': $($_.Exception.Message)"
                }
            }

            Clear-DnsClientCache -ErrorAction SilentlyContinue
            Show-Result -Adapters $adapters

            if ($failures.Count -gt 0) {
                throw "One or more adapters failed:`n$($failures -join [Environment]::NewLine)"
            }

            Write-Host 'DNS server addresses were reset to the Windows defaults supplied by automatic network configuration.' -ForegroundColor Green
            Write-Host 'The global Mullvad DoH registration was left in place because it is inactive unless an adapter uses the Mullvad resolver IPs.' -ForegroundColor DarkGray
        }
    }
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
