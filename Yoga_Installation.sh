#! /bin/bash

set -euo pipefail

function require_root()
{
if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must be run as root (use sudo)." >&2
  exit 1
fi
}

function check_dependencies()
{
for cmd in apt add-apt-repository mysql systemctl ip awk; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
done
}

function validate_configuration()
{
if [[ "${maria_db_root_password}" == "password" ]]; then
  echo "WARNING: maria_db_root_password is still set to the default value." >&2
fi
}

function host_config()
{
controller=$(echo "$ip"     "controller")
sed -i "/127.0.0.1/a$controller" /etc/hosts
}

function install_yoga_packages()
{
#NTP Installation
apt -y install chrony

#OpenStack Yoga repository
add-apt-repository cloud-archive:yoga -y

#Upgrade packages
apt -y update && apt -y dist-upgrade

#Installing OpenStack Client
apt -y install python3-openstackclient

#Installing mariadb
apt -y install mariadb-server python3-pymysql

#Installing rabbit-mq
apt -y install rabbitmq-server

#Installing memcached
apt -y install memcached python3-memcache

#Installing Keystone
apt -y install keystone

#Installing Glance
apt -y install glance

#Installing placement
apt -y install placement-api

#Installing Nova
apt -y install nova-api nova-conductor nova-novncproxy nova-scheduler
apt -y install nova-compute

#Installing Neutron
apt -y install neutron-server neutron-plugin-ml2 neutron-linuxbridge-agent neutron-l3-agent neutron-dhcp-agent neutron-metadata-agent

#Installing Horizon
apt -y install openstack-dashboard

#Installing swift
#apt-get -y install swift swift-proxy python-swiftclient python-keystoneclient python-keystonemiddleware memcached
#apt-get -y install xfsprogs rsync
#apt-get -y install swift swift-account swift-container swift-object

}

function configuring_db()
{
    # Copy configuration files
    cp ./conf_files/99-openstack.cnf /etc/mysql/mariadb.conf.d/99-openstack.cnf
    cp ./conf_files/50-server.cnf /etc/mysql/mariadb.conf.d/50-server.cnf

    # Restart the database service to apply configuration
    systemctl restart mariadb.service

    # Wait for the database service to restart
    sleep 10

    # Set the root password and secure installation automatically
    mysql -u root <<-EOF
    SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${maria_db_root_password}');
    DELETE FROM mysql.user WHERE User='';
    DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
    DROP DATABASE IF EXISTS test;
    DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
    FLUSH PRIVILEGES;
EOF

    # Define databases and their corresponding users and passwords
    local dbs=("keystone" "glance" "placement" "nova_api" "nova" "nova_cell0" "neutron" "iotronic" "designate")
    local users=("keystone" "glance" "placement" "nova" "nova" "nova" "neutron" "iotronic" "designate")
    local passwords=("$keystone_db_password" "$glance_db_password" "$placement_db_password" "$nova_db_password" "$nova_db_password" "$nova_db_password" "$neutron_db_password" "smartme" "smartme")

    for i in "${!dbs[@]}"; do
        db=${dbs[$i]}
        user=${users[$i]}
        password=${passwords[$i]}
        # Create database if it does not exist
        mysql -u root -p"${maria_db_root_password}" -e "CREATE DATABASE IF NOT EXISTS $db;"
        # Grant privileges to the database user
        mysql -u root -p"${maria_db_root_password}" -e "GRANT ALL PRIVILEGES ON $db.* TO '$user'@'localhost' IDENTIFIED BY '$password';"
        mysql -u root -p"${maria_db_root_password}" -e "GRANT ALL PRIVILEGES ON $db.* TO '$user'@'%' IDENTIFIED BY '$password';"
    done

    # Flush privileges to ensure all changes are applied
    mysql -u root -p"${maria_db_root_password}" -e "FLUSH PRIVILEGES;"
}


function chrony()
{
#copy preconfig file
cp ./conf_files/chrony.conf /etc/chrony/chrony.conf

#restart chrony
service chrony restart

# verify NTP synchronization
chronyc sources
}

function rabbitmq()
{
#Add the openstack user
rabbitmqctl add_user openstack "${rabbitmq_pass}"

#Permit configuration, write, and read access for the openstack user
rabbitmqctl set_permissions openstack ".*" ".*" ".*"
}

