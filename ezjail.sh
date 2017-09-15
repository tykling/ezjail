#!/bin/sh
# $Id$
#
# $FreeBSD$
#
# PROVIDE: ezjail
# REQUIRE: LOGIN cleanvar sshd
# BEFORE: securelevel
# KEYWORD: nojail shutdown
#
# Add the following lines to /etc/rc.conf.local or /etc/rc.conf to enable ezjail
#
#ezjail_enable="YES"
#
# Please do not change this file, configure in EZJAIL_PREFIX/etc/ezjail.conf

# ugly: this variable is set on port install time
ezjail_prefix=EZJAIL_PREFIX

. /etc/rc.subr

name=ezjail
rcvar=${name}_enable
extra_commands="startcrypto stopcrypto"
load_rc_config ${name}

ezjail_enable=${ezjail_enable:-"NO"}

restart_cmd="do_cmd restart _"
start_cmd="do_cmd start '_ ezjail'"
stop_cmd="do_cmd stop '_ ezjail'"
startcrypto_cmd="do_cmd startcrypto _"
stopcrypto_cmd="do_cmd stopcrypto _"

do_cmd()
{
  action=$1; message=$2; shift 2;
  unset ezjail_list ezjail_pass ezjail_mds ezjail_stop
  ezjail_cfgs=${ezjail_prefix}/etc/ezjail/
  ezjail_fromrc="YES"

  case "${action}" in *stop) ezjail_stop="YES";; esac

  # If a jail list is given on command line, process it
  # If not, fetch it from our config directory
  if [ "$*" ]; then
    ezjail_list=`echo -n $* | tr -c '[:alnum:] ' '_'` 
    unset ezjail_fromrc
  else
    [ "${ezjail_stop}" ] && reverse_command="tail -r" || reverse_command="cat"
    [ -d "${ezjail_cfgs}" ] && cd "${ezjail_cfgs}" && ezjail_list=`ls | xargs rcorder | ${reverse_command}`
    echo -n "${message##_}"
  fi

  for ezjail in ${ezjail_list}; do
    unset ezjail_config ezjail_norun

    [ -e "${ezjail_cfgs}/${ezjail}"       ] && ezjail_config="${ezjail_cfgs}/${ezjail}"
    [ -e "${ezjail_cfgs}/${ezjail}.norun" ] && ezjail_config="${ezjail_cfgs}/${ezjail}.norun" && ezjail_norun="YES"

    # Check for jails config
    [ ! -f "${ezjail_config}" ] && echo " Warning: Jail ${ezjail} not found." && continue

    # If jail is temporary disabled (dot in name), skip it for starts
    [ "${ezjail_stop}" ] && ezjail="${ezjail%%.*}"
    [ "${ezjail%.*}" != "${ezjail}" -o "${ezjail_norun}" ] && echo -n " skipping ${ezjail}" && continue

    # Read config file
    . ${ezjail_config}

    eval ezjail_rootdir=\"\$jail_${ezjail}_rootdir\"
    eval ezjail_image=\"\$jail_${ezjail}_image\"
    eval ezjail_imagetype=\"\$jail_${ezjail}_imagetype\"
    eval ezjail_attachparams=\"\$jail_${ezjail}_attachparams\"
    eval ezjail_attachblocking=\"\$jail_${ezjail}_attachblocking\"
    eval ezjail_forceblocking=\"\$jail_${ezjail}_forceblocking\"

    # Fix backward compatibility issue
    eval ezjail_exec_start=\"\$jail_${ezjail}_exec_start\"
    eval ezjail_exec=\"\$jail_${ezjail}_exec\"
    eval jail_${ezjail}_exec_start=\"\${ezjail_exec_start:-${ezjail_exec}}\"
    eval unset jail_${ezjail}_exec

    # Do we still have a root to run in?
    [ ! -d "${ezjail_rootdir}" ] && echo " Warning: root directory ${ezjail_rootdir} of ${ezjail} does not exist." && continue

    [ "${ezjail_attachblocking}" -o "${ezjail_forceblocking}" ] && ezjail_blocking="YES" || unset ezjail_blocking

    # Cannot auto mount blocking jails without interrupting boot process
    [ "${ezjail_fromrc}" -a "${action}" = "start" -a "${ezjail_blocking}" ] && echo -n " ...skipping blocking jail ${ezjail}" && continue

    # Explicitly do only run blocking crypto jails when *crypto is requested
    [ "${action%crypto}" = "${action}" -o "${ezjail_blocking}" ] || continue

    # Try to attach (crypto) devices
    if [ "${ezjail_image}" ]; then
      attach_detach_pre || continue
    fi

    ezjail_pass="${ezjail_pass} ${ezjail}"
  done

  # Pass control to jail script which does the actual work
  [ "${ezjail_pass}" ] && sh /etc/rc.d/jail one${action%crypto} ${ezjail_pass}

  # Configure settings that need to be done after the jail has been started
  if [ "${action%crypto}" = "start" -o "${action}" = "restart" ]; then
    for ezjail in ${ezjail_pass}; do
      ezjail_safename=`echo -n "${ezjail}" | tr -c '[:alnum:]' _`
      # Get the JID of the jail
      [ -f "/var/run/jail_${ezjail_safename}.id" ] && ezjail_id=`cat /var/run/jail_${ezjail_safename}.id` || return

      eval ezjail_zfs_datasets=\"\$jail_${ezjail_safename}_zfs_datasets\"
      eval ezjail_cpuset=\"\$jail_${ezjail_safename}_cpuset\"
      eval ezjail_post_start_script=\"\$jail_${ezjail_safename}_post_start_script\"

      # Attach ZFS-datasets to the jail
      for zfs in ${ezjail_zfs_datasets}; do
        /sbin/zfs jail ${ezjail_id} ${zfs} || echo -n "Error: ${zfs} could not be configured"
      done

      # Mount any datasets that have become available in the jail
      /usr/sbin/jexec ${ezjail_id} /sbin/zfs mount -a

      # Configure processor sets for the jail via cpuset(1)
      [ -z "${ezjail_cpuset}" ] || /usr/bin/cpuset -l ${ezjail_cpuset} -j ${ezjail_id} || echo -n "Error: The defined cpuset is malformed"

      # Run post start script
      [ -z "${ezjail_post_start_script}" ] || "${ezjail_post_start_script}" ${ezjail_id} "${ezjail}" || echo -n "Error: Post Start Script failed"
    done
  fi

  # Can only detach after unmounting (from fstab.JAILNAME in /etc/rc.d/jail)
  attach_detach_post
}

