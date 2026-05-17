# start-tunnel-dev.ps1
# Open an SSH tunnel from this Windows laptop to the dev MicroK8s cluster
# and merge the cluster's kubeconfig into $env:USERPROFILE\.kube\config
# under context `dev`.
#
# After this script is running:
#   kubectl config use-context dev
#   kubectl get nodes
#
# Press Ctrl+C to close the tunnel. The merged kubeconfig stays so you can
# re-tunnel later without re-fetching.
#
# Requires: pwsh 7+, OpenSSH client (built into Win10+), kubectl on PATH.

$ErrorActionPreference = 'Stop'

# --- Dev cluster ---
$DevHost          = 'server.dev.digitaplatform.com'
$DevUser          = 'server'
$DevK8sLocalPort  = 16443
$DevK8sRemotePort = 16443

# --- Kubeconfig ---
$KubeDir       = Join-Path $env:USERPROFILE '.kube'
$KubeConfig    = Join-Path $KubeDir 'config'
$KubeConfigDev = Join-Path $KubeDir 'config-dev'

# State
$Script:SshProcess = $null
$Script:TmpConfig  = $null

function Cleanup {
    Write-Host ''
    Write-Host 'Shutting down tunnel...'
    if ($Script:SshProcess -and -not $Script:SshProcess.HasExited) {
        try {
            Stop-Process -Id $Script:SshProcess.Id -Force -ErrorAction SilentlyContinue
            Write-Host "   Dev tunnel (PID $($Script:SshProcess.Id)) stopped" -ForegroundColor Green
        } catch { }
    }
    if ($Script:TmpConfig -and (Test-Path $Script:TmpConfig)) {
        Remove-Item -Force -ErrorAction SilentlyContinue $Script:TmpConfig
    }
    Write-Host 'Tunnel closed.'
}

# Ctrl+C handler — pwsh raises a [Console]::CancelKeyPress event we hook.
[Console]::TreatControlCAsInput = $false
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -SupportEvent -Action { Cleanup }
trap { Cleanup; exit 1 }

function Clear-Port {
    param([int]$Port, [string]$PortName)
    Write-Host "   Checking port $Port ($PortName)..."
    $conn = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
            Where-Object State -eq Listen
    if ($conn) {
        $procId = $conn.OwningProcess | Select-Object -First 1
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        $procName = if ($proc) { $proc.ProcessName } else { 'unknown' }
        Write-Host "   Found existing process: $procName (PID $procId)" -ForegroundColor Yellow
        Write-Host '   Killing process...' -ForegroundColor Red
        try { Stop-Process -Id $procId -Force -ErrorAction Stop } catch { }
        Start-Sleep -Seconds 1
        Write-Host "   Port $Port is now free" -ForegroundColor Green
    } else {
        Write-Host "   Port $Port is available" -ForegroundColor Green
    }
}

