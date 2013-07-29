#!/bin/bash
#
# Author: kattunga
# Date: August 11, 2012
# Version: 2.0
#
# http://linuxzfs.blogspot.com/2012/08/zfs-replication-script.html
# https://github.com/kattunga/zfs-scripts.git
#
# Credits: 
#    Mike La Spina for the original concept and script http://blog.laspina.ca/
#  
# Function:
#    Provides snapshot and send process which replicates a ZFS dataset from a source to target server.
#    Maintains a runing snapshot archive for X time
#

#######################################################################################
# email configuration. Install package mailutils, ssmtp and configure /etc/ssmtp/ssmtp.conf
#######################################################################################

mail_from=
mail_to=
mail_subject=

#######################################################################################
##################### Do not touch anything below this line ###########################
#######################################################################################

show_help() {
	echo "-h target user@host"
	echo "-p target ssh port"
	echo "-s source zfs dataset"
	echo "-d target zfs dataset (default = source)"
	echo "-f snapshot prefix"
	echo "-t max time to preserve snapshots"
	echo '   eg. "7 days ago", "12 hours ago", "10 minutes ago", (default infinite)'
	echo "-v verbose"
	echo "-c clean snapshots in target that are not in source"
	echo "-k compare source and target with checksum using rsync"
	echo "-n do no snapshot"
	echo "-r do no replicate"
	echo "-z create target filesystem if needed"
	echo "-D use deduplication"
	echo "-o replication protocol"
	echo "   SSH (remote networks)"
	echo "   SSHGZIP (remote networks, low bandwith)"
	echo "   NETCAT (use port 8023)"
	echo "   SOCAT (use port 8023)"
	echo "   NETSOCAT (recomended, netcat in server / socat in client, use port 8023)"
	echo "   netcat requires package netcat-traditional, netcat-openbsd is not supported"
	echo "-l compression level 1..9 (default 6)"
	exit
}

# parse parameters
TGT_HOST=
TGT_PORT=
SRC_PATH=
TGT_PATH=
SNP_PREF=
MAX_TIME=
VERBOSE=
CLEAN=false
COMPARE=false
SNAPSHOT=true
REPLICATE=true
SENDMAIL=false
CREATEFS=false
PROTOCOL="SSH"
ZIPLEVEL=6
DEDUP=

while getopts “h:p:s:d:f:t:o:l:vcknrmzD?” OPTION
do
     case $OPTION in
         h)
             TGT_HOST=$OPTARG
             ;;
         p)
             TGT_PORT="-p$OPTARG"
             ;;
         s)
             SRC_PATH=$OPTARG
             ;;
         d)
             TGT_PATH=$OPTARG
             ;;
         f)
             SNP_PREF=$OPTARG
             ;;
         t)
             MAX_TIME=$OPTARG
             ;;
         o)
             PROTOCOL=$OPTARG
             ;;
         l)
             ZIPLEVEL=$OPTARG
             ;;
         v)
             VERBOSE=-v
             ;;
         c)
             CLEAN=true
             ;;
         k)
             COMPARE=true
             ;;
         n)
             SNAPSHOT=false
             ;;
         r)
             REPLICATE=false
             ;;
         m)
             SENDMAIL=true
             ;;
         z)
             CREATEFS=true
             ;;
         D)
             DEDUP="-D"
             ;;
         ?)
             show_help
             ;;
     esac
done

# flag file to avoid concurrent replication
FLG_FILE=$0.flg

# Check if no current replication is running
if [ -e "$FLG_FILE" ]; then
	echo "-> ERROR, replication is currently running"
	exit
fi

#######################################################################################
####################################Function###########################################
#######################################################################################
#
# end script
#

end_script() {

	# delete control flag
	if [ -e "$FLG_FILE" ]; then
		rm $FLG_FILE
	fi

	echo $(date) "End ------------------------------------------------------------"
	exit
}

#######################################################################################
####################################Function###########################################
#######################################################################################
#
# check if error was logged
#

check_for_error() {

	if [ -s "$0.err" ]; then
		echo $(date) $(cat $0.err)
		if [ $SENDMAIL == true ]
		then
			mail -a "From: $mail_from" -s "$mail_subject" $mail_to < $0.err
		fi
		end_script
	fi
}

#######################################################################################
####################################Function###########################################
#######################################################################################
#
# log error and send mail
#

log_error() {

	echo $1 > $0.err
	check_for_error
}

#######################################################################################
####################################Function###########################################
#######################################################################################
#
# Function Issue a snapshot for the source zfs path
#

