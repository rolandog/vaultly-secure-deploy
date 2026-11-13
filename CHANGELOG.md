# Changelog

All notable changes are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Added
- Security workflow (`.github/workflows/security.yml`): gitleaks, checkov, yamllint, trivy, semgrep and pip-audit, with pinned tool versions.
- `scripts/ci-install-tools.sh`, `scripts/ci-soft.sh` and `scripts/ci-checkov.sh` so CI and local runs share one path.
- `redact-evidence.sh --learn`: appends gitleaks findings to the local redaction list.
- `infra/network/.checkov.yaml`: scans the VPC registry module, with one documented skip.

### Changed
- `up.sh` verify bypasses the local resolver cache (`curl --resolve`) and has connect timeouts.
- `update-admin-ip.sh` re-applies the Gateway so the ALB allow-list follows the admin IP.
- VPC flow-log group retention is 365 days (was 7).
