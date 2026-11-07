#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${SCRIPT_DIR}/conf_files"
LOG_FILE="/var/log/openstack-yoga-installer.log"
ADMIN_OPENRC_PATH="${SCRIPT_DIR}/admin-openrc"

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

# ----------------------------
# User-configurable variables
# ----------------------------
CONTROLLER_HOST="${CONTROLLER_HOST:-controller}"
CONTROLLER_IP="${CONTROLLER_IP:-$(ip route get 8.8.8.8 | awk 'NR == 1 {print $7; exit}')}"
PROVIDER_INTERFACE="${PROVIDER_INTERFACE:-$(ip route get 8.8.8.8 | awk 'NR == 1 {print $5; exit}')}"
REGION="${REGION:-RegionOne}"

RESET_MARIADB_DATA="${RESET_MARIADB_DATA:-0}"
DOWNLOAD_CIRROS="${DOWNLOAD_CIRROS:-1}"

MARIADB_ROOT_PASSWORD="${MARIADB_ROOT_PASSWORD:-password}"
RABBIT_PASS="${RABBIT_PASS:-RABBIT_PASS}"
ADMIN_PASS="${ADMIN_PASS:-ADMIN_PASS}"
METADATA_SECRET="${METADATA_SECRET:-METADATA_SECRET}"

KEYSTONE_DBPASS="${KEYSTONE_DBPASS:-KEYSTONE_DBPASS}"
GLANCE_DBPASS="${GLANCE_DBPASS:-GLANCE_DBPASS}"
PLACEMENT_DBPASS="${PLACEMENT_DBPASS:-PLACEMENT_DBPASS}"
NOVA_DBPASS="${NOVA_DBPASS:-NOVA_DBPASS}"
NEUTRON_DBPASS="${NEUTRON_DBPASS:-NEUTRON_DBPASS}"

GLANCE_PASS="${GLANCE_PASS:-GLANCE_PASS}"
PLACEMENT_PASS="${PLACEMENT_PASS:-PLACEMENT_PASS}"
NOVA_PASS="${NOVA_PASS:-NOVA_PASS}"
NEUTRON_PASS="${NEUTRON_PASS:-NEUTRON_PASS}"
SWIFT_PASS="${SWIFT_PASS:-SWIFT_PASS}"

readonly PACKAGES=(
  chrony
  software-properties-common
  python3-openstackclient
  mariadb-server
  python3-pymysql
  rabbitmq-server
  memcached
  python3-memcache
  keystone
  glance
  placement-api
  nova-api
  nova-conductor
  nova-novncproxy
  nova-scheduler
  nova-compute
  neutron-server
  neutron-plugin-ml2
  neutron-linuxbridge-agent
  neutron-l3-agent
  neutron-dhcp-agent
  neutron-metadata-agent
  openstack-dashboard
)

log() {
  local level="$1"
  shift
  local msg="$*"
  printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$level" "$msg" | tee -a "$LOG_FILE"
}

run() {
  log "RUN" "$*"
  "$@"
}

die() {
  log "ERROR" "$*"
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root (use sudo)."
}

check_prerequisites() {
  local cmds=(apt add-apt-repository systemctl ip awk sed)
  local c
  for c in "${cmds[@]}"; do
    command -v "$c" >/dev/null 2>&1 || die "Missing required command: $c"
  done
  [[ -d "$CONF_DIR" ]] || die "Missing directory: $CONF_DIR"
}

validate_inputs() {
  [[ -n "$CONTROLLER_IP" ]] || die "Unable to detect CONTROLLER_IP."
  [[ -n "$PROVIDER_INTERFACE" ]] || die "Unable to detect PROVIDER_INTERFACE."
  [[ "$MARIADB_ROOT_PASSWORD" != "password" ]] || log "WARN" "MARIADB_ROOT_PASSWORD is still default."
  [[ "$ADMIN_PASS" != "ADMIN_PASS" ]] || log "WARN" "ADMIN_PASS is still default."
  [[ "$METADATA_SECRET" != "METADATA_SECRET" ]] || log "WARN" "METADATA_SECRET is still default."
}

ensure_hosts_entry() {
  if ! grep -Eq "^[[:space:]]*${CONTROLLER_IP}[[:space:]]+${CONTROLLER_HOST}$" /etc/hosts; then
    echo "${CONTROLLER_IP} ${CONTROLLER_HOST}" >> /etc/hosts
    log "INFO" "Added /etc/hosts entry: ${CONTROLLER_IP} ${CONTROLLER_HOST}"
  else
    log "INFO" "/etc/hosts already contains ${CONTROLLER_HOST}"
  fi
}