create_fs_snap() {

	SnapName="$SNP_PREF$(date +%Y%m%d%H%M%S)"
	echo $(date) "-> $SRC_PATH@$SnapName Snapshot creation."
	zfs snapshot $SRC_PATH\@$SnapName 2> $0.err
	check_for_error
}

#######################################################################################
####################################Function###########################################
#######################################################################################
#
# Function check if the destination zfs path exists and assign the result to the
# variable target_fs_name.
#

target_fs_exists() {

	target_fs_name=$(ssh -n $TGT_HOST $TGT_PORT zfs list -o name -H $TGT_PATH 2> $0.err | tail -1 )
	if [ -s "$0.err" ]
	then
		path_error=$(grep "$TGT_PATH" $0.err)
		if [ "$path_error" == "" ]
		then
			check_for_error
		else
			rm $0.err
			echo $(date) "-> $TGT_PATH file system does not exist on target host $TGT_HOST."
		fi
	fi
	
}

#######################################################################################
####################################Function###########################################
#######################################################################################
#
# Function issue zfs list commands and assign the variables the last snapshot names for
# both the source and destination hosts.
#

check_last_source_snap() {

	last_snap_source=$( zfs list -o name -t snapshot -H 2> $0.err | grep $SRC_PATH\@ | tail -1 )
	check_for_error
	if [ "$last_snap_source" == "" ]
	then
		log_error "There is no snapshots in source filesystem $SRC_PATH"
	fi

}

#######################################################################################
####################################Function###########################################
#######################################################################################
#
# Function issue zfs list commands and assign the variables the last snapshot names for
# both the source and destination hosts.
#

check_last_target_snap() {

	last_snap_target=$( ssh -n $TGT_HOST $TGT_PORT zfs list -H -o name -r -t snapshot 2> $0.err | grep $TGT_PATH\@ | tail -1 )
	check_for_error
	if [ "$last_snap_target" == "" ]
	then
		log_error "There is no snapshots in target filesystem $TGT_PATH"
	fi
}

#######################################################################################
####################################Function###########################################
#######################################################################################
#
# Function create a zfs path on the destination to allow the receive command
# funtionallity then issue zfs snap and send to transfer the zfs object to the 
# destination host
#

target_fs_create() {

	check_last_source_snap 
	echo $(date) "-> $last_snap_source Initial replication."

	ssh -n $TGT_HOST $TGT_PORT zfs create -p $TGT_PATH 2> $0.err
	check_for_error
	ssh -n $TGT_HOST $TGT_PORT zfs set mountpoint=none $TGT_PATH 2> $0.err
	check_for_error
	if [ $DEDUP == "-D" ]
	then
		ssh -n $TGT_HOST $TGT_PORT zfs set dedup=on $TGT_PATH 2> $0.err
		check_for_error
	fi

	# using ssh (for remote networks)
	if [ "$PROTOCOL" == "SSH" ]
	then
		zfs send $DEDUP -R $last_snap_source | ssh -c blowfish $TGT_HOST $TGT_PORT zfs recv $VERBOSE -F $TGT_PATH 2> $0.err
	fi
	# using ssh with compression (for slow remote networks)
	if [ "$PROTOCOL" == "SSHGZIP" ]
	then
		zfs send $DEDUP -R $last_snap_source | gzip $ZIPLEVEL -c | ssh -c blowfish $TGT_HOST $TGT_PORT "zcat | zfs recv $VERBOSE -F $TGT_PATH" 2> $0.err
	fi
	# using netcat (local network) requires "netcat-traditional", must uninstall "netcat-openbds"
	if [ "$PROTOCOL" == "NETCAT" ]
	then
		ssh -n -f $TGT_HOST $TGT_PORT "nc -w 1 -l -p 8023 | zfs recv $VERBOSE -F $TGT_PATH"
		sleep 1
		zfs send $DEDUP -R $last_snap_source | nc $TGT_HOST 8023
	fi
	# using socat (local network)
	if [ "$PROTOCOL" == "SOCAT" ]
	then
		zfs send $DEDUP -R $last_snap_source | socat - tcp4:$TGT_HOST:8023,retry=5 &
		ssh -n $TGT_HOST $TGT_PORT "socat tcp4-listen:8023 - | zfs recv $VERBOSE -F $TGT_PATH" 2> $0.err
	fi
	# using netcat in server and socat in client, recomended, requires "netcat-traditional", must uninstall "netcat-openbds"
	if [ "$PROTOCOL" == "NETSOCAT" ] 
	then
		zfs send $DEDUP -R $last_snap_source | socat - tcp4:$TGT_HOST:8023,retry=5 &
		ssh -n $TGT_HOST $TGT_PORT "nc -w 1 -l -p 8023 | zfs recv $VERBOSE -F $TGT_PATH" 2> $0.err
	fi

	check_for_error
}