function memcached()
{
#copy preconfig file
sed -i -e  "s/^\(-l\s*\).*/\1 $ip/" /etc/memcached.conf

#Restart the Memcached service
service memcached restart
}

function keystone()
{
#copy preconfig file
cp ./conf_files/keystone.conf /etc/keystone/keystone.conf


#Populating the Identity service database
su -s /bin/sh -c "keystone-manage db_sync" keystone

#Initialize Fernet key repositories
keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
keystone-manage credential_setup --keystone-user keystone --keystone-group keystone

#Bootstrap the Identity service
keystone-manage bootstrap --bootstrap-password "${admin_pass}" \
  --bootstrap-admin-url http://controller:5000/v3/ \
  --bootstrap-internal-url http://controller:5000/v3/ \
  --bootstrap-public-url http://controller:5000/v3/ \
  --bootstrap-region-id RegionOne

#Restart the Apache service
export OS_USERNAME=admin
export OS_PASSWORD="${admin_pass}"
export OS_PROJECT_NAME=admin
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_AUTH_URL=http://controller:5000/v3
export OS_IDENTITY_API_VERSION=3

#Domain Creation
openstack domain create --description "An Example Domain" example

#Service project creation
openstack project create --domain default --description "Service Project" service

#demo project creation
openstack project create --domain default --description "Demo Project" myproject

#creating my role
openstack role create myrole

#Add the myrole role to the myproject project and myuser user
openstack role add --project myproject --user myuser myrole

#Unset the temporary OS_AUTH_URL and OS_PASSWORD environment variable:
unset OS_AUTH_URL OS_PASSWORD

#As the admin user, request an authentication token
openstack --os-auth-url http://controller:5000/v3 \
  --os-project-domain-name Default --os-user-domain-name Default \
  --os-project-name admin --os-username admin --os-password "${admin_pass}" token issue
}

function glance()
{
#copy preconfig file
cp ./conf_files/glance-api.conf /etc/glance/glance-api.conf
cp ./conf_files/glance-registry.conf /etc/glance/glance-registry.conf

#Source the admin credentials to gain access to admin-only CLI commands
. admin-openrc

#Create the glance user
openstack user create --domain default --password "${glance_pass}" glance

#Add the admin role to the glance user and service project
openstack role add --project service --user glance admin


#Create the glance service entity
openstack service create --name glance \
  --description "OpenStack Image" image

#Create the Image service API endpoints
openstack endpoint create --region RegionOne image public http://controller:9292
openstack endpoint create --region RegionOne image internal http://controller:9292
openstack endpoint create --region RegionOne image admin http://controller:9292

openstack role add --user MY_SERVICE --user-domain Default --system all reader

#Populate the Image service database
su -s /bin/sh -c "glance-manage db_sync" glance


#Restart the Image services
service glance-api restart

sleep 10s

#Source the admin credentials to gain access to admin-only CLI commands
. admin-openrc

#Download the source image
wget http://download.cirros-cloud.net/0.4.0/cirros-0.4.0-x86_64-disk.img

#upload image to the glance
openstack image create "cirros5" \
  --file cirros-0.4.0-x86_64-disk.img \
  --disk-format qcow2 --container-format bare \
  --public

#Confirm upload of the image and validate attributes
openstack image list
}

function placement()
{
#copy preconfig file
cp ./conf_files/placement.conf /etc/placement/placement.conf

#Create a Placement service user
openstack user create --domain default --password "${placement_pass}" placement

#Add the Placement user to the service project with the admin role
openstack role add --project service --user placement admin

#Create the Placement API entry in the service catalog
openstack service create --name placement \
  --description "Placement API" placement

#Create the Placement API service endpoints
openstack endpoint create --region RegionOne placement public http://controller:8778
openstack endpoint create --region RegionOne placement internal http://controller:8778
openstack endpoint create --region RegionOne placement admin http://controller:8778

#Populate the placement database
su -s /bin/sh -c "placement-manage db sync" placement

#Reload the web server to adjust to get new configuration settings for placement
service apache2 restart

#Source the admin credentials to gain access to admin-only CLI commands
. admin-openrc

#Perform status checks to make sure everything is in order
placement-status upgrade check
}

