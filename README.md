# GitHub Actions Self-Hosted Runner Deployment

Deploy self-hosted GitHub Actions runners on Kubernetes (k3d) using the official Actions Runner Controller (ARC).

## Features

- Ubuntu 24.04 based runners matching GitHub-hosted `ubuntu-latest`
- Pre-installed: clang, gcc, gfortran (12/13/14), cmake, ninja, nodejs, npm
- Docker-in-Docker (DinD) support for container workflows
- Autoscaling from 0 to N runners based on workflow demand
- Optional caching proxies (apt, Docker registry, HTTP)
- Multi-machine horizontal scaling support

## Prerequisites

- Docker installed and running
- sudo access for deployment scripts
- GitHub App (recommended) or Personal Access Token (PAT)

## Authentication Setup

### Option 1: GitHub App (Recommended)

1. Create a GitHub App at:
   - **Organization**: `https://github.com/organizations/YOUR_ORG/settings/apps/new`
   - **Personal account**: `https://github.com/settings/apps/new`

2. Set permissions:
   - **Repository permissions**: Actions (Read), Metadata (Read)
   - **Organization permissions**: Self-hosted runners (Read & Write)
   - For repo-level only: Administration (Read & Write) instead

3. Generate and download a private key (PEM file)

4. Install the app on your organization or repositories

5. Note down:
   - App ID (from app settings)
   - Installation ID (from `https://github.com/settings/installations`)

### Option 2: Personal Access Token (PAT)

1. Create a PAT at `https://github.com/settings/tokens`
2. Select scopes:
   - `repo` (for repository runners)
   - `admin:org` (for organization runners)

## Configuration

```bash
cp config.env.example config.env
chmod 600 config.env
# Edit config.env with your values
```

### GitHub App Configuration

```bash
GITHUB_APP_ID=123456
GITHUB_APP_INSTALLATION_ID=789012
GITHUB_APP_PRIVATE_KEY_PATH=/path/to/private-key.pem
GITHUB_ORG=your-org
GITHUB_REPO=           # Empty for org-level, or specific repo name
```

### PAT Configuration

```bash
GITHUB_PAT=ghp_xxxxxxxxxxxx
GITHUB_ORG=your-org
GITHUB_REPO=           # Empty for org-level, or specific repo name
```

### Runner Settings

```bash
RUNNER_SCALE_SET_NAME=my-runners    # Name used in runs-on
MIN_RUNNERS=0                        # Scale to zero when idle
MAX_RUNNERS=32                       # Maximum concurrent runners
```

## Deploy

```bash
sudo ./setup.sh config.env
```

## Teardown

```bash
sudo ./teardown.sh
# Or with options:
sudo ./teardown.sh --keep-cluster    # Keep k3d, remove only ARC
sudo ./teardown.sh --keep-registry   # Keep local Docker registry
sudo ./teardown.sh --keep-user       # Keep github-runner user
```

## Usage in Workflows

```yaml
jobs:
  build:
    runs-on: my-runners  # Your RUNNER_SCALE_SET_NAME
    steps:
      - uses: actions/checkout@v4
      # Your build steps...
```

## Multi-Machine Scaling

Deploy on multiple machines to create a distributed runner pool:

```bash
# On each machine
git clone https://github.com/your-org/your-runners.git
cd your-runners
cp config.env.example config.env
# Edit config.env with same credentials
sudo ./setup.sh config.env
```

All machines register under the same runner name. GitHub automatically distributes jobs to any available runner for transparent horizontal scaling.

## Security Best Practices

- Store `config.env` outside the repository with `chmod 600`
- Private key files should have `chmod 600` permissions
- Rotate GitHub App private keys periodically
- Never commit `config.env`, `*.pem`, or `*.key` files (blocked by .gitignore)
- Prefer GitHub App over PAT (more granular permissions, auditable)

## Architecture

- **k3d**: Lightweight Kubernetes in Docker
- **ARC**: Official GitHub Actions Runner Controller
- **DinD**: Docker-in-Docker for container workflows
- **Local Registry**: Persistent runner image storage
- **Ephemeral runners**: Fresh runner pod per job
- **Autoscaling**: 0 to MAX_RUNNERS based on demand

## Customizing the Runner Image

Edit `runner-image/Dockerfile` to add tools your workflows need:

```dockerfile
RUN apt-get update && apt-get install -y \
    your-package \
    another-package
```

Rebuild and redeploy:

```bash
sudo ./teardown.sh --keep-user
sudo ./setup.sh config.env
```

## License

MIT License - see [LICENSE](LICENSE)