install_packages() {
  log "INFO" "Configuring OpenStack Yoga repository."
  run add-apt-repository cloud-archive:yoga -y
  run apt -y update
  run apt -y dist-upgrade
  run apt -y install "${PACKAGES[@]}"
}

replace_token() {
  local file="$1"
  local token="$2"
  local value="$3"
  local escaped
  escaped="$(printf '%s' "$value" | sed 's/[\/&]/\\&/g')"
  sed -i "s/${token}/${escaped}/g" "$file"
}

prepare_config_file() {
  local src="$1"
  local dst="$2"
  [[ -f "$src" ]] || die "Template file not found: $src"
  install -m 0644 "$src" "$dst"

  replace_token "$dst" "controller" "$CONTROLLER_HOST"
  replace_token "$dst" "RABBIT_PASS" "$RABBIT_PASS"
  replace_token "$dst" "KEYSTONE_DBPASS" "$KEYSTONE_DBPASS"
  replace_token "$dst" "GLANCE_DBPASS" "$GLANCE_DBPASS"
  replace_token "$dst" "PLACEMENT_DBPASS" "$PLACEMENT_DBPASS"
  replace_token "$dst" "NOVA_DBPASS" "$NOVA_DBPASS"
  replace_token "$dst" "NEUTRON_DBPASS" "$NEUTRON_DBPASS"
  replace_token "$dst" "GLANCE_PASS" "$GLANCE_PASS"
  replace_token "$dst" "PLACEMENT_PASS" "$PLACEMENT_PASS"
  replace_token "$dst" "NOVA_PASS" "$NOVA_PASS"
  replace_token "$dst" "NEUTRON_PASS" "$NEUTRON_PASS"
  replace_token "$dst" "ADMIN_PASS" "$ADMIN_PASS"
  replace_token "$dst" "SWIFT_PASS" "$SWIFT_PASS"
  replace_token "$dst" "METADATA_SECRET" "$METADATA_SECRET"
}

mysql_root() {
  mysql -uroot -p"${MARIADB_ROOT_PASSWORD}" "$@"
}

reset_mariadb_if_requested() {
  if [[ "$RESET_MARIADB_DATA" != "1" ]]; then
    log "INFO" "Skipping MariaDB reset (RESET_MARIADB_DATA=0)."
    return
  fi
  log "WARN" "RESET_MARIADB_DATA=1, existing MariaDB data will be removed."
  run systemctl stop mariadb
  rm -rf /var/lib/mysql/*
  run mysql_install_db --datadir=/var/lib/mysql --user=mysql
  run systemctl start mariadb
  sleep 5
}

configure_mariadb() {
  prepare_config_file "${CONF_DIR}/99-openstack.cnf" /etc/mysql/mariadb.conf.d/99-openstack.cnf
  prepare_config_file "${CONF_DIR}/50-server.cnf" /etc/mysql/mariadb.conf.d/50-server.cnf
  run systemctl restart mariadb
  sleep 5

  mysql -u root <<EOF
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${MARIADB_ROOT_PASSWORD}');
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
}

ensure_database_user() {
  local db="$1"
  local user="$2"
  local pass="$3"
  mysql_root -e "CREATE DATABASE IF NOT EXISTS ${db};"
  mysql_root -e "GRANT ALL PRIVILEGES ON ${db}.* TO '${user}'@'localhost' IDENTIFIED BY '${pass}';"
  mysql_root -e "GRANT ALL PRIVILEGES ON ${db}.* TO '${user}'@'%' IDENTIFIED BY '${pass}';"
  mysql_root -e "FLUSH PRIVILEGES;"
}

configure_base_services() {
  prepare_config_file "${CONF_DIR}/chrony.conf" /etc/chrony/chrony.conf
  run systemctl restart chrony

  run rabbitmqctl add_user openstack "${RABBIT_PASS}" || true
  run rabbitmqctl set_permissions openstack ".*" ".*" ".*"

  sed -i -E "s/^-l\s+.*/-l ${CONTROLLER_IP}/" /etc/memcached.conf
  run systemctl restart memcached
}

write_admin_openrc() {
  cat > "$ADMIN_OPENRC_PATH" <<EOF
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=${ADMIN_PASS}
export OS_AUTH_URL=http://${CONTROLLER_HOST}:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF
  chmod 0600 "$ADMIN_OPENRC_PATH"
}

source_admin_openrc() {
  # shellcheck disable=SC1090
  source "$ADMIN_OPENRC_PATH"
}