function nova()
{
#copy preconfig file
cp ./conf_files/nova.conf /etc/nova/nova.conf
sed -i -e  "s/^\(my_ip\s*=\).*/\1 $ip/" /etc/nova/nova.conf
sed -i -e  "s/^\(novncproxy_base_url\s*=\).*/\1 http:\/\/$ip:6080\/vnc_auto.html/" /etc/nova/nova.conf


#Source the admin credentials to gain access to admin-only CLI commands
. admin-openrc

#Create the nova user
openstack user create --domain default --password "${nova_pass}" nova

#Add the admin role to the nova user
openstack role add --project service --user nova admin

#Create the nova service entity
openstack service create --name nova --description "OpenStack Compute" compute

#Create the Compute API service endpoints
openstack endpoint create --region RegionOne compute public http://controller:8774/v2.1
openstack endpoint create --region RegionOne compute internal http://controller:8774/v2.1
openstack endpoint create --region RegionOne compute admin http://controller:8774/v2.1

#Populate the nova-api database
su -s /bin/sh -c "nova-manage api_db sync" nova

#Register the cell0 database
su -s /bin/sh -c "nova-manage cell_v2 map_cell0" nova

#Create the cell1 cell
su -s /bin/sh -c "nova-manage cell_v2 create_cell --name=cell1 --verbose" nova

#Populate the nova database
su -s /bin/sh -c "nova-manage db sync" nova

#Verify nova cell0 and cell1 are registered correctly
su -s /bin/sh -c "nova-manage cell_v2 list_cells" nova

#Restart the Compute services
service nova-api restart
service nova-scheduler restart
service nova-conductor restart
service nova-novncproxy restart
service nova-compute restart

#Determine whether your compute node supports hardware acceleration for virtual machines
egrep -c '(vmx|svm)' /proc/cpuinfo

#Restart the Compute service
service nova-compute restart

#Source the admin credentials to enable admin-only CLI commands
. admin-openrc

sleep 10s

#Discover compute hosts
su -s /bin/sh -c "nova-manage cell_v2 discover_hosts --verbose" nova


#Source the admin credentials to enable admin-only CLI commands
. admin-openrc
openstack compute service list

#List API endpoints in the Identity service to verify connectivity with the Identity service
openstack catalog list

#List images in the Image service to verify connectivity with the Image service
openstack image list

#Check the cells and placement API are working successfully and that other necessary prerequisites are in place
nova-status upgrade check
}

function neutron()
{
#copy preconfig file
cp ./conf_files/neutron.conf /etc/neutron/neutron.conf
cp ./conf_files/ml2_conf.ini /etc/neutron/plugins/ml2/ml2_conf.ini
cp ./conf_files/linuxbridge_agent.ini /etc/neutron/plugins/ml2/linuxbridge_agent.ini
sed -i -e  "s/^\(physical_interface_mappings\s*=\).*/\1 provider:$network_interface/" /etc/neutron/plugins/ml2/linuxbridge_agent.ini 
sed -i -e  "s/^\(local_ip\s*=\).*/\1 $ip/" /etc/neutron/plugins/ml2/linuxbridge_agent.ini
cp ./conf_files/l3_agent.ini /etc/neutron/l3_agent.ini
cp ./conf_files/dhcp_agent.ini /etc/neutron/dhcp_agent.ini
cp ./conf_files/metadata_agent.ini /etc/neutron/metadata_agent.ini
sed -i -e  "s/^\(nova_metadata_host\s*=\).*/\1 $ip/" /etc/neutron/metadata_agent.ini

#Source the admin credentials to enable admin-only CLI commands
. admin-openrc

#Create the neutron user
openstack user create --domain default --password "${neutron_pass}" neutron

#Add the admin role to the neutron user
openstack role add --project service --user neutron admin

#Create the neutron service entity
openstack service create --name neutron --description "OpenStack Networking" network

#Create the Networking service API endpoints
openstack endpoint create --region RegionOne network public http://controller:9696
openstack endpoint create --region RegionOne network internal http://controller:9696
openstack endpoint create --region RegionOne network admin http://controller:9696

#Populate the database
su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron

#Restart the Compute API service
service nova-api restart

#Restart the Networking services
service neutron-server restart
service neutron-linuxbridge-agent restart
service neutron-dhcp-agent restart
service neutron-metadata-agent restart
service neutron-l3-agent restart

#Restart the Compute service
service nova-compute restart

#Restart the Linux bridge agent
service neutron-linuxbridge-agent restart

sleep 10s
#List agents to verify successful launch of the neutron agents
openstack network agent list
}