# Rewrite the raw `microk8s config` output so the local kubectl talks to
# the SSH tunnel and the context has a sane name. Done via kubectl itself
# (no regex) — kubectl knows YAML, can rename contexts cleanly, and is
# immune to CRLF / encoding quirks that bit earlier regex versions.
function Rewrite-Kubeconfig {
    param(
        [string]$RawConfig,
        [int]$LocalPort,
        [int]$RemotePort,
        [string]$ContextName,
        [string]$OutPath
    )
    # 1. Save raw to a working file. UTF8 no-BOM avoids kubectl YAML parse
    #    errors on Windows that has historically defaulted to UTF8-BOM.
    [System.IO.File]::WriteAllText($OutPath, $RawConfig, [System.Text.UTF8Encoding]::new($false))

    # 2. Discover what names microk8s used. Recent versions use
    #    context=microk8s, cluster=microk8s-cluster, user=admin — but
    #    parsing is cheap insurance against future drift.
    $origCtx     = (& kubectl --kubeconfig $OutPath config current-context).Trim()
    $origCluster = (& kubectl --kubeconfig $OutPath config view --raw -o jsonpath="{.contexts[?(@.name==`"$origCtx`")].context.cluster}").Trim()

    # 3. Rename the context to $ContextName. kubectl handles cluster +
    #    user references inside the context automatically.
    if ($origCtx -ne $ContextName) {
        & kubectl --kubeconfig $OutPath config rename-context $origCtx $ContextName | Out-Null
    }

    # 4. Point the cluster at the local tunnel + skip-TLS (the remote cert
    #    isn't valid for `localhost`). set-cluster drops CA data when
    #    --insecure-skip-tls-verify is set.
    & kubectl --kubeconfig $OutPath config set-cluster $origCluster `
        --server="https://localhost:$LocalPort" `
        --insecure-skip-tls-verify=true | Out-Null
}

# Step 1: free the local port
Write-Host ''
Write-Host 'Checking and clearing required port...'
Clear-Port -Port $DevK8sLocalPort -PortName 'Kubernetes API (dev)'

# Step 2: SSH reachability
Write-Host ''
Write-Host 'Testing SSH connectivity to DEV cluster...'
$sshTest = & ssh -o ConnectTimeout=10 -o BatchMode=yes "$DevUser@$DevHost" 'echo Connected' 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host 'SSH connection to DEV failed.' -ForegroundColor Red
    Write-Host 'Try:' -ForegroundColor Yellow
    Write-Host "   ssh-add -l"
    Write-Host "   ssh $DevUser@$DevHost"
    Write-Host "   ssh-keyscan $DevHost | Out-File -Append $env:USERPROFILE\.ssh\known_hosts"
    exit 1
}
Write-Host 'DEV SSH connection successful' -ForegroundColor Green

# Step 3: ensure .kube exists
if (-not (Test-Path $KubeDir)) {
    Write-Host ''
    Write-Host "Creating .kube directory at $KubeDir..."
    New-Item -ItemType Directory -Path $KubeDir | Out-Null
}

# Step 4: fetch kubeconfig from DEV MicroK8s
Write-Host ''
Write-Host 'Fetching kubeconfig from DEV MicroK8s...'
$RawDevConfig = & ssh "$DevUser@$DevHost" 'microk8s config' 2>&1 | Out-String
if ([string]::IsNullOrWhiteSpace($RawDevConfig)) {
    Write-Host 'Failed to retrieve DEV kubeconfig.' -ForegroundColor Red
    exit 1
}
Write-Host '   DEV kubeconfig retrieved' -ForegroundColor Green

# Step 5: rewrite raw config for localhost tunnel using kubectl
Write-Host ''
Write-Host 'Processing DEV kubeconfig...'
$Script:TmpConfig = [System.IO.Path]::GetTempFileName()
Rewrite-Kubeconfig -RawConfig $RawDevConfig -LocalPort $DevK8sLocalPort -RemotePort $DevK8sRemotePort -ContextName 'dev' -OutPath $Script:TmpConfig
Write-Host "   Server -> https://localhost:$DevK8sLocalPort, context -> dev" -ForegroundColor Green

# Step 6: merge into ~/.kube/config and write the per-context file
Write-Host ''
Write-Host 'Merging kubeconfig...'

if (Test-Path $KubeConfig) {
    # KUBECONFIG path separator is OS-specific: ';' on Windows, ':' on Linux/macOS.
    # ([System.IO.Path]::PathSeparator returns the right char on the current OS.)
    $sep = [System.IO.Path]::PathSeparator
    $env:KUBECONFIG = "${KubeConfig}${sep}${Script:TmpConfig}"
    $merged = & kubectl config view --flatten 2>&1
    $mergeExit = $LASTEXITCODE
    Remove-Item Env:\KUBECONFIG
    if ($mergeExit -ne 0 -or [string]::IsNullOrWhiteSpace($merged)) {
        Write-Host "kubectl config view --flatten failed (exit $mergeExit):" -ForegroundColor Red
        Write-Host $merged
        Write-Host "Existing $KubeConfig may be corrupt. Delete it and re-run." -ForegroundColor Yellow
        exit 1
    }
    Set-Content -Path $KubeConfig -Value $merged
} else {
    Copy-Item -Path $Script:TmpConfig -Destination $KubeConfig
}
Write-Host "Merged kubeconfig saved to $KubeConfig" -ForegroundColor Green

# Per-context standalone file (use with $env:KUBECONFIG=... in another shell).
Copy-Item -Path $KubeConfig -Destination $KubeConfigDev -Force
$env:KUBECONFIG = $KubeConfigDev
& kubectl config use-context dev | Out-Null
Remove-Item Env:\KUBECONFIG
Write-Host "   $KubeConfigDev (current-context: dev)" -ForegroundColor Green

# Step 7: start tunnel
Write-Host ''
Write-Host 'Starting DEV SSH tunnel...'
$sshArgs = @(
    '-N',
    '-L', "${DevK8sLocalPort}:localhost:${DevK8sRemotePort}",
    "$DevUser@$DevHost"
)
$Script:SshProcess = Start-Process -FilePath ssh -ArgumentList $sshArgs -NoNewWindow -PassThru
Write-Host "   Kubernetes API:  localhost:$DevK8sLocalPort -> ${DevHost}:$DevK8sRemotePort" -ForegroundColor Cyan
Write-Host "   Dev tunnel started (PID $($Script:SshProcess.Id))" -ForegroundColor Green

Write-Host ''
Write-Host ('=' * 60)
Write-Host 'DEV tunnel running.' -ForegroundColor Green
Write-Host ('=' * 60)
Write-Host ''
Write-Host 'Use kubectl:' -ForegroundColor Yellow
Write-Host '   kubectl config use-context dev'
Write-Host '   kubectl get nodes'
Write-Host ''
Write-Host 'Or in a separate shell:' -ForegroundColor Yellow
Write-Host "   `$env:KUBECONFIG = '$KubeConfigDev'"
Write-Host '   kubectl get nodes'
Write-Host ''
Write-Host 'Press Ctrl+C to close the tunnel.'
Write-Host ''

# Block until the SSH process exits (or Ctrl+C — handled by trap).
$Script:SshProcess.WaitForExit()
Cleanup