attach_detach_pre ()
{
  case "${action%crypto}" in
  start|restart)
    # If jail is running, do not mount devices, this is the same check as
    # /etc/rc.d/jail does
    [ -e "/var/run/jail_${ezjail}.id" ] && return 0

    if [ -L "${ezjail_rootdir}.device" ]; then
      # Fetch destination of soft link
      ezjail_device=`stat -f "%Y" ${ezjail_rootdir}.device`

      mount -p -v | grep -E "^${ezjail_rootdir}.device.${ezjail_rootdir}" && echo "Warning: Skipping jail. Jail image file ${ezjail} already attached as ${ezjail_device}. 'ezjail-admin config -i detach' it first." && return 1
      mount -p -v | grep -E "^${ezjail_device}.${ezjail_rootdir}" && echo "Warning: Skipping jail. Jail image file ${ezjail} already attached as ${ezjail_device}. 'ezjail-admin config -i detach' it first." && return 1

      # Remove stale device link
      rm -f "${ezjail_rootdir}.device"
    fi

    # Create a memory disc from jail image
    ezjail_device=`mdconfig -a -t vnode -f ${ezjail_image}` || return 1

    # If this is a crypto jail, try to mount it, remind user, which jail
    # this is. In this case, the device to mount is 
    case ${ezjail_imagetype} in
    crypto|bde)
      echo "Attaching bde device for image jail ${ezjail}..."
      echo gbde attach "/dev/${ezjail_device}" ${ezjail_attachparams} | /bin/sh 
      if [ $? -ne 0 ]; then
        mdconfig -d -u "${ezjail_device}" > /dev/null
        echo "Error: Attaching bde device failed."; return 1
      fi
      # Device to mount is not md anymore
      ezjail_device="${ezjail_device}.bde"
      ;;
    eli)
      echo "Attaching eli device for image jail ${ezjail}..."
      echo geli attach ${ezjail_attachparams} "/dev/${ezjail_device}" | /bin/sh
      if [ $? -ne 0 ]; then
        mdconfig -d -u "${ezjail_device}" > /dev/null
        echo "Error: Attaching eli device failed."; return 1
      fi
      # Device to mount is not md anymore
      ezjail_device="${ezjail_device}.eli"
      ;;
    esac

    # Clean image
    fsck -t ufs -p -B "/dev/${ezjail_device}"

    # relink image device
    rm -f "${ezjail_rootdir}.device"
    ln -s "/dev/${ezjail_device}" "${ezjail_rootdir}.device"
  ;;
  stop)
    # If jail is not running, do not unmount devices, this is the same check
    # as /etc/rc.d/jail does
    [ -e "/var/run/jail_${ezjail}.id" ] || return 1

    # If soft link to device is not set, we cannot unmount
    [ -e "${ezjail_rootdir}.device" ] || return

    # Fetch destination of soft link
    ezjail_device=`stat -f "%Y" "${ezjail_rootdir}.device"`

    # Add this device to the list of devices to be unmounted
    case ${ezjail_imagetype} in
      crypto|bde) ezjail_mds="${ezjail_mds} ${ezjail_device%.bde}" ;;
      eli) ezjail_mds="${ezjail_mds} ${ezjail_device%.eli}" ;;
      simple) ezjail_mds="${ezjail_mds} ${ezjail_device}" ;;
    esac

    # Remove soft link (which acts as a lock)
    rm -f "${ezjail_rootdir}.device"
  ;;
  esac
}

attach_detach_post () {
  # In case of a stop, unmount image devices after stopping jails
  for md in ${ezjail_mds}; do
    [ -e "${md}.bde" ] && gbde detach "${md}"
    [ -e "${md}.eli" ] && geli detach "${md}"
    mdconfig -d -u "${md#/dev/}"
  done
}

run_rc_command $*