#######################################################################################
####################################Function###########################################
#######################################################################################
#
# Function create a zfs send/recv command set based on a the zfs path source 
# and target hosts for an established replication state. (aka incremental replication)
#

incr_repl_fs() {

	check_last_source_snap  

	check_last_target_snap 
	stringpos=0
	let stringpos=$(expr index "$last_snap_target" @)
	last_snap_target=$SRC_PATH@${last_snap_target:$stringpos}

	echo $(date) "-> $last_snap_target $last_snap_source Incremental send."

	# using ssh (for remote networks)
	if [ "$PROTOCOL" == "SSH" ]
	then
		zfs send $DEDUP -I $last_snap_target $last_snap_source | ssh -c blowfish $TGT_HOST $TGT_PORT zfs recv $VERBOSE -F $TGT_PATH 2> $0.err
	fi
	# using ssh with compression (for slow remote networks)
	if [ "$PROTOCOL" == "SSHGZIP" ]
	then
		zfs send $DEDUP -I $last_snap_target $last_snap_source | gzip -1 -c | ssh -c blowfish $TGT_HOST $TGT_PORT "zcat | zfs recv $VERBOSE -F $TGT_PATH" 2> $0.err
	fi
	# using netcat (local network) requires "netcat-traditional", must uninstall "netcat-openbds"
	if [ "$PROTOCOL" == "NETCAT" ]
	then
		ssh -f -n $TGT_HOST $TGT_PORT "nc -w 1 -l -p 8023 | zfs recv $VERBOSE -F $TGT_PATH"
		sleep 1
		zfs send $DEDUP -I $last_snap_target $last_snap_source | nc $TGT_HOST 8023 2> $0.err
	fi
	# using socat (local network)
	if [ "$PROTOCOL" == "SOCAT" ]
	then
		zfs send $DEDUP -I $last_snap_target $last_snap_source | socat - tcp4:$TGT_HOST:8023,retry=5 &
		ssh -n $TGT_HOST $TGT_PORT "socat tcp4-listen:8023 - | zfs recv $VERBOSE -F $TGT_PATH" 2> $0.err
	fi
	# using netcat in server and socat in client, recomended, requires "netcat-traditional", must uninstall "netcat-openbds"
	if [ "$PROTOCOL" == "NETSOCAT" ] 
	then
		zfs send $DEDUP -I $last_snap_target $last_snap_source | socat - tcp4:$TGT_HOST:8023,retry=5 &
		ssh -n $TGT_HOST $TGT_PORT "nc -w 1 -l -p 8023 | zfs recv $VERBOSE -F $TGT_PATH" 2> $0.err
	fi

	check_for_error
}

#######################################################################################
####################################Function###########################################
#######################################################################################
#
# Function to clean up snapshots that are in target host but not in source
#

clean_remote_snaps() {

	ssnap_list=$(zfs list -H -o name -t snapshot | grep  $SRC_PATH\@)

	dsnap_list="snaplist-target.lst"
	ssh -n $TGT_HOST $TGT_PORT zfs list -H -o name -t snapshot | grep $TGT_PATH\@ > $dsnap_list

	while read dsnaps
	do

		stringpos=0
		let stringpos=$(expr index "$dsnaps" @)
		SnapName=${dsnaps:$stringpos}

		ssnaps=$(echo $ssnap_list | grep $SRC_PATH\@$SnapName)

		if [ "$ssnaps" = "" ]
		then
			echo $(date) "-> Destroying snapshot $dsnaps on $TGT_HOST"
			ssh -n $TGT_HOST $TGT_PORT zfs destroy $dsnaps
		fi

	done < $dsnap_list

	rm $dsnap_list
}

#######################################################################################
####################################Function###########################################
#######################################################################################
#
# Function to clean up snapshots that are older than X days old X being the 
# value set by "MAX_TIME" on both the source and destination hosts.
# the last snapshot should not be deleted, at least one snapshot must be keeped
#

