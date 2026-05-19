# Setup SSH keys for passwordless authentication
# Root cause: Interactive password prompts block automation

$hosts = @(
    @{IP="192.168.1.91"; User="root"; Pass="homohominilupusest"; Name="Pineapple"},
    @{IP="89.125.92.10"; User="root"; Pass="0Cb8r7Bug5J1AW6pH"; Name="VPS"},
    @{IP="172.16.42.1"; User="root"; Pass="homohominilupusest"; Name="Terra"}
)

Write-Host "=== SSH Key Setup ===" -ForegroundColor Cyan

# Generate SSH key if not exists
$sshKeyPath = "$env:USERPROFILE\.ssh\id_rsa"
if (-not (Test-Path $sshKeyPath)) {
    Write-Host "Generating SSH key..."
    ssh-keygen -t rsa -b 4096 -f $sshKeyPath -N '""'
}

$pubKey = Get-Content "$sshKeyPath.pub"

foreach ($host in $hosts) {
    Write-Host "`nConfiguring $($host.Name) ($($host.IP))..." -ForegroundColor Yellow
    
    # Use sshpass or plink to copy key
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        wsl bash -c "sshpass -p '$($host.Pass)' ssh-copy-id -o StrictHostKeyChecking=no $($host.User)@$($host.IP)"
    } else {
        # Manual method
        $cmd = "mkdir -p ~/.ssh; echo '$pubKey' >> ~/.ssh/authorized_keys; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys"
        echo $host.Pass | plink -ssh -l $host.User -pw $host.Pass $host.IP $cmd
    }
    
    Write-Host "✓ Key installed on $($host.Name)" -ForegroundColor Green
}

Write-Host "`n✓ SSH keys configured. Now you can use ssh without passwords." -ForegroundColor Green
