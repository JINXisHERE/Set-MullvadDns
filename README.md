Mullvad Base DNS-over-HTTPS for Windows

Set-MullvadBaseDns.ps1 configures Mullvad Base encrypted DNS on all physical Ethernet and Wi-Fi adapters detected by Windows.

Mullvad Base blocks:

Ads

Trackers

Malware domains

The script supports two operations:

--set
--reset-default

Configuration

Setting

Value

IPv4 resolver

194.242.2.4

IPv6 resolver

2a07:e340::4

DoH template

https://base.dns.mullvad.net/dns-query

Automatic DoH upgrade

Enabled

Fallback to unencrypted UDP DNS

Disabled

Requirements

Windows 11, Windows Server 2022, or another Windows release that provides the DnsClient DoH cmdlets

Windows PowerShell 5.1 or later

Administrator privileges

The following PowerShell cmdlets:

Get-DnsClientDohServerAddress

Add-DnsClientDohServerAddress

Set-DnsClientDohServerAddress

Set-DnsClientServerAddress

Get-NetAdapter

Check whether the required DoH cmdlets are available:

Get-Command Get-DnsClientDohServerAddress, `
            Add-DnsClientDohServerAddress, `
            Set-DnsClientDohServerAddress

The script exits without changing DNS settings when the required DoH cmdlets are unavailable.

Files

.
├── README.md
└── Set-MullvadBaseDns.ps1

Usage

Open Windows PowerShell as Administrator, change to the directory containing the script, and run one of the following commands.

Configure Mullvad Base DoH

.\Set-MullvadBaseDns.ps1 --set

This operation:

Verifies that the required DoH cmdlets exist.

Refuses to proceed on an Active Directory domain-joined computer.

Registers the Mullvad IPv4 and IPv6 resolvers as known DoH servers.

Enables automatic DoH use for both resolver addresses.

Disables fallback to unencrypted UDP DNS.

Assigns the Mullvad resolver addresses to every targeted adapter.

Clears the Windows DNS client cache.

Displays the resulting DNS configuration.

Runs a DNS resolution test when at least one targeted adapter is connected.

Reset adapters to default DNS

.\Set-MullvadBaseDns.ps1 --reset-default

This resets the targeted adapters to the DNS servers supplied by DHCP or the adapter's automatic network configuration.

[!WARNING]--reset-default does not restore custom static DNS addresses that existed before --set. The script does not maintain a configuration snapshot.

The global Mullvad DoH resolver registration is intentionally left in Windows. It is inactive when no adapter uses the Mullvad resolver IP addresses.

Back up the current DNS configuration

Before using --set, export the existing adapter DNS configuration if the computer uses custom static DNS servers:

Get-DnsClientServerAddress |
    Select-Object InterfaceAlias, InterfaceIndex, AddressFamily, ServerAddresses |
    Export-Clixml -Path '.\dns-config-before-mullvad.xml'

Display the saved configuration:

Import-Clixml -Path '.\dns-config-before-mullvad.xml' |
    Format-Table -AutoSize

The exported file is a reference record. The current script does not automatically import or restore it.

Targeted adapters

The script targets adapters returned by:

Get-NetAdapter -Physical

It then limits the result to these IANA interface types:

Interface type

Value

Ethernet

6

IEEE 802.11 Wi-Fi

71

Connected, disconnected, and disabled physical adapters can be included.

The script does not intentionally target virtual switches, VPN tunnels, loopback interfaces, or other non-physical adapters.

List the adapters that would be targeted:

Get-NetAdapter -Physical |
    Where-Object { ([uint32]$_.InterfaceType) -in @(6, 71) } |
    Sort-Object ifIndex |
    Format-Table Name, ifIndex, Status, InterfaceDescription -AutoSize

Active Directory safeguard

--set refuses to replace DNS settings when Win32_ComputerSystem.PartOfDomain is true.

Active Directory relies on internal DNS for domain controller discovery, Kerberos, Group Policy, service records, and domain name resolution. Replacing internal DNS with a public resolver would normally break domain functionality.

The safeguard does not apply to workgroup computers or Microsoft Entra ID-only joined devices unless they are also joined to an Active Directory domain.

Validation

Show configured adapter DNS servers

Get-DnsClientServerAddress |
    Where-Object {
        $_.ServerAddresses -contains '194.242.2.4' -or
        $_.ServerAddresses -contains '2a07:e340::4'
    } |
    Format-Table InterfaceAlias, InterfaceIndex, AddressFamily, ServerAddresses -AutoSize

Show the registered Mullvad DoH resolvers

Get-DnsClientDohServerAddress |
    Where-Object ServerAddress -in @('194.242.2.4', '2a07:e340::4') |
    Format-List ServerAddress, DohTemplate, AutoUpgrade, AllowFallbackToUdp