clean_old_snaps() {

	check_last_source_snap  

	snap_list="snaplist.lst"
	zfs list -o name -t snapshot | grep  $SRC_PATH\@$SNP_PREF > $snap_list

	while read snaps
	do

	if [ "$last_snap_source" != $snaps ]
	then
		stringpos=0
		let stringpos=$(expr index "$snaps" @)+${#SNP_PREF}
		let SnapDateTime=${snaps:$stringpos}

		if [ $(date +%Y%m%d%H%M%S --date="$MAX_TIME") -gt $SnapDateTime ]
		then
			echo $(date) "-> Destroying snapshot $snaps on localhost"
			zfs destroy $snaps
			if [ $REPLICATE == true ]
			then
				echo $(date) "-> Destroying snapshot $TGT_PATH@$SNP_PREF$SnapDateTime on $TGT_HOST"
				ssh -n $TGT_HOST $TGT_PORT -n zfs destroy $TGT_PATH\@$SNP_PREF$SnapDateTime
			fi
		fi
	fi

	done < $snap_list
	rm $snap_list
}

#######################################################################################
####################################Function###########################################
#######################################################################################
#
# Function to compare filesystems with checksum
#

compare_filesystems() {

	check_last_source_snap
	stringpos=0
	let stringpos=$(expr index "$last_snap_source" @)
	source_snap_path=$(zfs get -H -o value mountpoint $SRC_PATH)/.zfs/snapshot/${last_snap_source:$stringpos}

	check_last_target_snap  
	stringpos=0
	let stringpos=$(expr index "$last_snap_target" @)
	target_snap_path=$(ssh -n $TGT_HOST $TGT_PORT zfs get -H -o value mountpoint $TGT_PATH)/.zfs/snapshot/${last_snap_target:$stringpos}


	echo $(date) "-> comparing $source_snap_path to $TGT_HOST:$target_snap_path"
	rm $0.stats
	rsync -e "ssh $TGT_PORT" --recursive --checksum --dry-run --compress --stats --quiet --log-file-format="" --log-file=$0.stats $source_snap_path/ $TGT_HOST:$target_snap_path/ 2> $0.err
	check_for_error

	file_stat="files transferred:"
	file_difs=$(grep "$file_stat" $0.stats)
	let stringpos=$(awk -v a="$file_difs" -v b="$file_stat" 'BEGIN{print index(a,b)}')+${#file_stat}
	file_difs=${file_difs:$stringpos}
	if [ $file_difs != '0' ]
	then
		log_error "error comparing source and target filesystem"
	fi
}

#######################################################################################
#####################################Main Entery#######################################
#######################################################################################

# check and complete parameters
if [ "$SRC_PATH" == "" ]
then
	echo "Missing parameter source path -s"
	show_help
fi
if [[ ($REPLICATE == true) || ($COMPARE == true) ]]
then
	if [ "$TGT_HOST" == "" ]
	then
		echo "Missing parameter target host -h"
		show_help
	fi
	if [ "$TGT_PATH" == "" ]
	then
		TGT_PATH=$SRC_PATH
	fi
	if [[ ("$PROTOCOL" != "SSH") && ("$PROTOCOL" != "SSHGZIP") && ("$PROTOCOL" != "NETCAT")  && ("$PROTOCOL" != "SOCAT")  && ("$PROTOCOL" != "NETSOCAT") ]]
	then
		echo "incorrect protocol -o $PROTOCOL"
		show_help
	fi
fi

# delete .err file
if [ -e "$0.err" ]; then
	rm $0.err
fi

# set the control flag
touch $FLG_FILE

#Create a new snapshot of the path spec.
if [ $SNAPSHOT == true ]
then
	create_fs_snap
fi

# Send the snapshots to the remote and create the fs if required
if [ $REPLICATE == true ]
then
	# Test for the existence of zfs file system path on the target host.
	target_fs_exists

	if [ "$target_fs_name" == "" ]
	then

		# Create a first time replication.
		if [ $CREATEFS == true ]
		then
			target_fs_create
		else
			echo $(date) "-> use option -z to create file system in target host"
		fi

	else

		# Clean up any snapshots in target that is not source
		if [ $CLEAN == true ]
		then
			clean_remote_snaps 2> $0.err
			check_for_error
		fi

		# Initiate a dif replication.
		incr_repl_fs 2> $0.err
		check_for_error

		# Clean up any snapshots that are old.
		if [ "$MAX_TIME" != "" ]
		then
			clean_old_snaps 2> $0.err
			check_for_error
		fi
	fi
else
	# Clean up any snapshots that are old.
	if [ "$MAX_TIME" != "" ]
	then
		clean_old_snaps 2> $0.err
		check_for_error
	fi
fi

# compare filesystems with checksum
if [ $COMPARE == true ]
then
	compare_filesystems
fi

# clean flag file an end script
end_script

exit 0
