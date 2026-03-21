# Bash Script for OpenStack Yoga Installation

<p align="center">
     <img src=https://github.com/lucadagati/openstack_stein_swift/blob/main/OpenStack-Logo-Horizontal.png>
</p>

This bash script automates the installation of the Yoga version of OpenStack, a popular open-source cloud computing platform. The script installs several key OpenStack services, including:

- Keystone: the identity service for OpenStack, providing authentication and authorization for all other services.
- Glance: the image service for OpenStack, used to store and retrieve virtual machine images.
- Placement: a new service introduced in the Yoga release, providing a REST API for managing allocation of resources like CPU, RAM, and disk space, allowing for more granular resource allocation.
- Nova: the compute service for OpenStack, used to manage virtual machines.
- Neutron: the networking service for OpenStack, used to manage virtual networks.
- Horizon: the web-based management interface for OpenStack.

The script also includes a "conf" directory that contains preconfigured config files for each service. If any changes are made to the variables in the script, it is important to reflect those changes in the config files. Additionally, the script includes "admin-openrc" and "demo-openrc" files which contain preconfigured credentials. If any changes are made to the credentials, these files should also be updated.

The script is designed to be executed on Ubuntu 20.04 LTS and can be downloaded and run using the following commands:

```bash
git clone https://github.com/lucadagati/openstack_yoga.git
cd openstack_yoga
sudo bash Yoga_Installation.sh
```

You can override service passwords at runtime with environment variables (for example `ADMIN_PASS`, `GLANCE_PASS`, `PLACEMENT_PASS`, `NOVA_PASS`, `NEUTRON_PASS`, `RABBIT_PASS`, `SWIFT_PASS`) before running the script:

```bash
sudo ADMIN_PASS='your-admin-password' GLANCE_PASS='your-glance-password' bash Yoga_Installation.sh
```

It's important to note that the script has been tested on Ubuntu 20.04 LTS and it is recommended to use the same version of Ubuntu or another LTS version for the best compatibility.

The Yoga release of OpenStack includes a number of new features and improvements over previous versions, such as enhanced support for containerized workloads, improved security, and better scalability. This script provides an easy and efficient way to install and set up the Yoga version of OpenStack on an Ubuntu 20.04 LTS system.