Expected values:

DohTemplate        : https://base.dns.mullvad.net/dns-query
AutoUpgrade        : True
AllowFallbackToUdp : False

Test DNS resolution

Resolve-DnsName -Name mullvad.net -Type A -DnsOnly -NoHostsFile

A successful result confirms name resolution. It does not by itself prove that a particular query used HTTPS; verify that the resolver registration shows AutoUpgrade = True and AllowFallbackToUdp = False.

Mullvad also provides a connection-check page:

https://mullvad.net/check

Browser DNS settings

Browsers can use their own Secure DNS or DoH provider instead of the Windows DNS client configuration.

Review browser-level DNS settings when you need all browser DNS queries to follow the operating-system configuration. In particular, check Firefox, Chrome, Edge, Brave, and other Chromium-based browsers for a custom Secure DNS provider.

Mullvad VPN interaction

Mullvad documents its public encrypted DNS service primarily for use when the Mullvad VPN is disconnected or cannot be used. When connected to Mullvad VPN, using the DNS resolver provided through the VPN tunnel is normally faster and already protected by the tunnel.

Failure behavior

Because fallback to unencrypted DNS is disabled, DNS resolution is expected to fail rather than silently use plaintext DNS when the configured Mullvad DoH resolver cannot be reached over HTTPS.

This is the secure behavior, but it can affect connectivity on:

Captive portals

Networks that block external DoH

Networks requiring an internal DNS resolver

Networks with broken IPv6 routing

Restricted enterprise or education networks

Use --reset-default to recover the adapter's automatic DNS configuration:

.\Set-MullvadBaseDns.ps1 --reset-default

Troubleshooting

The script requires elevation

Start PowerShell using Run as administrator. The script also declares:

#requires -RunAsAdministrator

Script execution is blocked

Inspect the effective execution policies:

Get-ExecutionPolicy -List

When the file was downloaded and is trusted, remove its Internet zone marker:

Unblock-File -Path '.\Set-MullvadBaseDns.ps1'

Do not weaken machine-wide execution policy solely to run this script.

Required DoH cmdlets are missing

Check the Windows version and available DnsClient commands:

Get-ComputerInfo | Select-Object WindowsProductName, WindowsVersion, OsBuildNumber
Get-Command -Module DnsClient | Sort-Object Name

The script cannot provide encrypted system-wide DNS without the Windows DoH client cmdlets.

DNS settings are correct, but websites do not resolve

Run these checks in order:

Get-DnsClientServerAddress
Get-DnsClientDohServerAddress
Test-NetConnection base.dns.mullvad.net -Port 443
Resolve-DnsName mullvad.net -DnsOnly -NoHostsFile

Interpretation:

Result

Meaning

Mullvad IPs are absent from the adapter

The adapter was not configured or was not targeted.

DoH registration is absent

The resolver registration failed or the OS lacks required support.

TCP port 443 test fails

The network, firewall, proxy, or upstream policy may block the resolver.

Port 443 works but DNS resolution fails

Inspect DoH registration, routing, IPv6 behavior, and Windows DNS client events.

Captive portal cannot open

Captive portals often require the network-provided DNS resolver before Internet access is granted.

Reset DNS temporarily:

.\Set-MullvadBaseDns.ps1 --reset-default

Complete the portal sign-in, then apply --set again.

Exit codes

Exit code

Meaning

0

Operation completed successfully.

1

A runtime, validation, adapter, or configuration error occurred.

64

Invalid command-line usage.

Example for automation:

& '.\Set-MullvadBaseDns.ps1' --set
if ($LASTEXITCODE -ne 0) {
    throw "Mullvad DNS configuration failed with exit code $LASTEXITCODE."
}

Security and operational notes

Review the script before running it with administrator privileges.

Test it on a non-production endpoint before broad deployment.

Do not deploy it to Active Directory domain members without redesigning the DNS approach.

Do not assume --reset-default restores an earlier static DNS configuration.

Account for browser-specific DoH settings and endpoint-management policies.

A firewall, proxy, VPN client, endpoint security agent, or Group Policy can override or block the expected behavior.

References

Mullvad encrypted DNS documentation: https://mullvad.net/en/help/dns-over-https-and-dns-over-tls

Microsoft DoH client documentation: https://learn.microsoft.com/windows-server/networking/dns/doh-client-support

Microsoft Set-DnsClientServerAddress documentation: https://learn.microsoft.com/powershell/module/dnsclient/set-dnsclientserveraddress

Microsoft Get-DnsClientDohServerAddress documentation: https://learn.microsoft.com/powershell/module/dnsclient/get-dnsclientdohserveraddress
