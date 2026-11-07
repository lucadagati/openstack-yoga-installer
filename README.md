# OpenStack Yoga Automated Installer

A Bash installer that deploys an **all-in-one OpenStack Yoga controller node** (Keystone, Glance, Placement, Nova, Neutron, Horizon) on a single Ubuntu 20.04 LTS machine, driven by environment variables and pre-edited configuration templates.

## Table of contents

1. [What it is and why it exists](#1-what-it-is-and-why-it-exists)
2. [Architecture](#2-architecture)
3. [Requirements](#3-requirements)
4. [Installation](#4-installation)
5. [Configuration](#5-configuration)
6. [Usage and expected output](#6-usage-and-expected-output)
7. [Repository layout](#7-repository-layout)
8. [Testing and verification](#8-testing-and-verification)
9. [Troubleshooting](#9-troubleshooting)
10. [Limitations and security notes](#10-limitations-and-security-notes)
11. [Extending and customising](#11-extending-and-customising)
12. [Changes](#12-changes)

## 1. What it is and why it exists

Following the official install guide by hand is long and error-prone. `Yoga_Installation.sh` automates the single-node variant: it installs the Yoga packages from the Ubuntu Cloud Archive, copies and customises the service templates in `conf_files/`, creates databases, users, services and endpoints, and runs the database syncs. It is written with `set -euo pipefail`, logs to a file and creates OpenStack resources only if they do not already exist (users, services, endpoints, project, image). It targets labs and proofs of concept, not HA production.

## 2. Architecture

```
                 Ubuntu 20.04 host  (name: $CONTROLLER_HOST, IP: $CONTROLLER_IP)
 +-------------------------------------------------------------------+
 | MariaDB   RabbitMQ (user "openstack")   memcached   chrony        |
 | Keystone :5000   Glance :9292   Placement :8778 (Apache)          |
 | Nova API :8774, scheduler, conductor, novncproxy :6080, compute   |
 | Neutron :9696  (ML2, linuxbridge, L3, DHCP, metadata agents)      |
 | Horizon (Apache)                                                  |
 +-------------------------------------------------------------------+
   Swift templates exist in conf_files/ but are NOT used by the script.
```

Execution order (`main`): root check, prerequisites, input validation, `/etc/hosts` entry, packages, optional MariaDB reset, MariaDB hardening, base services (chrony, RabbitMQ, memcached), Keystone, Glance, Cirros upload, Placement, Nova, Neutron, Horizon, post-checks.

## 3. Requirements

- Ubuntu 20.04 LTS (Focal), fresh machine or VM recommended; root access; Internet access (Ubuntu archives, `cloud-archive:yoga`, `download.cirros-cloud.net`).
- Commands needed up front: `apt`, `add-apt-repository`, `systemctl`, `ip`, `awk`, `sed`. A default route is needed (IP and NIC auto-detection).
- Sizing is not specified by the repository (not verified); an all-in-one OpenStack node typically needs several GB of RAM and tens of GB of disk.

Not verified in this environment: an actual run on Ubuntu 20.04 (it was deliberately not executed because it modifies the system).

## 4. Installation

```bash
git clone https://github.com/lucadagati/openstack-yoga-installer.git
cd openstack-yoga-installer
chmod +x Yoga_Installation.sh
sudo ./Yoga_Installation.sh
```

The script resolves `conf_files/` relative to its own location, so it can be started from any directory. With strong secrets (recommended):

```bash
sudo \
  MARIADB_ROOT_PASSWORD='change-me' ADMIN_PASS='change-me' RABBIT_PASS='change-me' \
  METADATA_SECRET='change-me' KEYSTONE_DBPASS='change-me' GLANCE_DBPASS='change-me' \
  PLACEMENT_DBPASS='change-me' NOVA_DBPASS='change-me' NEUTRON_DBPASS='change-me' \
  GLANCE_PASS='change-me' PLACEMENT_PASS='change-me' NOVA_PASS='change-me' NEUTRON_PASS='change-me' \
  ./Yoga_Installation.sh
```

Use passwords without `/`, `&`, quotes or shell/SQL special characters: `/` and `&` are escaped for `sed`, but quotes would break the SQL statements (not tested).

## 5. Configuration

All options are environment variables read at the top of the script.

| Variable | Default | Meaning |
|---|---|---|
| `CONTROLLER_HOST` | `controller` | Host name written to `/etc/hosts` and used in all URLs and templates |
| `CONTROLLER_IP` | auto: `ip route get 8.8.8.8`, field 7 | Host IP (`/etc/hosts`, memcached `-l`, nova `my_ip`, neutron `local_ip`) |
| `PROVIDER_INTERFACE` | auto: field 5 of the same command | NIC used for `physical_interface_mappings = provider:<nic>` |
| `REGION` | `RegionOne` | Region for Keystone bootstrap and endpoints |
| `RESET_MARIADB_DATA` | `0` | `1` stops MariaDB, **deletes `/var/lib/mysql/*`** and re-initialises it |
| `DOWNLOAD_CIRROS` | `1` | `0` skips downloading/uploading the CirrOS 0.4.0 image (uploaded as `cirros`) |
| `MARIADB_ROOT_PASSWORD` | `password` | MariaDB root password |
| `RABBIT_PASS` | `RABBIT_PASS` | Password of the RabbitMQ user `openstack` |
| `ADMIN_PASS` | `ADMIN_PASS` | Keystone `admin` password (also written to `admin-openrc`) |
| `METADATA_SECRET` | `METADATA_SECRET` | Neutron metadata shared secret |
| `KEYSTONE_DBPASS`, `GLANCE_DBPASS`, `PLACEMENT_DBPASS`, `NOVA_DBPASS`, `NEUTRON_DBPASS` | same as the name | Database user passwords (databases: keystone, glance, placement, nova_api, nova, nova_cell0, neutron) |
| `GLANCE_PASS`, `PLACEMENT_PASS`, `NOVA_PASS`, `NEUTRON_PASS` | same as the name | Keystone service-user passwords |
| `SWIFT_PASS` | `SWIFT_PASS` | Reserved: only substituted into templates; no Swift user is created |
| `DEBIAN_FRONTEND` | `noninteractive` | Passed to apt |

How templates are customised: each file in `conf_files/` is copied with `install -m 0644` and the placeholder tokens (`controller`, `RABBIT_PASS`, `*_DBPASS`, `*_PASS`, `ADMIN_PASS`, `METADATA_SECRET`) are substituted by `replace_token`. Note that the token `controller` is replaced everywhere in a template, so keep it only as the host name in your own edits. Then targeted `sed` edits set `my_ip`, `novncproxy_base_url`, `physical_interface_mappings`, `local_ip`, `nova_metadata_host`, `OPENSTACK_HOST` and the memcached `LOCATION`.

Fixed values: log file `/var/log/openstack-yoga-installer.log`; credentials file `<repo>/admin-openrc` (mode 0600, generated, git-ignored); `nova-compute.conf` template uses `virt_type=qemu`.

## 6. Usage and expected output

The script prints timestamped lines (`[YYYY-MM-DD HH:MM:SS] [INFO|RUN|WARN|ERROR] message`) to the terminal and the log file, ending with `OpenStack Yoga automated installation completed.` Then `post_checks` runs `openstack service list`, `endpoint list`, `compute service list`, `network agent list` and `image list`. Default passwords trigger `WARN` lines. Actual outputs were not observed here.

```bash
source admin-openrc
openstack service list        # keystone, glance, placement, nova, neutron
openstack image list          # cirros (unless DOWNLOAD_CIRROS=0)
openstack network agent list  # linuxbridge, L3, DHCP, metadata agents
```

No provider network, flavor, keypair or security-group rules are created; do that before booting instances. Horizon is configured through `openstack-dashboard.conf` and served by Apache (usually under `/horizon`; not checked live).

## 7. Repository layout

```
Yoga_Installation.sh   installer (functions per service, idempotent helpers ensure_os_user/service/endpoint)
conf_files/            templates: 50-server.cnf, 99-openstack.cnf (MariaDB), chrony.conf, keystone.conf,
                       glance-api/registry.conf, placement.conf, nova.conf, nova-compute.conf, neutron.conf,
                       ml2_conf.ini, linuxbridge_agent.ini, l3_agent.ini, dhcp_agent.ini, metadata_agent.ini,
                       local_settings.py, openstack-dashboard.conf, swift templates (account/container/
                       object/proxy-server.conf, swift.conf, rsyncd.conf; unused by the script)
.gitignore             admin-openrc, *.img, mariadb_repo_setup, *.log
```

Generated at run time: `admin-openrc`, `cirros-0.4.0-x86_64-disk.img` (in the repo directory), the log file.

## 8. Testing and verification

On a target machine: run the commands in section 6; also `systemctl status keystone apache2 glance-api nova-api neutron-server` and check the log for `[ERROR]`. A second run should not create duplicate users, services or endpoints.

Verified in this environment: `bash -n Yoga_Installation.sh` passes and `shellcheck` (shellcheck-py) reports no findings after the fixes in section 12. **Not verified in this environment:** the installation itself, Yoga/Ubuntu 20.04 package behaviour, MariaDB authentication after the root password change, Horizon access.

## 9. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `Run this script as root` | Use `sudo` |
| `Missing required command: ...` | Install it (`apt install software-properties-common` for `add-apt-repository`) |
| `Unable to detect CONTROLLER_IP` / script aborts at start | No default route; export `CONTROLLER_IP` and `PROVIDER_INTERFACE` |
| `add-apt-repository cloud-archive:yoga` fails | Not Ubuntu 20.04, or no network |
| MariaDB `Access denied for user 'root'` | Root password differs from `MARIADB_ROOT_PASSWORD`; on a disposable machine use `RESET_MARIADB_DATA=1` (destroys all databases) |
| Endpoint/user creation fails | Check connectivity and the log; fix and re-run (helpers skip existing resources) |
| A service does not start | `journalctl -u <service> -xe` and the installer log |
| Wrong host name inside configs | Changing `CONTROLLER_HOST` after a run: re-run the script so templates are rewritten |

## 10. Limitations and security notes

- Default passwords are the install-guide placeholders; the script only warns for root/admin/metadata. Always override them.
- Secrets are echoed to the log by the `run` helper (for example `rabbitmqctl add_user`, `openstack user create --password`). The log is now created with mode 0600; delete it after installation. Passwords are also visible in the process list while commands run (`mysql -p...`).
- `RESET_MARIADB_DATA=1` irreversibly deletes all MariaDB data.
- The MariaDB template binds as shipped in `conf_files/50-server.cnf` (check `bind-address`); firewall the host.
- Swift is not installed; `SWIFT_PASS` is reserved only.
- Single node, no HA, QEMU emulation, no network/flavor bootstrap.
- Yoga and Ubuntu 20.04 are end-of-life: labs only.

## 11. Extending and customising

- Add a service: write a `configure_<service>` function using `prepare_config_file`, `ensure_database_user`, `ensure_os_user/service/endpoint`, and call it from `main`. Add the package to `PACKAGES`.
- New placeholder: add a variable at the top and a `replace_token` line in `prepare_config_file`.
- Hardware virtualisation: change `virt_type` in `conf_files/nova-compute.conf` (note: the script does not currently copy this file; it must be applied manually or added to the script).
- Enable Swift: use the templates in `conf_files/` as a starting point, following the sibling Stein installer.

## 12. Changes

- `check_prerequisites` required the `mysql` client before packages were installed, so the script aborted on a fresh Ubuntu 20.04 host. The check was removed (the client comes with `mariadb-server`).
- `ensure_hosts_entry` and `ensure_os_endpoint` used `rg` (ripgrep), which is not installed by default and not checked; the first duplicated the `/etc/hosts` line on every run and the second re-created endpoints on every run. Replaced with `grep -E` / `grep -F`.
- The log file (which can contain secrets) is now `chmod 0600`.
- README rewritten as a full guide. Verified with `bash -n` and `shellcheck` only.