function horizon()
{
#copy preconfig file
cp ./conf_files/local_settings.py /etc/openstack-dashboard/local_settings.py
cp ./conf_files/openstack-dashboard.conf /etc/apache2/conf-available/openstack-dashboard.conf
sed -i -e  "s/^\(OPENSTACK_HOST\s*=\).*/\1 '$ip'/" /etc/openstack-dashboard/local_settings.py
sed -i -e  "s/^\(\s*'LOCATION'\s*:\).*/\1 '$ip:11211', /" /etc/openstack-dashboard/local_settings.py

#Reload the web server configuration
service apache2 reload
}

function swift_install()
{
#copy preconfig file
mkdir -p /etc/swift
cp ./conf_files/proxy-server.conf /etc/swift/proxy-server.conf
cp ./conf_files/proxy-server.conf /etc/swift/internal-client.conf
cp ./conf_files/rsyncd.conf /etc/rsyncd.conf
sed -i -e "s/^\(address\s*=\).*/\1 $ip/" /etc/rsyncd.conf
apt-get update
apt-get install -y rsync
sed -i -e 's/RSYNC_ENABLE=false/RSYNC_ENABLE=true/g' /etc/default/rsync
service rsync restart
cp ./conf_files/account-server.conf /etc/swift/account-server.conf
#sed -i -e "s/^\(bind_ip\s*=\).*/\1 $ip/" /etc/swift/account-server.conf
cp ./conf_files/container-server.conf /etc/swift/container-server.conf
#sed -i -e "s/^\(bind_ip\s*=\).*/\1 $ip/" /etc/swift/container-server.conf
cp ./conf_files/object-server.conf /etc/swift/object-server.conf
#sed -i -e "s/^\(bind_ip\s*=\).*/\1 $ip/" /etc/swift/object-server.conf
cp ./conf_files/swift.conf /etc/swift/


. admin-openrc
openstack user create --domain default --password "${swift_pass}" swift
openstack role add --project service --user swift admin
openstack service create --name swift --description "OpenStack Object Storage" object-store
openstack endpoint create --region RegionOne object-store public http://$ip:8080/v1/AUTH_%\(project_id\)s
openstack endpoint create --region RegionOne object-store internal http://$ip:8080/v1/AUTH_%\(project_id\)s
openstack endpoint create --region RegionOne object-store admin http://$ip:8080/v1
#chmod 777 /home
#dd if=/dev/zero of=/home/hdd.img bs=3M count=1200
#mkfs.xfs -f /home/$object_storage_disk
#mkdir -p /srv/node/$object_storage_disk
#echo "/home/$object_storage_disk /srv/node/$object_storage_disk xfs noatime,nodiratime,nobarrier,logbufs=8 0 2" >> /etc/fstab
#mount /srv/node/$object_storage_disk
#/srv/node/$object_storage_disk

# Get the current user's home directory
user_home=$(eval echo ~$SUDO_USER)

# Check if a path was provided as an argument to the script
if [ -z "$object_storage_disk" ]; then
    # If no path was provided, use a default virtual disk in the user's home directory
    object_storage_disk="$user_home/hdd.img"
    # Create a virtual disk if it doesn't already exist
    if [ ! -f "$object_storage_disk" ]; then
        dd if=/dev/zero of="$object_storage_disk" bs=3M count=1200
    fi
else
    # If a path was provided, use that
    object_storage_disk=$object_storage_disk
fi

# Check if the disk already has a filesystem, if not, create one
if ! blkid | grep -q "$object_storage_disk"; then
    mkfs.xfs -f "$object_storage_disk"
fi

# Create the mount point directory if it doesn't exist
mount_point="/srv/node/$(basename "$object_storage_disk")"
mkdir -p "$mount_point"

# Check if the disk is already in fstab, if not, add it
if ! grep -q "$object_storage_disk" /etc/fstab; then
    echo "$object_storage_disk $mount_point xfs noatime,nodiratime,nobarrier,logbufs=8 0 2" >> /etc/fstab
fi

# Mount the disk
mount "$object_storage_disk" "$mount_point"

# Restart the rsync service
service rsync start

#Ensure proper ownership of the mount point directory structure
chown -R swift:swift /srv/node

#Create the recon directory and ensure proper ownership of it
mkdir -p /var/cache/swift
chown -R root:swift /var/cache/swift
chmod -R 775 /var/cache/swift

device_name=$(basename "$object_storage_disk")

#account ring creation
swift-ring-builder account.builder create 10 1 1
swift-ring-builder account.builder add --region 1 --zone 1 --ip $ip --port 6202 --device $device_name --weight 100
swift-ring-builder account.builder
swift-ring-builder account.builder rebalance

#container ring creation
swift-ring-builder container.builder create 10 1 1
swift-ring-builder container.builder add --region 1 --zone 1 --ip $ip --port 6201 --device $device_name --weight 100
swift-ring-builder container.builder
swift-ring-builder container.builder rebalance

#object ring creation
swift-ring-builder object.builder create 10 1 1
swift-ring-builder object.builder add --region 1 --zone 1 --ip $ip --port 6200 --device $device_name --weight 100
swift-ring-builder object.builder
swift-ring-builder object.builder rebalance

#Distribute ring configuration files
cp account.ring.gz container.ring.gz object.ring.gz /etc/swift

#On all nodes, ensure proper ownership of the configuration directory
chown -R root:swift /etc/swift
service memcached restart
service swift-proxy restart
swift-init all start

#cd "$current_path"

#Swift Verification
. admin-openrc
swift stat
}

