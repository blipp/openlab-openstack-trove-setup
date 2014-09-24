#!/bin/bash
# 
# Script to install OpenStack and OpenStack Trove on a
# Scientific Linux machine.
#
# Written by Benjamin Lipp and available on
# https://github.com/blipp/openlab-openstack-trove-setup
#
#
# ## How to use
#
# Execute this script from the directory it is stored in!
# 
# If you execute this script as it is, it will do nothing. It is 
# not meant to be executed without looking at the code. Although
# the functions are meant to be executed in the order they are
# placed in the script, you are supposed to execute them one by
# one and after each, check if what happened is what you wanted.
#
# At the end of this script, "$@" is called, so you can
# execute the functions by passing their name to the script.
#
# The script stores output of commands inside the directory
# $OUTPUT_DIR. Don't delete it, the files will be used by the
# script to obtain IDs.
#
# ### NAT after a reboot
#
# After a reboot of your machine, you have to setup the NAT again,
# do it by calling the according script inside the scripts directory.
#
# ### Images and cloudinit
#
# In ./config, cloudinit config files for Ubuntu and Fedora are
# available. If you want to use Fedora, for example change the
# script to upload another image to Glance and to create the datastore
# with the new image.
#
#
# ## Scripts in ./scripts directory
#
# You can use ./scripts/ipns to execute commands inside a
# network namespace. This might be needed for troubleshooting.
#
# ./scripts/floatingip-associate is available to add a floating IP
# to an instance
#
#
# ## Documentation used
#
# This script was written following
# http://openstack.redhat.com/PackStack_All-in-One_DIY_Configuration
# so if in the comments you see something like "Step x: …" that
# refers to the according section in this wiki page.
# A copy of the wiki page is available in the Github repository. If
# you cannot open it with your browser, try this Firefox addon:
# http://maf.mozdev.org/
#
# For the installation of Trove, the official documentation was
# taken as a starting point
# http://docs.openstack.org/icehouse/install-guide/install/yum/content/trove-install.html
#


# TODO: change UBUNTU_IMAGE_URL to IMAGE_URL and make it possible
#       to use other images than Ubuntu
# TODO: install Trove from Github repos instead of from the
#       package repositories
# TODO: switch from openstack-config to crudini


# to see what happens
set -x

# if you want to confirm each step, uncomment the following line
# here _and in each_ of the functions below
#trap read debug


#
# Load configuration
#  if the file is not present, create it on the basis of
#  setup-config.sample
#
. setup-config


#
# Begin of helper functions
#

# expects 3 parameters
# 1: file inside $OUTPUT_DIR to read
# 2: expression to grep
# 3: number of field to get via awk
#
# inspired by DevStack's code
function get_field {
	grep "$2" $OUTPUT_DIR/$1 | awk "{print \$$3}"
}

# write to given file inside $OUTPUT_DIR 
# but still output to stdout
function log_output {
	tee $OUTPUT_DIR/$1
}

#
# End of helper functions
#




#
# Start of the actual functions
#

function setup_environment {
	set -x
#	trap read debug

        echo "set term=xterm" >> .vimrc
	mkdir /root/backup
	mkdir /root/scripts
	mkdir -p $OUTPUT_DIR
	mkdir -p $IMAGE_DIR
	yum install -y pwgen ack etckeeper
	etckeeper init
	etckeeper commit "initial commit"
}


