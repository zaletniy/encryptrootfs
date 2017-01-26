#!/bin/sh
PATH=$PATH:/sbin:/usr/sbin
# update /etc/resolv.conf based on received values
make_resolv_conf() {
    local new_resolv_conf

    # DHCPv4
    if [ -n "$new_domain_search" ] || [ -n "$new_domain_name" ] ||
       [ -n "$new_domain_name_servers" ]; then
        resolv_conf=$(readlink -f "/etc/resolv.conf" 2>/dev/null) ||
            resolv_conf="/etc/resolv.conf"

        new_resolv_conf="${resolv_conf}.dhclient-new.$$"
        rm -f $new_resolv_conf

        if [ -n "$new_domain_name" ]; then
            echo domain ${new_domain_name%% *} >>$new_resolv_conf
        fi

        if [ -n "$new_domain_search" ]; then
            if [ -n "$new_domain_name" ]; then
                domain_in_search_list=""
                for domain in $new_domain_search; do
                    if [ "$domain" = "${new_domain_name}" ] ||
                       [ "$domain" = "${new_domain_name}." ]; then
                        domain_in_search_list="Yes"
                    fi
                done
                if [ -z "$domain_in_search_list" ]; then
                    new_domain_search="$new_domain_name $new_domain_search"
                fi
            fi
            echo "search ${new_domain_search}" >> $new_resolv_conf
        elif [ -n "$new_domain_name" ]; then
            echo "search ${new_domain_name}" >> $new_resolv_conf
        fi

        if [ -n "$new_domain_name_servers" ]; then
            for nameserver in $new_domain_name_servers; do
                echo nameserver $nameserver >>$new_resolv_conf
            done
        else # keep 'old' nameservers
            sed -n /^\w*[Nn][Aa][Mm][Ee][Ss][Ee][Rr][Vv][Ee][Rr]/p $resolv_conf >>$new_resolv_conf
        fi

	if [ -f $resolv_conf ]; then
	    chown --reference=$resolv_conf $new_resolv_conf
	    chmod --reference=$resolv_conf $new_resolv_conf
	fi
        mv -f $new_resolv_conf $resolv_conf
    # DHCPv6
    elif [ -n "$new_dhcp6_domain_search" ] || [ -n "$new_dhcp6_name_servers" ]; then
        resolv_conf=$(readlink -f "/etc/resolv.conf" 2>/dev/null) ||
            resolv_conf="/etc/resolv.conf"

        new_resolv_conf="${resolv_conf}.dhclient-new.$$"
        rm -f $new_resolv_conf

        if [ -n "$new_dhcp6_domain_search" ]; then
            echo "search ${new_dhcp6_domain_search}" >> $new_resolv_conf
        fi

        if [ -n "$new_dhcp6_name_servers" ]; then
            for nameserver in $new_dhcp6_name_servers; do
                # append %interface to link-local-address nameservers
                if [ "${nameserver##fe80::}" != "$nameserver" ] ||
                   [ "${nameserver##FE80::}" != "$nameserver" ]; then
                    nameserver="${nameserver}%${interface}"
                fi
                echo nameserver $nameserver >>$new_resolv_conf
            done
        else # keep 'old' nameservers
            sed -n /^\w*[Nn][Aa][Mm][Ee][Ss][Ee][Rr][Vv][Ee][Rr]/p $resolv_conf >>$new_resolv_conf
        fi

	if [ -f $resolv_conf ]; then
            chown --reference=$resolv_conf $new_resolv_conf
            chmod --reference=$resolv_conf $new_resolv_conf
	fi
        mv -f $new_resolv_conf $resolv_conf
    fi
}