######MariaDB Credentials Starts ######
maria_db_user="root"

#selecting new passsword for maria db root user
maria_db_root_password="password"

maria_db_port="3306"
maria_db_connect="mysql -h localhost -u$maria_db_user -p$maria_db_root_password --port=$maria_db_port"

######MariaDB Credentials ends ######

####### Runtime Credentials (override via env vars) #######
admin_pass="${ADMIN_PASS:-ADMIN_PASS}"
glance_pass="${GLANCE_PASS:-GLANCE_PASS}"
placement_pass="${PLACEMENT_PASS:-PLACEMENT_PASS}"
nova_pass="${NOVA_PASS:-NOVA_PASS}"
neutron_pass="${NEUTRON_PASS:-NEUTRON_PASS}"
rabbitmq_pass="${RABBIT_PASS:-RABBIT_PASS}"
swift_pass="${SWIFT_PASS:-SWIFT_PASS}"

####### Application databases with name and password Starts ########

# Keystone:
keystone_db_name="keystone"
keystone_db_user="keystone"
keystone_db_password="KEYSTONE_DBPASS"

# Glance
glance_db_name="glance"
glance_db_user="glance"
glance_db_password="GLANCE_DBPASS"

# Placement
placement_db_name="placement"
placement_db_user="placement"
placement_db_password="PLACEMENT_DBPASS"

# Nova_api
nova_api_db_name="nova_api"

# Nova
nova_db_name="nova"
nova_db_user="nova"
nova_db_password="NOVA_DBPASS"

# Nova_cell0
nova_cell0_db_name="nova_cell0"

# Neutron
neutron_db_name="neutron"
neutron_db_user="neutron"
neutron_db_password="NEUTRON_DBPASS"

####### Application databases with name and password ends ########

####Getting Provider NIC name and IP Address starts #####

current_path=$(pwd)
ip=$(ip route get 8.8.8.8 | awk 'NR == 1 {print $7; exit }')
network_interface=$(ip route get 8.8.8.8 | awk 'NR == 1 {print $5 ; exit }')
object_storage_disk=${1:-"hdd.img"};

####Getting Provider NIC name and IP Address ends #####


####Reset DB####
systemctl stop mariadb
rm -rf /var/lib/mysql/*
mysql_install_db --datadir=/var/lib/mysql --user=mysql
systemctl start mariadb

sleep 10

#######OpenStack YOGA Installation Starts  ##############

require_root
check_dependencies
validate_configuration
host_config
install_yoga_packages
configuring_db
chrony
rabbitmq
memcached
keystone
glance
placement
nova
neutron
horizon
#swift_install

#######OpenStack YOGA Installation ends  ##############