#
# Call of Packstack
#
# The workarounds done before the call are taken from
# http://information-technology.web.cern.ch/book/cern-cloud-infrastructure-user-guide/advanced-topics/installing-openstack#icehouse
#
# If you encounter an error while running Packstack, try to fix it
# with http://openstack.redhat.com/Workarounds or
# http://openstack.redhat.com/Workarounds_2014_01 and run Packstack
# again using the answer file it generated:
# packstack --answer-file=…
#
function packstack {
	set -x
#	trap read debug

        yum install -y http://rdo.fedorapeople.org/rdo-release.rpm

	# fix repository priorities
        sed -i -e 's/priority.*/priority=1/g' /etc/yum.repos.d/rdo-release.repo

        sed --in-place '/^exclude=libmongodb/d;s/^priority=/exclude=libmongodb,pymongo\*,mongodb\*,python-bson,python-webob,python-mako,python-webtest\npriority=/g' /etc/yum.repos.d/slc6-os.repo /etc/yum.repos.d/slc6-updates.repo /etc/yum.repos.d/slc6-extras.repo

	# Packstack is at the moment not able to add the SSH key
	# correctly to authorized_keys, so do it manually before
        ssh-keygen -q -f /root/.ssh/id_rsa -t rsa -P ""
        sh -c 'cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys'
        chmod 700 .ssh
        chmod 600 .ssh/*

        yum install -y openstack-packstack
        sed -i'' '3 s/^/#/' /usr/share/openstack-puppet/modules/packstack/templates/innodb.cnf.erb

	# I know this is bad, but for this test setup, things should just work
	# see http://securityblog.org/2006/05/21/software-not-working-disable-selinux/
	# and http://www.crypt.gen.nz/selinux/disable_selinux.html
        sed -i -e 's/^SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config

	# disable provision-demo: don't create demo user and network
	# provision-all-in-one-
        packstack --allinone --os-neutron-install=y --provision-demo=n --provision-all-in-one-ovs-bridge=n --nagios-install=n
}


function after_packstack {
	. $RC_ADMIN
	# change mail address
	keystone user-update --name admin --email root@localhost admin | log_output user-update-admin
}


function modify_neutron_config {
	set -x
#	trap read debug

	# Step 1: Verify and Modify Neutron Configuration
	#sleep 5m
	for i in server dhcp-agent l3-agent metadata-agent openvswitch-agent; do /etc/init.d/neutron-$i restart; done
	openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT ovs_use_veth True
	openstack-config --set /etc/neutron/l3_agent.ini DEFAULT ovs_use_veth True
	openstack-config --set /etc/neutron/dhcp_agent.ini DEFAULT enable_isolated_metadata True
	# Step 2: Configure Router and External Network
	ifconfig | log_output ifconfig_vanilla
	ovs-vsctl show | log_output ovs-vsctl-show_vanilla
	brctl show | log_output brctl-show_vanilla
	mv /etc/sysconfig/network-scripts/ifcfg-br-tun /root/backup/
	for i in server dhcp-agent l3-agent metadata-agent openvswitch-agent; do /etc/init.d/neutron-$i restart; done
}


function modify_glance_config {
	set -x
#	trap read debug

	# fix an issue with glance, see http://openstack.redhat.com/Workarounds#glance:_Error_communicating_with_http:.2F.2F192.168.8.96:9292_timed_out
	openstack-config --set /etc/glance/glance-api.conf DEFAULT notification_driver noop
}


#
# Call the script to setup the NAT
# You have to call this script again after a reboot!
#
function setup_nat {
	set -x
#	trap read debug

	# Setting up NAT and "virtual" external network
	./scripts/setup-external-network.sh
}


function create_external_network_and_tenant {
	set -x
#	trap read debug

	# Creating the External Network
	. $RC_ADMIN
	neutron net-create extnet --router:external=True | log_output extnet
	NETWORK_ID=$(get_field extnet " id " 4)
	# Create Subnet
	neutron subnet-create extnet --allocation-pool start=10.0.21.10,end=10.0.21.125 --gateway 10.0.21.1 --enable_dhcp=False 10.0.21.0/24 | log_output extnet_subnet
	# Create Router
	neutron router-create rdorouter | log_output rdorouter
	ROUTER_ID=$(get_field rdorouter " id " 4)
	# Set the Router's Gateway
	neutron router-gateway-set $ROUTER_ID $NETWORK_ID | log_output gateway-set
	neutron router-list | log_output router-list
	ovs-vsctl show | log_output ovs-vsctl-show_after_router_create
	# Create a Tenant and a User
	keystone tenant-create --name rdotest | log_output tenant-create
	TENANT_ID=$(get_field tenant-create " id " 4)
	TENANT_PASS=$(pwgen 15 1)
	echo "rdotest" >> $PASSWORD_FILE
	echo $TENANT_PASS >> $PASSWORD_FILE
	keystone user-create --name rdotest --tenant-id $TENANT_ID --pass $TENANT_PASS --enabled true | log_output user-create
	USER_ID=$(get_field user-create " id " 4)
	# Create RC file for rdotest
	cat $RC_ADMIN | sed -e 's/admin/rdotest/g' -e "s/^export OS_PASSWORD.*/export OS_PASSWORD=$TENANT_PASS/" | tee $RC_RDOTEST
}