ensure_os_user() {
  local user="$1"
  local pass="$2"
  if ! openstack user show "$user" >/dev/null 2>&1; then
    run openstack user create --domain default --password "$pass" "$user"
  fi
}

ensure_os_service() {
  local name="$1"
  local type="$2"
  local desc="$3"
  if ! openstack service show "$name" >/dev/null 2>&1; then
    run openstack service create --name "$name" --description "$desc" "$type"
  fi
}

ensure_os_endpoint() {
  local service_type="$1"
  local iface="$2"
  local url="$3"
  if ! openstack endpoint list --service "$service_type" --interface "$iface" -f value -c URL | grep -Fq -- "$url"; then
    run openstack endpoint create --region "$REGION" "$service_type" "$iface" "$url"
  fi
}

configure_keystone() {
  prepare_config_file "${CONF_DIR}/keystone.conf" /etc/keystone/keystone.conf
  ensure_database_user "keystone" "keystone" "$KEYSTONE_DBPASS"
  run su -s /bin/sh -c "keystone-manage db_sync" keystone
  run keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
  run keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
  run keystone-manage bootstrap \
    --bootstrap-password "$ADMIN_PASS" \
    --bootstrap-admin-url "http://${CONTROLLER_HOST}:5000/v3/" \
    --bootstrap-internal-url "http://${CONTROLLER_HOST}:5000/v3/" \
    --bootstrap-public-url "http://${CONTROLLER_HOST}:5000/v3/" \
    --bootstrap-region-id "$REGION" || true
  write_admin_openrc
  source_admin_openrc
  openstack project show service >/dev/null 2>&1 || run openstack project create --domain default --description "Service Project" service
  run openstack token issue >/dev/null
}

configure_glance() {
  prepare_config_file "${CONF_DIR}/glance-api.conf" /etc/glance/glance-api.conf
  prepare_config_file "${CONF_DIR}/glance-registry.conf" /etc/glance/glance-registry.conf
  ensure_database_user "glance" "glance" "$GLANCE_DBPASS"
  source_admin_openrc
  ensure_os_user glance "$GLANCE_PASS"
  run openstack role add --project service --user glance admin || true
  ensure_os_service glance image "OpenStack Image"
  ensure_os_endpoint image public "http://${CONTROLLER_HOST}:9292"
  ensure_os_endpoint image internal "http://${CONTROLLER_HOST}:9292"
  ensure_os_endpoint image admin "http://${CONTROLLER_HOST}:9292"
  run su -s /bin/sh -c "glance-manage db_sync" glance
  run systemctl restart glance-api
}

upload_cirros_image() {
  [[ "$DOWNLOAD_CIRROS" == "1" ]] || return
  source_admin_openrc
  local img="${SCRIPT_DIR}/cirros-0.4.0-x86_64-disk.img"
  if [[ ! -f "$img" ]]; then
    run wget -O "$img" http://download.cirros-cloud.net/0.4.0/cirros-0.4.0-x86_64-disk.img
  fi
  if ! openstack image show cirros >/dev/null 2>&1; then
    run openstack image create "cirros" \
      --file "$img" \
      --disk-format qcow2 \
      --container-format bare \
      --public
  fi
}

configure_placement() {
  prepare_config_file "${CONF_DIR}/placement.conf" /etc/placement/placement.conf
  ensure_database_user "placement" "placement" "$PLACEMENT_DBPASS"
  source_admin_openrc
  ensure_os_user placement "$PLACEMENT_PASS"
  run openstack role add --project service --user placement admin || true
  ensure_os_service placement placement "Placement API"
  ensure_os_endpoint placement public "http://${CONTROLLER_HOST}:8778"
  ensure_os_endpoint placement internal "http://${CONTROLLER_HOST}:8778"
  ensure_os_endpoint placement admin "http://${CONTROLLER_HOST}:8778"
  run su -s /bin/sh -c "placement-manage db sync" placement
  run systemctl restart apache2
}