# Execute the operation
case "$reason" in

    ### DHCPv4 Handlers

    MEDIUM|ARPCHECK|ARPSEND)
        # Do nothing
        ;;
    PREINIT)
        # The DHCP client is requesting that an interface be
        # configured as required in order to send packets prior to
        # receiving an actual address. - dhclient-script(8)

        # ensure interface is up
        ip link set dev ${interface} up

        if [ -n "$alias_ip_address" ]; then
            # flush alias IP from interface
            ip -4 addr flush dev ${interface} label ${interface}:0
        fi

        ;;

    BOUND|RENEW|REBIND|REBOOT)
        if [ -n "$old_ip_address" ] && [ -n "$alias_ip_address" ] &&
           [ "$alias_ip_address" != "$old_ip_address" ]; then
            # alias IP may have changed => flush it
            ip -4 addr flush dev ${interface} label ${interface}:0
        fi

        if [ -n "$old_ip_address" ] &&
           [ "$old_ip_address" != "$new_ip_address" ]; then
            # leased IP has changed => flush it
            ip -4 addr flush dev ${interface} label ${interface}
        fi

        if [ -z "$old_ip_address" ] ||
           [ "$old_ip_address" != "$new_ip_address" ] ||
           [ "$reason" = "BOUND" ] || [ "$reason" = "REBOOT" ]; then
            # new IP has been leased or leased IP changed => set it
            ip -4 addr add ${new_ip_address}${new_subnet_mask:+/$new_subnet_mask} \
                ${new_broadcast_address:+broadcast $new_broadcast_address} \
                dev ${interface} label ${interface}

            if [ -n "$new_interface_mtu" ]; then
                # set MTU
                ip link set dev ${interface} mtu ${new_interface_mtu}
            fi

	    # if we have $new_rfc3442_classless_static_routes then we have to
	    # ignore $new_routers entirely
	    if [ ! "$new_rfc3442_classless_static_routers" ]; then
		    # set if_metric if IF_METRIC is set or there's more than one router
		    if_metric="$IF_METRIC"
		    if [ "${new_routers%% *}" != "${new_routers}" ]; then
			if_metric=${if_metric:-1}
		    fi

		    for router in $new_routers; do
			if [ "$new_subnet_mask" = "255.255.255.255" ]; then
			    # point-to-point connection => set explicit route
			    ip -4 route add ${router} dev $interface >/dev/null 2>&1
			fi

			# set default route
			ip -4 route add default via ${router} dev ${interface} \
			    ${if_metric:+metric $if_metric} >/dev/null 2>&1

			if [ -n "$if_metric" ]; then
			    if_metric=$((if_metric+1))
			fi
		    done
	    fi
        fi

        if [ -n "$alias_ip_address" ] &&
           [ "$new_ip_address" != "$alias_ip_address" ]; then
            # separate alias IP given, which may have changed
            # => flush it, set it & add host route to it
            ip -4 addr flush dev ${interface} label ${interface}:0
            ip -4 addr add ${alias_ip_address}${alias_subnet_mask:+/$alias_subnet_mask} \
                dev ${interface} label ${interface}:0
            ip -4 route add ${alias_ip_address} dev ${interface} >/dev/null 2>&1
        fi

        # update /etc/resolv.conf
        make_resolv_conf

        ;;

    EXPIRE|FAIL|RELEASE|STOP)
        if [ -n "$alias_ip_address" ]; then
            # flush alias IP
            ip -4 addr flush dev ${interface} label ${interface}:0
        fi

        if [ -n "$old_ip_address" ]; then
            # flush leased IP
            ip -4 addr flush dev ${interface} label ${interface}
        fi

        if [ -n "$alias_ip_address" ]; then
            # alias IP given => set it & add host route to it
            ip -4 addr add ${alias_ip_address}${alias_network_arg} \
                dev ${interface} label ${interface}:0
            ip -4 route add ${alias_ip_address} dev ${interface} >/dev/null 2>&1
        fi

        ;;

    TIMEOUT)
        if [ -n "$alias_ip_address" ]; then
            # flush alias IP
            ip -4 addr flush dev ${interface} label ${interface}:0
        fi

        # set IP from recorded lease
        ip -4 addr add ${new_ip_address}${new_subnet_mask:+/$new_subnet_mask} \
            ${new_broadcast_address:+broadcast $new_broadcast_address} \
            dev ${interface} label ${interface}

        if [ -n "$new_interface_mtu" ]; then
            # set MTU
            ip link set dev ${interface} mtu ${new_interface_mtu}
        fi

        # if there is no router recorded in the lease or the 1st router answers pings
        if [ -z "$new_routers" ] || ping -q -c 1 "${new_routers%% *}"; then
	    # if we have $new_rfc3442_classless_static_routes then we have to
	    # ignore $new_routers entirely
	    if [ ! "$new_rfc3442_classless_static_routes" ]; then
		    if [ -n "$alias_ip_address" ] &&
		       [ "$new_ip_address" != "$alias_ip_address" ]; then
			# separate alias IP given => set up the alias IP & add host route to it
			ip -4 addr add ${alias_ip_address}${alias_subnet_mask:+/$alias_subnet_mask} \
			    dev ${interface} label ${interface}:0
			ip -4 route add ${alias_ip_address} dev ${interface} >/dev/null 2>&1
		    fi

		    # set if_metric if IF_METRIC is set or there's more than one router
		    if_metric="$IF_METRIC"
		    if [ "${new_routers%% *}" != "${new_routers}" ]; then
			if_metric=${if_metric:-1}
		    fi

		    # set default route
		    for router in $new_routers; do
			ip -4 route add default via ${router} dev ${interface} \
			    ${if_metric:+metric $if_metric} >/dev/null 2>&1

			if [ -n "$if_metric" ]; then
			    if_metric=$((if_metric+1))
			fi
		    done
	    fi

            # update /etc/resolv.conf
            make_resolv_conf
        else
            # flush all IPs from interface
            ip -4 addr flush dev ${interface}
        fi

        ;;
esac
exit 0