function create_private_network {
	set -x
#	trap read debug

	# Step 4: Create Private Network
	. $RC_RDOTEST
	neutron net-create rdonet | log_output net-create-rdonet
	neutron subnet-create --dns-nameserver 137.138.17.5 --dns-nameserver 137.138.16.5 rdonet 10.0.90.0/24 | log_output subnet-create-rdonet
	SUBNET_ID=$(get_field subnet-create-rdonet " id " 4)
	. $RC_ADMIN
	ROUTER_ID=$(get_field rdorouter " id " 4)
	neutron router-interface-add $ROUTER_ID $SUBNET_ID | log_output router-interface-add
	ovs-vsctl show | log_output ovs-vsctl-show_after_subnet
}


# 
# Creates a CirrOS image, adds root's SSH key as keypair
# and allows ICMP and SSH in the default security group
#
function create_image_and_prepare_environment {
	set -x
#	trap read debug

	# Step 5: Create image
	. $RC_ADMIN
	glance image-create --container-format=bare --disk-format=qcow2 --name=cirros --is-public=True < $CIRROS_IMAGE_FILE | log_output image-create
	# Step 6: Create and Import SSH Key
	. $RC_RDOTEST
	nova keypair-add --pub-key /root/.ssh/id_rsa.pub rdokey | log_output keypair-add
	# Step 7: Create Security Group Rules
	neutron security-group-rule-create --protocol icmp --direction ingress default | log_output security-group-rule-icmp
	neutron security-group-rule-create --protocol tcp --port-range-min 22 --port-range-max 22 --direction ingress default | log_output security-group-rule-ssh
}


#
# Boots a CirrOS instance
# expects 1 argument: number to attach to "cirros" to get the name of the instance
#
function boot_vm {
	set -x
#	trap read debug

	# Step 8: Boot the VM
	. $RC_RDOTEST
	IMAGE_ID=$(get_field image-create " id " 4)
	nova boot --flavor 1 --image $IMAGE_ID --key-name rdokey "cirros$1" | log_output "boot-cirros$1"
}


#
# Assign a floating IP to a previously created CirrOS instance
# expects 1 argument: number to attach to "cirros" to get the name of the instance
#
function assign_floating_ip {
	set -x
#	trap read debug

	. $RC_RDOTEST
	VM_ID=$(get_field "boot-cirros$1" " id " 4)
	neutron port-list --device_id $VM_ID | log_output "port-list-cirros$1"
	PORT_ID=$(get_field "port-list-cirros$1" "subnet_id" 2)
	neutron floatingip-create extnet | log_output "floatingip-create-cirros$1"
	FLOATINGIP_ID=$(get_field "floatingip-create-cirros$1" " id " 4)
	neutron floatingip-associate $FLOATINGIP_ID $PORT_ID
}


#
# Installs Trove from the package repositories
# If you want to install another version from Github,
# do it manually and skip this step.
#
function install_trove {
	set -x
#	trap read debug

	#yum reinstall -y openstack-trove python-troveclient
	yum install -y openstack-trove python-troveclient
}

