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
   - For repo-level deployments, use Administration (Read & Write) instead of organization permissions

3. Generate and download a private key (PEM file)

4. Install the app on your organization or repositories

5. Note down:
   - App ID (from app settings)
   - Installation ID (from `https://github.com/settings/installations`)

### Option 2: Personal Access Token (PAT)

1. Create a classic PAT at `https://github.com/settings/tokens`
2. Select scopes:
   - `repo` (for repository-level runners)
   - `admin:org` (for organization-level runners)

## Configuration

Create your configuration file from the example:

```bash
cp config.env.example config.env
chmod 600 config.env
```

Edit `config.env` with your authentication credentials and runner settings. Choose either GitHub App or PAT authentication.

### GitHub App Configuration

```bash
GITHUB_APP_ID=123456
GITHUB_APP_INSTALLATION_ID=789012
GITHUB_APP_PRIVATE_KEY_PATH=/path/to/private-key.pem
GITHUB_ORG=your-org
GITHUB_REPO=           # Leave empty for org-level runners, or specify repo name
```

### PAT Configuration

```bash
GITHUB_PAT=ghp_xxxxxxxxxxxx
GITHUB_ORG=your-org
GITHUB_REPO=           # Leave empty for org-level runners, or specify repo name
```

### Runner Settings

```bash
RUNNER_SCALE_SET_NAME=my-runners    # Name used in runs-on
MIN_RUNNERS=0                        # Scale to zero when idle
MAX_RUNNERS=32                       # Maximum concurrent runners
```

## Deploy

Run the setup script with your configuration:

```bash
sudo ./setup.sh config.env
```

The script will:
- Create a k3d Kubernetes cluster
- Deploy the Actions Runner Controller
- Build and push the runner image
- Configure autoscaling based on your MIN_RUNNERS and MAX_RUNNERS settings

Deployment takes approximately 2-3 minutes. Once complete, runners will appear in your GitHub repository or organization settings under Actions > Runners.

### Verifying Deployment

Check that your runners are registered and ready:

1. Navigate to your GitHub organization or repository settings
2. Go to Actions > Runners
3. Look for your RUNNER_SCALE_SET_NAME in the list
4. The runner should show as idle and ready to accept jobs

You can also verify the Kubernetes deployment:
```bash
kubectl --context k3d-arc-cluster -n arc-runners get pods
kubectl --context k3d-arc-cluster -n arc-runners get scalesets
```

## Teardown

Remove all deployed components:

```bash
sudo ./teardown.sh
```

Available options for partial cleanup:
```bash
sudo ./teardown.sh --keep-cluster    # Keep k3d cluster, remove only ARC
sudo ./teardown.sh --keep-registry   # Keep local Docker registry
sudo ./teardown.sh --keep-user       # Keep github-runner user account
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

Deploy on multiple machines to create a distributed runner pool. Each machine runs an independent k3d cluster, but all register under the same scale set name.

```bash
# On each machine
git clone <this-repository-url>
cd github-runner-deploy
cp config.env.example config.env
# Edit config.env with identical credentials and RUNNER_SCALE_SET_NAME
sudo ./setup.sh config.env
```

All machines register under the same scale set name. GitHub automatically distributes jobs across all available runners, providing transparent horizontal scaling and redundancy.

## Security Best Practices

- Store `config.env` outside the repository with `chmod 600` permissions
- Set private key files to `chmod 600` to restrict access
- Rotate GitHub App private keys periodically
- Never commit `config.env`, `*.pem`, or `*.key` files to version control
- Use GitHub App authentication over PAT when possible for more granular permissions and better auditability
- Review runner logs periodically for suspicious activity
- Limit runner access to only the repositories that need them

## Architecture

This deployment uses the following components:

- **k3d**: Lightweight Kubernetes cluster running in Docker
- **ARC**: Official GitHub Actions Runner Controller for Kubernetes
- **DinD**: Docker-in-Docker support for container-based workflows
- **Local Registry**: Persistent storage for runner container images
- **Ephemeral runners**: Fresh, isolated runner pod created for each job
- **Autoscaling**: Dynamic scaling from 0 to MAX_RUNNERS based on workflow demand

## Customizing the Runner Image

To add additional tools or dependencies for your workflows, edit `runner-image/Dockerfile`:

```dockerfile
RUN apt-get update && apt-get install -y \
    your-package \
    another-package
```

After modifying the Dockerfile, rebuild and redeploy:

```bash
sudo ./teardown.sh --keep-user
sudo ./setup.sh config.env
```

The runner image will be rebuilt with your changes and pushed to the local registry.

## Troubleshooting

### Runners not appearing in GitHub

- Verify your GitHub App or PAT has the correct permissions
- Check that the private key file path is correct and the file has `chmod 600` permissions
- Ensure the GitHub App is installed on the target organization or repository
- Review logs: `kubectl --context k3d-arc-cluster -n arc-runners logs -l app.kubernetes.io/name=gha-runner-scale-set-controller`

### Workflows not using self-hosted runners

- Confirm the `runs-on` value in your workflow matches RUNNER_SCALE_SET_NAME exactly
- Check that runners show as idle in GitHub settings under Actions > Runners
- Verify the runner scale set is registered: `kubectl --context k3d-arc-cluster -n arc-runners get scalesets`

### Permission errors during deployment

- Ensure you are running setup.sh with `sudo`
- Verify Docker is installed and the Docker daemon is running
- Check that your user can run Docker commands: `docker ps`

### Pods failing to start

- Check pod status: `kubectl --context k3d-arc-cluster -n arc-runners get pods`
- View pod logs: `kubectl --context k3d-arc-cluster -n arc-runners logs <pod-name>`
- Ensure sufficient system resources are available (CPU, memory, disk space)

## License

MIT License - see [LICENSE](LICENSE)
