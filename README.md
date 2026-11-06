# bpom-tomcat-upgrade

GitHub Actions pipeline that upgrades the Apache Tomcat 10.1.x binary on BPOM servers
(dev, qa, qa2, staging, prod-ch, prod-ho = production DR), using the same server login flow
as `bpom-deploy.yml`. WAR deployment stays in `bpom-deploy.yml`.

Full setup guide: `BPOM_Tomcat_Upgrade_Repo_Setup_Guide.pdf`

## Layout

| Path | Purpose |
|---|---|
| `.github/workflows/tomcat-upgrade.yml` | The workflow (validate -> fetch/verify -> upgrade per host) |
| `.github/actions/autobahn-ssh/action.yml` | Vault -> ssh-agent -> signed certificate -> jump host login |
| `scripts/run-rollout.sh` | Orchestrates hosts, stops at first failure, auto rollback |
| `scripts/lib/ssh.sh` | `remote_run`, `remote_copy`, `remote_plain` over the Autobahn jump host |
| `scripts/remote/*.sh` | Scripts executed on the server as `mradmin` |
| `config/health/<role>.txt` | Endpoints checked after the switch |
| `config/preserve-paths.txt` | Extra files copied from the old install |

## Modes

`dry_run` (checks only) / `upgrade` / `rollback`; host scope `first` (canary) / `remaining` / `all`.

## Server layout required

`/app/platform/tomcat/tomcat` must be a symlink to `apache-tomcat-<version>`.
See Step 6.2 of the setup guide for the one-time migration.