configure_nova() {
  prepare_config_file "${CONF_DIR}/nova.conf" /etc/nova/nova.conf
  sed -i -E "s/^(my_ip\s*=\s*).*/\1${CONTROLLER_IP}/" /etc/nova/nova.conf
  sed -i -E "s#^(novncproxy_base_url\s*=\s*).*#\1http://${CONTROLLER_HOST}:6080/vnc_auto.html#" /etc/nova/nova.conf
  ensure_database_user "nova_api" "nova" "$NOVA_DBPASS"
  ensure_database_user "nova" "nova" "$NOVA_DBPASS"
  ensure_database_user "nova_cell0" "nova" "$NOVA_DBPASS"
  source_admin_openrc
  ensure_os_user nova "$NOVA_PASS"
  run openstack role add --project service --user nova admin || true
  ensure_os_service nova compute "OpenStack Compute"
  ensure_os_endpoint compute public "http://${CONTROLLER_HOST}:8774/v2.1"
  ensure_os_endpoint compute internal "http://${CONTROLLER_HOST}:8774/v2.1"
  ensure_os_endpoint compute admin "http://${CONTROLLER_HOST}:8774/v2.1"
  run su -s /bin/sh -c "nova-manage api_db sync" nova
  run su -s /bin/sh -c "nova-manage cell_v2 map_cell0" nova || true
  run su -s /bin/sh -c "nova-manage cell_v2 create_cell --name=cell1 --verbose" nova || true
  run su -s /bin/sh -c "nova-manage db sync" nova
  run systemctl restart nova-api nova-scheduler nova-conductor nova-novncproxy nova-compute
  run su -s /bin/sh -c "nova-manage cell_v2 discover_hosts --verbose" nova || true
}

configure_neutron() {
  prepare_config_file "${CONF_DIR}/neutron.conf" /etc/neutron/neutron.conf
  prepare_config_file "${CONF_DIR}/ml2_conf.ini" /etc/neutron/plugins/ml2/ml2_conf.ini
  prepare_config_file "${CONF_DIR}/linuxbridge_agent.ini" /etc/neutron/plugins/ml2/linuxbridge_agent.ini
  prepare_config_file "${CONF_DIR}/l3_agent.ini" /etc/neutron/l3_agent.ini
  prepare_config_file "${CONF_DIR}/dhcp_agent.ini" /etc/neutron/dhcp_agent.ini
  prepare_config_file "${CONF_DIR}/metadata_agent.ini" /etc/neutron/metadata_agent.ini

  sed -i -E "s/^(physical_interface_mappings\s*=\s*).*/\1provider:${PROVIDER_INTERFACE}/" /etc/neutron/plugins/ml2/linuxbridge_agent.ini
  sed -i -E "s/^(local_ip\s*=\s*).*/\1${CONTROLLER_IP}/" /etc/neutron/plugins/ml2/linuxbridge_agent.ini
  sed -i -E "s/^(nova_metadata_host\s*=\s*).*/\1${CONTROLLER_HOST}/" /etc/neutron/metadata_agent.ini

  ensure_database_user "neutron" "neutron" "$NEUTRON_DBPASS"
  source_admin_openrc
  ensure_os_user neutron "$NEUTRON_PASS"
  run openstack role add --project service --user neutron admin || true
  ensure_os_service neutron network "OpenStack Networking"
  ensure_os_endpoint network public "http://${CONTROLLER_HOST}:9696"
  ensure_os_endpoint network internal "http://${CONTROLLER_HOST}:9696"
  ensure_os_endpoint network admin "http://${CONTROLLER_HOST}:9696"

  run su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron
  run systemctl restart nova-api
  run systemctl restart neutron-server neutron-linuxbridge-agent neutron-dhcp-agent neutron-metadata-agent neutron-l3-agent nova-compute
}

configure_horizon() {
  prepare_config_file "${CONF_DIR}/local_settings.py" /etc/openstack-dashboard/local_settings.py
  prepare_config_file "${CONF_DIR}/openstack-dashboard.conf" /etc/apache2/conf-available/openstack-dashboard.conf
  sed -i -E "s/^(OPENSTACK_HOST\s*=\s*).*/\1\"${CONTROLLER_HOST}\"/" /etc/openstack-dashboard/local_settings.py
  sed -i -E "s/('LOCATION':\s*)'[^']*'/\1'${CONTROLLER_HOST}:11211'/" /etc/openstack-dashboard/local_settings.py
  run systemctl reload apache2
}

post_checks() {
  source_admin_openrc
  run openstack service list
  run openstack endpoint list
  run openstack compute service list || true
  run openstack network agent list || true
  run openstack image list || true
}

main() {
  require_root
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
  log "INFO" "Starting OpenStack Yoga automated installation."
  check_prerequisites
  validate_inputs
  ensure_hosts_entry
  install_packages
  reset_mariadb_if_requested
  configure_mariadb
  configure_base_services
  configure_keystone
  configure_glance
  upload_cirros_image
  configure_placement
  configure_nova
  configure_neutron
  configure_horizon
  post_checks
  log "INFO" "OpenStack Yoga automated installation completed."
}

main "$@"
