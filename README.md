# GitHub Actions Self-Hosted Runner Deployment

Deploy self-hosted GitHub Actions runners on Kubernetes (k3d) using the official Actions Runner Controller (ARC).

## Prerequisites

- Docker installed and running
- sudo access for deployment scripts
- GitHub App with runner registration permissions

## GitHub App Setup

1. Create a GitHub App in your organization settings
2. Set permissions:
   - **Repository permissions**: Actions (Read), Administration (Read & Write), Metadata (Read)
   - **Organization permissions**: Self-hosted runners (Read & Write)
3. Install the app on your organization or specific repositories
4. Download the private key PEM file

## Configuration

Copy the example config and edit:

```bash
cp config.env.example config.env
# Edit config.env with your values
```

Required settings:
- `GITHUB_APP_ID` - Your GitHub App ID
- `GITHUB_APP_INSTALLATION_ID` - Installation ID (found in app settings after install)
- `GITHUB_APP_PRIVATE_KEY_PATH` - Path to the downloaded PEM file
- `GITHUB_ORG` - Your GitHub organization or username

### Organization Level (recommended)

Runners available to all repos in the organization:

```bash
GITHUB_ORG=itpplasma
GITHUB_REPO=
```

GitHub App permissions needed:
- **Organization permissions**: Self-hosted runners (Read & Write)

### Repository Level

Runners available to a single repository only:

```bash
GITHUB_ORG=itpplasma
GITHUB_REPO=myrepo
```

GitHub App permissions needed:
- **Repository permissions**: Administration (Read & Write)

### Personal Account (User Level)

For personal GitHub accounts (not organizations):

```bash
GITHUB_ORG=yourusername
GITHUB_REPO=yourrepo
```

Note: Personal accounts require repository-level setup (specify `GITHUB_REPO`). Create the GitHub App under your personal account settings at Settings > Developer settings > GitHub Apps.

## Deploy

```bash
sudo ./setup.sh config.env
```

## Teardown

```bash
sudo ./teardown.sh
# Or with options:
sudo ./teardown.sh --keep-cluster  # Keep k3d, remove only ARC
sudo ./teardown.sh --keep-user     # Keep github-runner user
```

## Usage in Workflows

```yaml
jobs:
  build:
    runs-on: plasma-runners  # or your RUNNER_SCALE_SET_NAME
    steps:
      - uses: actions/checkout@v4
      # ...
```

## Multi-Machine Scaling

Deploy on multiple machines to create a global runner pool:

```bash
# On each machine
git clone git@github.com:itpplasma/github-runner-deploy.git
cd github-runner-deploy
cp config.env.example config.env
# Edit config.env with same GitHub App credentials
sudo ./setup.sh config.env
```

All machines register under `plasma-runners` - GitHub distributes jobs automatically to any available runner. Fully transparent horizontal scaling.

## Security Best Practices

- Store `config.env` outside the repository with `chmod 600`
- Private key files should have `chmod 600` permissions
- Rotate GitHub App private keys periodically
- Audit GitHub App installation permissions regularly
- Never commit `config.env`, `*.pem`, or `*.key` files (blocked by .gitignore)

## Architecture

- **k3d**: Lightweight Kubernetes in Docker
- **ARC**: Official GitHub Actions Runner Controller
- **DinD**: Docker-in-Docker enabled for container workflows
- **Ephemeral runners**: Each job gets a fresh runner pod
- **Autoscaling**: 0 to MAX_RUNNERS per machine based on workflow demand
