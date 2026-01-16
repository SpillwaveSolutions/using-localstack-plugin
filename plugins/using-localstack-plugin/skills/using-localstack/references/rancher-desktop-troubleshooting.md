# Rancher Desktop Troubleshooting

Comprehensive guide for running LocalStack on Rancher Desktop with containerd/nerdctl and Lima/WSL2 virtualization.

## Table of Contents
- [Architecture & Compatibility](#architecture--compatibility)
- [Container Runtime Selection](#container-runtime-selection)
- [Virtualization Backends](#virtualization-backends)
- [Socket Interface Issues](#socket-interface-issues)
- [Network Engineering](#network-engineering)
- [Storage & Filesystem](#storage--filesystem)
- [Lambda & Compute Emulation](#lambda--compute-emulation)
- [Troubleshooting Matrix](#troubleshooting-matrix)
- [Automation Scripts](#automation-scripts)

---

## Architecture & Compatibility

Rancher Desktop differs fundamentally from Docker Desktop in its architecture, using Lima (macOS/Linux) or WSL2 (Windows) for virtualization, and offering choice between containerd and dockerd (Moby) runtimes.

### Key Architectural Differences

| Layer | LocalStack Requirement | Rancher Desktop Default | Impact |
|-------|------------------------|-------------------------|--------|
| **Orchestration API** | Full Docker Engine API (v1.40+) via Unix Socket | containerd (no Docker API) or dockerd at non-standard paths | docker-py client fails to locate socket |
| **Networking** | Resolution of `localhost.localstack.cloud`; binding to 4566 | Namespaced networking; specific subnets (10.4.0.0/24); network tunnels | DNS rebind protection; subnet conflicts |
| **Storage** | High-performance volume mounts for persistence | QEMU (9p) or VirtioFS (macOS); WSL2 mounts | Permission denials (EACCES); slow I/O timeouts |

### Why These Differences Matter

**Docker Desktop Abstraction:**
- Hides Linux VM complexity behind seamless UI
- Standardized API socket at `/var/run/docker.sock`
- Hardcoded standard that thousands of tools rely on

**Rancher Desktop Flexibility:**
- Prioritizes Kubernetes (K3s) and runtime choice
- User-space socket paths to avoid root privileges
- Breaks "implicit contracts" that LocalStack relies upon

---

## Container Runtime Selection

**CRITICAL:** This is the single most common source of fatal errors for LocalStack users.

### Problem: "Cannot connect to the Docker daemon"

**Symptom:** LocalStack fails to start with error about missing Docker daemon, even though Rancher Desktop is running.

**Root Cause:** LocalStack is architected around the Docker Engine API. It uses Python's `docker` library to spawn Lambda containers, inspect networks, and mount volumes. Rancher Desktop defaults to containerd, which lacks this API.

### Solution: Switch to Moby (dockerd)

**Step 1: Open Rancher Desktop Preferences**
```
Preferences → Container Engine → Select "dockerd (moby)"
```

**Step 2: Restart Rancher Desktop**

**Step 3: Verify Engine**
```bash
docker version
# Should show both Client and Server versions

docker info | grep "Server Version"
# Should show Moby/Docker version
```

**Verification:**
```bash
# Should succeed
docker ps

# Should list the socket
ls -l ~/.rd/docker.sock
```

### Alternative: Experimental containerd Support

**Only use if constrained by policy.**

LocalStack can run with containerd using `nerdctl` commands internally:

```bash
DEBUG=1 DOCKER_CMD=nerdctl localstack start --network rancher
```

**Limitations:**
- Complex networking may not work correctly
- Volume mounting issues with Pro features
- Not recommended for production workflows

**Verify nerdctl:**
```bash
nerdctl version
nerdctl ps
```

---

## Virtualization Backends

The virtualization layer significantly impacts LocalStack's I/O performance and permission handling.

### macOS: QEMU vs VZ Performance

#### Problem: Slow Lambda Startup or Permission Errors

**Symptom:** Lambda functions timeout during initialization, or you see `Permission denied` errors on mounted volumes.

**Root Cause:** Legacy QEMU virtualization has significant I/O overhead when translating filesystem calls between macOS (APFS) and Linux (ext4).

#### Solution: Switch to VZ + VirtioFS

**VZ (Apple Virtualization Framework):** Near-native performance on Apple Silicon
**VirtioFS:** Shared filesystem via memory mapping (bypasses network protocols)

**Configuration:**

1. **Open Rancher Desktop Preferences**
2. **Virtual Machine → Emulation**
   - Set to: `VZ` (not QEMU)
3. **Virtual Machine → Volume Mount Type**
   - Set to: `virtiofs` (not reverse-sshfs or 9p)

**Verify Configuration:**
```bash
# Check Rancher settings
cat ~/Library/Application\ Support/rancher-desktop/settings.json | jq '.virtualMachine'

# Should show:
# {
#   "type": "vz",
#   "mountType": "virtiofs"
# }
```

**Test Performance:**
```bash
# Create test file in mounted volume
time touch volume/test.txt

# Should complete in < 100ms with VirtioFS
# QEMU/9p typically takes 500ms+
```

#### Performance Comparison

| Backend | Lambda Cold Start | Volume Write | File Event Propagation |
|---------|------------------|--------------|------------------------|
| QEMU + 9p | 5-10 seconds | 500ms | 2-5 seconds |
| VZ + VirtioFS | 1-2 seconds | 50ms | < 500ms |

### Windows: WSL2 Filesystem Performance

#### Problem: Slow LocalStack Startup from /mnt/c

**Symptom:** LocalStack takes 2-5 minutes to start when project is on C: drive.

**Root Cause:** Files on Windows drives accessed via `/mnt/c` incur severe 9P protocol translation penalty.

#### Solution: Use Native WSL2 Filesystem

**Relocate Project:**
```bash
# Inside WSL2 (not PowerShell)
cd ~
mkdir projects
cd projects
git clone <your-repo>
```

**Verify Location:**
```bash
pwd
# Should show: /home/username/projects/...
# NOT: /mnt/c/Users/...
```

**Performance Impact:**
```bash
# Benchmark I/O
dd if=/dev/zero of=test.dat bs=1M count=100 oflag=direct

# /mnt/c: ~50 MB/s
# /home:  ~500 MB/s (10x faster)
```

### Linux: No Virtualization Layer

**Advantage:** Direct kernel access, no VM overhead
**Consideration:** Ensure Docker socket permissions are correct (covered in next section)

---

## Socket Interface Issues

The most pervasive error: `Cannot connect to the Docker daemon at unix:///var/run/docker.sock`

### The Socket Mismatch Problem

**Standard Location:** `/var/run/docker.sock`  
**Rancher Location:** `~/.rd/docker.sock` or `/var/run/rancher-desktop-lima/docker.sock`

**Why This Breaks LocalStack:**
- LocalStack's Python `docker` library hardcodes check for `/var/run/docker.sock`
- When not found, assumes Docker daemon is down
- Rancher socket at different path is ignored

### Solution 1: Symlink (Recommended)

**macOS/Linux:**
```bash
# Remove stale socket if exists
sudo rm -f /var/run/docker.sock

# Locate Rancher socket
ls -l ~/.rd/docker.sock

# Create system-wide symlink
sudo ln -s ~/.rd/docker.sock /var/run/docker.sock

# Verify
ls -l /var/run/docker.sock
# Should show: /var/run/docker.sock -> /Users/<user>/.rd/docker.sock
```

**Why sudo?** `/var/run` is root-owned; creating symlink requires elevated privileges.

**Verify LocalStack can access:**
```bash
docker ps
# Should list containers

python3 -c "import docker; client = docker.from_env(); print(client.version())"
# Should print Docker version info
```

### Solution 2: Environment Variable Override

**Less reliable for LocalStack (docker-in-docker scenarios):**

```bash
export DOCKER_HOST=unix://$HOME/.rd/docker.sock

# Verify
docker ps
```

**For docker-compose:**
```yaml
environment:
  - DOCKER_HOST=unix:///home/user/.rd/docker.sock
volumes:
  - "/home/user/.rd/docker.sock:/var/run/docker.sock"
```

### Solution 3: Docker Context (CLI Only)

**Note:** This fixes CLI but not LocalStack's internal Python client.

```bash
# List contexts
docker context ls

# Should show rancher-desktop as active (*)
# NAME              DESCRIPTION
# default           Default context
# rancher-desktop*  Rancher Desktop context

# If not active, switch:
docker context use rancher-desktop
```

### Windows WSL2 Socket Configuration

**Rancher proxies Windows named pipe into WSL2 as Unix socket.**

**Verify WSL2 Integration:**
1. Open Rancher Desktop → Preferences → WSL
2. Ensure your distro (e.g., Ubuntu-22.04) is checked
3. Restart Rancher Desktop

**Check socket inside WSL2:**
```bash
# Inside WSL2 terminal
ls -l /var/run/docker.sock

# If missing, check:
ls -l ~/.rd/docker.sock
```

**Create symlink if needed:**
```bash
sudo ln -s ~/.rd/docker.sock /var/run/docker.sock
```

---

## Network Engineering

LocalStack's networking requirements create complex routing challenges on Rancher Desktop.

### Problem: Port 4566 Not Accessible

**Symptom:** `curl http://localhost:4566/_localstack/health` returns "Connection refused"

**Root Cause:** Port binding defaults to 127.0.0.1 (loopback only)

#### Solution: Bind to All Interfaces

**docker-compose.yml:**
```yaml
services:
  localstack:
    ports:
      - "0.0.0.0:4566:4566"  # Bind to all interfaces
```

**Security Warning:** This exposes LocalStack to your entire network. Anyone on the same Wi-Fi can invoke AWS commands against your emulator.

**Verify:**
```bash
# Check listening ports
netstat -an | grep 4566

# Should show:
# tcp4  0.0.0.0:4566  *.*  LISTEN

# Test from host
curl http://localhost:4566/_localstack/health | jq

# Test from another machine (replace with your IP)
curl http://192.168.1.100:4566/_localstack/health | jq
```

### Problem: DNS Resolution Failures for localhost.localstack.cloud

**Symptom:** `Could not resolve host: my-bucket.localhost.localstack.cloud`

**Root Cause:** DNS Rebind Protection on router blocks resolution to 127.0.0.1

#### Solution 1: Verify DNS Resolution

```bash
# Test DNS
nslookup localhost.localstack.cloud

# Should return:
# Server:    8.8.8.8
# Address:   8.8.8.8#53
# Name:      localhost.localstack.cloud
# Address:   127.0.0.1
```

**If it fails or times out:**

#### Solution 2: Router Whitelist

**Access router admin panel and whitelist:**
- Domain: `localhost.localstack.cloud`
- Allow resolution to private IP ranges

**Common routers:**
- pfSense: Services → DNS Resolver → General Settings → Disable DNS Rebind Protection
- OpenWRT: Network → DHCP and DNS → Rebind Protection → Add localhost.localstack.cloud to whitelist

#### Solution 3: /etc/hosts Override

**Bypass DNS entirely:**

```bash
# macOS/Linux
echo "127.0.0.1 localhost.localstack.cloud" | sudo tee -a /etc/hosts
echo "127.0.0.1 *.localhost.localstack.cloud" | sudo tee -a /etc/hosts

# Windows (PowerShell as Admin)
Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value "127.0.0.1 localhost.localstack.cloud"
```

**Verify:**
```bash
ping localhost.localstack.cloud
# Should show: 64 bytes from 127.0.0.1
```

### Problem: Subnet Conflicts with VPN

**Symptom:** `FATA[1] subnet 10.4.0.0/24 overlaps with other one on this address space`

**Root Cause:** Rancher creates network interface (rd0) with subnet 10.4.0.0/24, which conflicts with corporate VPN using 10.x.x.x range.

#### Solution 1: Immediate Workaround (Windows)

```powershell
# Shutdown WSL2 to reset networking
wsl --shutdown

# Restart Rancher Desktop
```

#### Solution 2: Permanent Fix

**Change Rancher's subnet CIDR:**

**macOS/Linux:**
```bash
# Edit Rancher settings
nano ~/Library/Application\ Support/rancher-desktop/settings.json

# Find and modify:
{
  "virtualMachine": {
    "networkingTunnel": true,
    "subnet": "192.168.155.0/24"  # Change from 10.4.0.0/24
  }
}
```

**Restart Rancher Desktop after change.**

**Verify:**
```bash
# Check network interfaces
ifconfig | grep rd0

# Should show new subnet range
```

### Problem: Container-to-Host Communication

**Symptom:** Lambda function inside LocalStack cannot connect to database running on host machine.

**Root Cause:** Inside container, `localhost` refers to container itself, not host.

#### Solution: Use host.docker.internal

**Test connectivity:**
```bash
# From within any container
docker run --rm busybox ping host.docker.internal

# Should succeed
```

**If it fails, add explicit mapping in docker-compose.yml:**
```yaml
services:
  localstack:
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

**Rancher-specific hostname:**
```yaml
extra_hosts:
  - "host.rancher-desktop.internal:host-gateway"
```

**Verify from LocalStack container:**
```bash
docker exec -it localstack-main ping host.docker.internal
# Should succeed
```

---

## Storage & Filesystem

Filesystem mounting is where virtualization abstractions leak most heavily.

### Problem: Permission Denied (EACCES) on Volume Mounts

**Symptom:** LocalStack crashes on startup with `Permission denied` writing to `/var/lib/localstack`

**Root Cause:** UID/GID mismatch between container (UID 1000) and host (UID 501 on macOS)

#### Solution 1: VirtioFS (macOS - Recommended)

**Already covered in Virtualization section.** VirtioFS transparently handles UID mapping.

**Verify:**
```bash
# Check mount type
cat ~/Library/Application\ Support/rancher-desktop/settings.json | jq '.virtualMachine.mountType'

# Should show: "virtiofs"
```

#### Solution 2: SELinux Context Labels (Linux)

**For RHEL/CentOS/Fedora:**

```yaml
volumes:
  - "./volume:/var/lib/localstack:z"  # Shared label
  # OR
  - "./volume:/var/lib/localstack:Z"  # Private label
```

**The `:z` flag:** Creates SELinux security context labels allowing container access.

**Verify:**
```bash
# Check SELinux context
ls -lZ ./volume

# Should show svirt_sandbox_file_t context
```

#### Solution 3: Explicit Permissions

**Last resort:**

```bash
# Give world-writable permissions (INSECURE)
chmod 777 ./volume

# Better: Match container UID
sudo chown -R 1000:1000 ./volume
```

### Problem: Hot Reload Latency

**Symptom:** Save code changes on host, invoke Lambda, old code executes.

**Root Cause:** File change events (inotify/fsevents) delayed through virtualization layers.

#### Solution: Optimize Mount Performance

**macOS: Use VirtioFS** (see Virtualization section)

**Windows: Use native WSL2 paths** (see Virtualization section)

**Linux: Use native mounts** (no VM layer)

**Test file event propagation:**
```bash
# Terminal 1: Watch for changes inside container
docker exec -it localstack-main sh -c 'while true; do stat /var/lib/localstack/test.txt 2>/dev/null; sleep 0.1; done'

# Terminal 2: Modify file on host
echo "test" > ./volume/test.txt

# Should see update within 500ms with VirtioFS
```

---

## Lambda & Compute Emulation

LocalStack spawns sibling containers for Lambda execution, requiring sophisticated networking.

### Problem: Lambda "Connection Refused" to S3/DynamoDB

**Symptom:** Lambda function crashes when calling AWS services (S3, DynamoDB, etc.)

**Root Cause:** Lambda container tries to connect to `localhost:4566`, which refers to itself, not LocalStack gateway.

#### Solution: Explicit Network Configuration

**docker-compose.yml:**
```yaml
services:
  localstack:
    environment:
      - LAMBDA_DOCKER_NETWORK=localstack-network
    networks:
      - localstack-network

networks:
  localstack-network:
    name: localstack-network
```

**This ensures:**
1. LocalStack container joins the network
2. All spawned Lambda containers join the same network
3. Lambda can resolve LocalStack by container name

**Verify network:**
```bash
docker network inspect localstack-network | jq '.[0].Containers'

# Should show localstack-main and any running Lambda containers
```

**Update Lambda environment variables:**
```bash
awslocal lambda update-function-configuration \
  --function-name my-function \
  --environment Variables="{
    AWS_ENDPOINT_URL=http://localstack:4566
  }"
```

**Test connectivity from Lambda:**
```python
# Lambda handler
import os
import boto3

s3 = boto3.client(
    's3',
    endpoint_url=os.environ.get('AWS_ENDPOINT_URL', 'http://localstack:4566')
)

def handler(event, context):
    # This should now work
    s3.list_buckets()
    return {'statusCode': 200}
```

### Problem: SSL Certificate Validation Errors

**Symptom:** Lambda fails with SSL certificate verification error when calling LocalStack.

**Root Cause:** LocalStack uses self-signed certificates; AWS SDKs inside Lambda reject them.

#### Solution 1: Disable SSL Validation (Development)

**Python (boto3):**
```python
import boto3
from botocore.client import Config

s3 = boto3.client(
    's3',
    endpoint_url='http://localstack:4566',
    config=Config(signature_version='s3v4'),
    verify=False  # Disable SSL verification
)
```

**Node.js:**
```javascript
process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
```

#### Solution 2: Use HTTP (If Production Parity Allows)

```yaml
environment:
  - USE_SSL=0
```

**Lambda environment:**
```bash
awslocal lambda update-function-configuration \
  --function-name my-function \
  --environment Variables="{
    AWS_ENDPOINT_URL=http://localstack:4566
  }"
```

---

## Troubleshooting Matrix

Comprehensive failure modes and remediations:

| Symptom | Root Cause | Rancher/LocalStack Fix | Priority |
|---------|-----------|------------------------|----------|
| **Daemon not found** | Socket path mismatch | Symlink socket: `sudo ln -s ~/.rd/docker.sock /var/run/docker.sock` | **CRITICAL** |
| **Connection Refused (4566)** | Port not exposed or tunnel blocked | Bind to 0.0.0.0; check firewall; disable Rancher tunnel | **HIGH** |
| **DNS Resolution Failure** | Router DNS Rebind Protection | Whitelist localhost.localstack.cloud or use /etc/hosts | **HIGH** |
| **Volume Permission Denied** | Virtualization UID mapping failure | macOS: Use VirtioFS; Linux: Use :z flag | **HIGH** |
| **Subnet Overlap** | IP CIDR conflict with VPN | `wsl --shutdown` or reconfigure Rancher subnet | **MEDIUM** |
| **Lambda Can't Reach S3** | Lambda localhost = container, not host | Set LAMBDA_DOCKER_NETWORK; use explicit network | **HIGH** |
| **Slow Lambda Startup** | QEMU I/O overhead | Switch to VZ + VirtioFS (macOS) | **MEDIUM** |
| **Hot Reload Delay** | File event propagation through VM | Use VirtioFS or native WSL2 paths | **LOW** |
| **Rate Limit Error** | Docker Hub anonymous pull limits | `docker login` to authenticate | **LOW** |
| **SSL Certificate Error** | Self-signed cert rejection | Disable SSL validation in SDK or USE_SSL=0 | **MEDIUM** |

---

## Automation Scripts

Ensure consistency across teams with mixed Docker Desktop and Rancher Desktop usage.

### Setup Script (macOS/Linux)

```bash
#!/bin/bash
# localstack-rancher-setup.sh

set -e

echo "==> LocalStack on Rancher Desktop Setup"

# 1. Check for Socket
if [ ! -S /var/run/docker.sock ]; then
    echo "Standard socket missing. Searching for Rancher socket..."
    
    RD_SOCK="$HOME/.rd/docker.sock"
    
    if [ -S "$RD_SOCK" ]; then
        echo "Found Rancher socket at $RD_SOCK"
        echo "Creating symlink (requires sudo)..."
        sudo ln -sf "$RD_SOCK" /var/run/docker.sock
        echo "✓ Socket symlink created"
    else
        echo "ERROR: No Docker socket found. Is Rancher Desktop running?"
        exit 1
    fi
else
    echo "✓ Docker socket found at /var/run/docker.sock"
fi

# 2. Verify Docker Connectivity
if docker ps > /dev/null 2>&1; then
    echo "✓ Docker connectivity verified"
else
    echo "ERROR: Cannot connect to Docker daemon"
    exit 1
fi

# 3. Check Container Engine
ENGINE=$(docker info --format '{{.ServerVersion}}')
if [[ "$ENGINE" == *"moby"* ]] || [[ "$ENGINE" == *"docker"* ]]; then
    echo "✓ Container engine: dockerd (moby)"
else
    echo "WARNING: Container engine may not be dockerd"
    echo "Please switch to dockerd in Rancher Desktop preferences"
fi

# 4. Check for host.docker.internal
if ! grep -q "host.docker.internal" /etc/hosts 2>/dev/null; then
    echo "WARNING: host.docker.internal not in /etc/hosts"
    echo "Lambda callbacks to host services may fail"
    echo "Add manually or use extra_hosts in docker-compose.yml"
fi

# 5. Check DNS Resolution
if nslookup localhost.localstack.cloud > /dev/null 2>&1; then
    echo "✓ DNS resolution for localhost.localstack.cloud works"
else
    echo "WARNING: localhost.localstack.cloud DNS resolution failed"
    echo "Adding to /etc/hosts..."
    echo "127.0.0.1 localhost.localstack.cloud" | sudo tee -a /etc/hosts
fi

# 6. Check Virtualization (macOS only)
if [[ "$OSTYPE" == "darwin"* ]]; then
    SETTINGS="$HOME/Library/Application Support/rancher-desktop/settings.json"
    if [ -f "$SETTINGS" ]; then
        VM_TYPE=$(jq -r '.virtualMachine.type' "$SETTINGS" 2>/dev/null)
        MOUNT_TYPE=$(jq -r '.virtualMachine.mountType' "$SETTINGS" 2>/dev/null)
        
        if [[ "$VM_TYPE" == "vz" ]] && [[ "$MOUNT_TYPE" == "virtiofs" ]]; then
            echo "✓ Virtualization: VZ + VirtioFS (optimal)"
        else
            echo "WARNING: Not using VZ + VirtioFS"
            echo "Current: VM=$VM_TYPE, Mount=$MOUNT_TYPE"
            echo "Recommend: VM=vz, Mount=virtiofs for best performance"
        fi
    fi
fi

echo ""
echo "==> Setup Complete!"
echo "You can now start LocalStack with: docker-compose up -d"
```

**Usage:**
```bash
chmod +x localstack-rancher-setup.sh
./localstack-rancher-setup.sh
```

### Windows WSL2 Setup Script

```powershell
# localstack-rancher-setup.ps1
# Run in PowerShell as Administrator

Write-Host "==> LocalStack on Rancher Desktop Setup (Windows)"

# Check if WSL2 is installed
$wslInstalled = wsl --status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: WSL2 not installed"
    exit 1
}

Write-Host "✓ WSL2 installed"

# Check Rancher Desktop is running
$rancherRunning = Get-Process -Name "Rancher Desktop" -ErrorAction SilentlyContinue
if ($null -eq $rancherRunning) {
    Write-Host "WARNING: Rancher Desktop may not be running"
}

# Add localhost.localstack.cloud to hosts file
$hostsPath = "C:\Windows\System32\drivers\etc\hosts"
$hostsContent = Get-Content $hostsPath -Raw

if ($hostsContent -notmatch "localhost.localstack.cloud") {
    Write-Host "Adding localhost.localstack.cloud to hosts file..."
    Add-Content -Path $hostsPath -Value "`n127.0.0.1 localhost.localstack.cloud"
    Write-Host "✓ DNS entry added"
} else {
    Write-Host "✓ localhost.localstack.cloud already in hosts file"
}

Write-Host ""
Write-Host "==> Setup Complete!"
Write-Host "Open WSL2 terminal and run: docker-compose up -d"
```

### Health Check Script

```bash
#!/bin/bash
# localstack-health.sh

echo "==> LocalStack Health Check"

# 1. Container Running
if docker ps --format '{{.Names}}' | grep -q localstack; then
    echo "✓ LocalStack container is running"
else
    echo "✗ LocalStack container not found"
    exit 1
fi

# 2. Port Reachable
if curl -s http://localhost:4566/_localstack/health > /dev/null; then
    echo "✓ Port 4566 is reachable"
else
    echo "✗ Port 4566 not reachable"
    exit 1
fi

# 3. Services Available
HEALTH=$(curl -s http://localhost:4566/_localstack/health)
echo ""
echo "Service Status:"
echo "$HEALTH" | jq -r '.services | to_entries[] | "\(.key): \(.value)"'

# 4. Network Connectivity
NETWORK=$(docker inspect localstack-main --format '{{range $net, $v := .NetworkSettings.Networks}}{{$net}}{{end}}')
echo ""
echo "Container Network: $NETWORK"

# 5. Volume Mounts
VOLUMES=$(docker inspect localstack-main --format '{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}')
echo "Volume Mounts: $VOLUMES"

echo ""
echo "==> Health Check Complete"
```

---

## Quick Reference Commands

### Diagnostics
```bash
# Check socket location
ls -l /var/run/docker.sock
ls -l ~/.rd/docker.sock

# Verify Docker engine
docker version
docker info | grep "Server Version"

# Test DNS
nslookup localhost.localstack.cloud
ping localhost.localstack.cloud

# Check network interfaces
ifconfig | grep rd0
ip addr show rd0  # Linux

# Test port binding
netstat -an | grep 4566
lsof -i :4566
```

### Container Operations
```bash
# List containers
docker ps -a

# Inspect LocalStack container
docker inspect localstack-main

# Check logs
docker logs -f localstack-main

# Enter container
docker exec -it localstack-main bash

# Test connectivity from container
docker exec -it localstack-main curl http://localhost:4566/_localstack/health
```

### Network Debugging
```bash
# Inspect network
docker network ls
docker network inspect localstack-network

# Test container-to-host
docker run --rm busybox ping host.docker.internal

# Test Lambda network
docker exec -it <lambda-container-id> ping localstack
```

### Cleanup
```bash
# Stop LocalStack
docker-compose down

# Remove volumes
docker-compose down -v

# Clean up networks
docker network prune

# Reset Rancher networking (Windows)
wsl --shutdown
```

---

## Best Practices Summary

### Required Configuration Checklist

✅ **Container Runtime:** Set to dockerd (moby), not containerd  
✅ **Socket Symlink:** Link `~/.rd/docker.sock` to `/var/run/docker.sock`  
✅ **Virtualization (macOS):** Use VZ + VirtioFS for performance  
✅ **Filesystem (Windows):** Use native WSL2 paths, not /mnt/c  
✅ **Networking:** Define explicit Docker network in compose file  
✅ **DNS:** Whitelist localhost.localstack.cloud or add to /etc/hosts  
✅ **Port Binding:** Use 0.0.0.0:4566:4566 for network access  
✅ **Lambda Network:** Set LAMBDA_DOCKER_NETWORK environment variable  

### Performance Optimization

- **macOS:** VZ + VirtioFS (10x faster than QEMU + 9p)
- **Windows:** Native WSL2 filesystem (10x faster than /mnt/c)
- **Linux:** Native Docker (no VM overhead)
- **Memory:** Allocate 4GB+ to Rancher VM
- **CPU:** Allocate 2+ cores to Rancher VM

### Security Considerations

- **Port Exposure:** Binding to 0.0.0.0 exposes LocalStack to network
- **Socket Permissions:** Symlinking requires sudo (elevated privileges)
- **SSL Validation:** Disabling in Lambda should only be for development
- **VPN Conflicts:** Use non-overlapping subnets (avoid 10.x.x.x)

---

## Comparison: Docker Desktop vs Rancher Desktop

| Feature | Docker Desktop | Rancher Desktop | Winner |
|---------|---------------|-----------------|--------|
| **Setup Complexity** | Zero-config | Requires socket symlink & runtime selection | Docker |
| **License** | Commercial (paid for teams) | Open-source (free) | Rancher |
| **Kubernetes** | Optional | Built-in (K3s) | Rancher |
| **Container Runtime** | dockerd only | dockerd or containerd (choice) | Rancher |
| **Performance (macOS)** | Good | Excellent (with VZ + VirtioFS) | Rancher |
| **LocalStack Compatibility** | Excellent (zero config) | Good (requires setup) | Docker |
| **Open Source** | No | Yes | Rancher |

### Recommendation

**Use Docker Desktop if:**
- You want zero-config LocalStack setup
- You don't need Kubernetes
- You have commercial license budget

**Use Rancher Desktop if:**
- You need open-source solution
- You want Kubernetes integration
- You're willing to invest setup time for long-term benefits
- You want maximum performance on Apple Silicon

---

## Conclusion

Running LocalStack on Rancher Desktop is **viable and enterprise-grade** when architectural differences are understood and managed. Success depends on three pillars:

1. **Standardization:** Use dockerd (Moby) runtime, not containerd
2. **Normalization:** Socket symlinks and explicit port bindings
3. **Optimization:** VirtioFS (macOS) or native WSL2 paths (Windows)

While initial setup is steeper than Docker Desktop, the resulting environment offers:
- **Transparency:** Open-source stack
- **Performance:** Near-native with VZ + VirtioFS
- **Kubernetes:** Built-in K3s for container orchestration
- **Cost:** No commercial licensing

Treat your local environment with the same rigor as production deployments—explicitly define networks, volumes, and security contexts—and Rancher Desktop becomes a powerful foundation for cloud-native local development.