#
# Configure Trove from scratch.
# * Creates config files
# * Creates an image and cloudinit config file
# * Creates user, tenant, service and endpoint
# * Creates a MySQL datastore
# * Starts and enables Trove services
#
function configure_trove {
	set -x
#	trap read debug

	. $RC_ADMIN

	# generate passwords
	# Trove's Keystone user
	TROVE_PASS=$(pwgen 15 1)
	echo "trove" >> $PASSWORD_FILE
	echo $TROVE_PASS >> $PASSWORD_FILE
	# Trove's MySQL user
	TROVE_MYSQL_PASS=$(pwgen 15 1)
	echo "mysql: trove" >> $PASSWORD_FILE
	echo $TROVE_MYSQL_PASS >> $PASSWORD_FILE

	# Create user and tenant
	keystone user-create --name=trove --pass=$TROVE_PASS --email=trove@localhost --tenant=services | log_output user-create-trove-services
	keystone user-role-add --user=trove --tenant=services --role=admin | log_output user-role-add-trove-services
 
       # Create RC file for trove. Is this even needed?
        cat $RC_ADMIN | sed -e 's/admin/trove/g' -e "s/OS_TENANT_NAME=trove/OS_TENANT_NAME=services/g" -e "s/^export OS_PASSWORD.*/export OS_PASSWORD=$TROVE_PASS/" | tee $RC_TROVE

	
	# make sure files exist and fix permissions
	mkdir /etc/trove
	mkdir /etc/trove/cloudinit
	for config_file in api-paste.ini trove.conf trove-taskmanager.conf trove-conductor.conf trove-guestagent.conf; do touch /etc/trove/$config_file; done
	touch /etc/trove/cloudinit/mysql.cloudinit
	chown -R root:trove /etc/trove

	# fill configuration files

	# enhanced logging to simplify debugging
	for config_file in trove.conf trove-taskmanager.conf trove-conductor.conf trove-guestagent.conf; do
		openstack-config --set /etc/trove/$config_file DEFAULT verbose True
		openstack-config --set /etc/trove/$config_file DEFAULT debug True
	done

	# put credentials in all config files
	# maybe this is not needed for api-paste.ini
	for config_file in api-paste.ini trove.conf trove-taskmanager.conf trove-conductor.conf trove-guestagent.conf; do
		openstack-config --set /etc/trove/$config_file keystone_authtoken auth_uri http://$HOST_IP:35357/
		openstack-config --set /etc/trove/$config_file keystone_authtoken identity_uri http://$HOST_IP:35357/
		openstack-config --set /etc/trove/$config_file keystone_authtoken admin_password $TROVE_PASS
		openstack-config --set /etc/trove/$config_file keystone_authtoken admin_user trove
		openstack-config --set /etc/trove/$config_file keystone_authtoken admin_tenant_name services
	done

	# basic settings for all Trove services
	for config_file in trove.conf trove-taskmanager.conf trove-conductor.conf; do
		openstack-config --set /etc/trove/$config_file DEFAULT log_dir /var/log/trove
		openstack-config --set /etc/trove/$config_file DEFAULT trove_auth_url http://$HOST_IP:5000/v2.0
		openstack-config --set /etc/trove/$config_file DEFAULT nova_compute_url http://$HOST_IP:8774/v2
		openstack-config --set /etc/trove/$config_file DEFAULT cinder_url http://$HOST_IP:8776/v1
		openstack-config --set /etc/trove/$config_file DEFAULT swift_url http://$HOST_IP:8080/v1/AUTH_
		openstack-config --set /etc/trove/$config_file DEFAULT sql_connection mysql://trove:$TROVE_MYSQL_PASS@$HOST_IP/trove
		openstack-config --set /etc/trove/$config_file DEFAULT notifier_queue_hostname $HOST_IP
		# this would be for Juno
		#openstack-config --set /etc/trove/$config_file DEFAULT rpc_backend rabbit
		openstack-config --set /etc/trove/$config_file DEFAULT rabbit_host $HOST_IP
		openstack-config --set /etc/trove/$config_file DEFAULT rabbit_password guest
	done

	# settings for api-paste.ini
	openstack-config --set /etc/trove/api-paste.ini filter:authtoken auth_uri http://$HOST_IP:35357/
	openstack-config --set /etc/trove/api-paste.ini filter:authtoken identity_uri http://$HOST_IP:35357/
	openstack-config --set /etc/trove/api-paste.ini filter:authtoken admin_user trove
	openstack-config --set /etc/trove/api-paste.ini filter:authtoken admin_password $TROVE_PASS
	#openstack-config --set /etc/trove/api-paste.ini filter:authtoken admin_token ?
	openstack-config --set /etc/trove/api-paste.ini filter:authtoken admin_tenant_name services
	openstack-config --set /etc/trove/api-paste.ini filter:authtoken signing_dir /var/cache/trove
	
	# settings for trove.conf
	openstack-config --set /etc/trove/trove.conf DEFAULT default_datastore mysql
	openstack-config --set /etc/trove/trove.conf DEFAULT add_addresses True
	openstack-config --set /etc/trove/trove.conf DEFAULT network_label_regex "^NETWORK_LABEL$"
	
	# nova credentials for all Trove services talking to Nova
	# is this needed for the Guestagent? Does it talk to Nova?
	#for config_file in trove-taskmanager.conf trove-conductor.conf trove-guestagent.conf; do
	for config_file in trove-taskmanager.conf; do
		openstack-config --set /etc/trove/$config_file DEFAULT nova_proxy_admin_user admin
		openstack-config --set /etc/trove/$config_file DEFAULT nova_proxy_admin_pass $ADMIN_PASS
		openstack-config --set /etc/trove/$config_file DEFAULT nova_proxy_admin_tenant_name services
	done

	# settings for Trove Conductor
	openstack-config --set /etc/trove/trove-conductor.conf DEFAULT control_exchange trove

	# settings for Trove Guestagents
	openstack-config --set /etc/trove/trove-guestagent.conf DEFAULT rabbit_host $HOST_IP
	openstack-config --set /etc/trove/trove-guestagent.conf DEFAULT rabbit_password guest
	openstack-config --set /etc/trove/trove-guestagent.conf DEFAULT trove_auth_url http://$HOST_IP:5000/v2.0
	openstack-config --set /etc/trove/trove-guestagent.conf DEFAULT control_exchange trove

	# settings for Trove Taskmanager
	openstack-config --set /etc/trove/trove-taskmanager.conf DEFAULT cloudinit_location /etc/trove/cloudinit
	openstack-config --set /etc/trove/trove-taskmanager.conf DEFAULT taskmanager_manager trove.taskmanager.manager.Manager
	
	# create Trove's MySQL database
	sed -e "s/TROVE_DBPASS/$TROVE_MYSQL_PASS/g" config/trove.sql | mysql -u root -p$MYSQL_ROOT_PASSWD
	su -s /bin/sh -c "trove-manage db_sync" trove
	su -s /bin/sh -c "trove-manage datastore_update mysql ''" trove

	# download and convert image
	wget -O $IMAGE_DIR/ubuntu.img $UBUNTU_IMAGE_URL
	qemu-img convert -O qcow2 $IMAGE_DIR/ubuntu.img $IMAGE_DIR/ubuntu.qcow2

	# create the CloudInit config file
	sed -e "s/HOST_IP/$HOST_IP/g" -e "s/ADMIN_PASS/$ADMIN_PASS/g" -e "s|SSH_KEY|$(cat /root/.ssh/id_rsa.pub)|g" config/mysql.cloudinit > /etc/trove/cloudinit/mysql.cloudinit

	# upload the image to Glance
	glance image-create --name trove_mysql_ubuntu --file $IMAGE_DIR/ubuntu.qcow2 --property hypervisor_type=qemu --disk-format qcow2 --container-format bare --is-public True --owner trove | log_output image-create-trove-ubuntu
	UBUNTU_IMAGE_ID=$(get_field "image-create-trove-ubuntu" " id " 4)

	# create the mysql datastore
	trove-manage --config-file /etc/trove/trove.conf datastore_version_update mysql mysql-5.5 mysql $UBUNTU_IMAGE_ID mysql-server-5.5 1

	# create the Trove service and endpoint in Keystone
	keystone service-create --name=trove --type=database --description="OpenStack Database Service" | log_output service-create-trove
	TROVE_SERVICE_ID=$(get_field "service-create-trove" " id " 4)
	keystone endpoint-create --service-id=$TROVE_SERVICE_ID --publicurl=http://$HOST_IP:8779/v1.0/%\(tenant_id\)s --internalurl=http://$HOST_IP:8779/v1.0/%\(tenant_id\)s --adminurl=http://$HOST_IP:8779/v1.0/%\(tenant_id\)s --region RegionOne | log_output endpoint-create-trove

	# start services and add enable them on startup
	for i in api taskmanager conductor; do
		service openstack-trove-$i start
		chkconfig openstack-trove-$i on
	done

	etckeeper commit "Finished setting up Trove using script"
}

#
# Remove all configuration of Trove so configure_trove
# can start from scratch
#
function remove_configuration_trove {
	set -x
#       trap read debug

	# stop services and disable them on startup
	for i in api taskmanager conductor; do
		service openstack-trove-$i stop
		chkconfig openstack-trove-$i off
	done

	# delete Trove user, endpoint, service and tenant
	keystone user-delete trove
	ENDPOINT_ID=$(get_field "endpoint-create-trove" " id " 4)
	keystone endpoint-delete $ENDPOINT_ID
	keystone service-delete trove
	keystone tenant-delete trove

	# delete image
	glance image-delete trove_mysql_ubuntu

	# remove configuration files
	rm -rf /etc/trove/*

	# delete Trove service database and database user
	echo "DROP DATABASE trove" | mysql -u root -p$MYSQL_ROOT_PASSWD
	echo "DROP USER trove@'localhost'" | mysql -u root -p$MYSQL_ROOT_PASSWD
	echo "DROP USER trove@'%'" | mysql -u root -p$MYSQL_ROOT_PASSWD
	
	etckeeper commit "Finished removing Trove using script"
}

#
# Execute function the user passes
#
"$@"

