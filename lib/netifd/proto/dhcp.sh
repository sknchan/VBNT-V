#!/bin/sh

. /lib/functions.sh
. ../netifd-proto.sh
init_proto "$@"

proto_dhcp_init_config() {
	renew_handler=1

	proto_config_add_string 'ipaddr:ipaddr'
	proto_config_add_string 'hostname:hostname'
	proto_config_add_string clientid
	proto_config_add_string vendorid
	proto_config_add_boolean 'broadcast:bool'
	proto_config_add_boolean 'release:bool'
	proto_config_add_string 'reqopts:list(string)'
	proto_config_add_string iface6rd
	proto_config_add_string sendopts
	proto_config_add_boolean delegate
	proto_config_add_string zone6rd
	proto_config_add_string zone
	proto_config_add_string mtu6rd
	proto_config_add_string customroutes
	proto_config_add_boolean 'arping:bool'
	proto_config_add_boolean 'initboot:bool'
	proto_config_add_boolean 'vendorinfolenfix:bool'
	proto_config_add_boolean classlessroute
}

proto_dhcp_setup() {
	local config="$1"
	local iface="$2"

	local ipaddr hostname clientid vendorid broadcast release reqopts iface6rd sendopts delegate zone6rd zone mtu6rd customroutes arping initboot vendorinfolenfix classlessroute
	json_get_vars ipaddr hostname clientid vendorid broadcast release reqopts iface6rd sendopts delegate zone6rd zone mtu6rd customroutes arping initboot vendorinfolenfix classlessroute

	local opt dhcpopts
	for opt in $reqopts; do
		append dhcpopts "-O $opt"
	done

	for opt in $sendopts; do
		append dhcpopts "-x $opt"
	done

	[ -z "$hostname" ] && hostname="$(cat /proc/sys/kernel/hostname)"
	[ "$broadcast" = 1 ] && broadcast="-B" || broadcast=
	[ "$release" = 1 ] && release="-R" || release=
	[ -n "$clientid" ] && clientid="-x 0x3d:${clientid//:/}" || clientid="-C"
	[ -n "$iface6rd" ] && proto_export "IFACE6RD=$iface6rd"
	[ "$iface6rd" != 0 -a -f /lib/netifd/proto/6rd.sh ] && append dhcpopts "-O 212"
	[ -n "$zone6rd" ] && proto_export "ZONE6RD=$zone6rd"
	[ -n "$zone" ] && proto_export "ZONE=$zone"
	[ -n "$mtu6rd" ] && proto_export "MTU6RD=$mtu6rd"
	[ -n "$customroutes" ] && proto_export "CUSTOMROUTES=$customroutes"
	[ "$delegate" = "0" ] && proto_export "IFACE6RD_DELEGATE=0"
	[ "$arping" = 1 ] && arping="-a" || arping=
	[ "$initboot" = 1 ] && initboot="-I /etc/udhcpc-$iface.ip" || initboot=
	[ "$vendorinfolenfix" = 1 ] && vendorinfolenfix="-l" || vendorinfolenfix=
	# Request classless route option (see RFC 3442) by default
	[ "$classlessroute" = "0" ] || append dhcpopts "-O 121"

	proto_export "INTERFACE=$config"
	proto_run_command "$config" odhcpc \
		-p /var/run/odhcpc-$iface.pid \
		-s /lib/netifd/dhcp.script \
		-f -o -t 0 -i "$iface" \
		${ipaddr:+-r $ipaddr} \
		${hostname:+-x "hostname:$hostname"} \
		${vendorid:+-V "$vendorid"} \
		$clientid $broadcast $release $dhcpopts $arping $initboot $vendorinfolenfix
}

proto_dhcp_renew() {
	local interface="$1"
	# SIGUSR1 forces udhcpc to renew its lease
	local sigusr1="$(kill -l SIGUSR1)"
	[ -n "$sigusr1" ] && proto_kill_command "$interface" $sigusr1
}

proto_dhcp_teardown() {
	local interface="$1"
	proto_kill_command "$interface"
}

add_protocol dhcp
