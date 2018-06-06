#!/bin/sh

# SolusVM to OnApp Cloud migration script
# Version 0.91 (Beta)
# Paul Morris - paul@onapp.com

f_List () {
    if [ `xm list | grep -v Domain-0 | grep -v Name | wc -l` -eq 0 ]; then
        echo -e "\n - No virtual machines are currently running on this hypervisor\n"
    else
        echo -e "\nListing all virtual machines"
        xm list | grep -v Domain-0 | awk '{print " -\t"$1"\t"$2 }'
        echo -ne "\n"
    fi
}

f_TemplateList () {
    IDLIST=( `curl -X GET -u ${USER}:${PASS} --url https://${HOST}/templates.json --insecure 2>/dev/null \
        | sed -e 's/[{}]/''/g' | awk -v RS=',"' -F: '/^id/ {print $2}'` )

    TPLIST=( `curl -X GET -u ${USER}:${PASS} --url https://${HOST}/templates.json --insecure 2>/dev/null \
        | sed -e 's/[{}]/''/g' | awk -v RS=',"' -F: '/^file_name/ {print $2}' | sed 's/\(^"\|"$\)//g'` )

    if [ $? -eq 1 ]; then
        echo "Error, API call failed"
	exit 1;
    else
        echo -ne "\nid\ttemplate\n\n"
        for (( i = 0 ; i < ${#IDLIST[@]} ; i++ )) do
            echo -ne "${IDLIST[${i}]}\t${TPLIST[${i}]}\n"
        done
    fi
}

f_ExportDiskToFile () {
    # Export disk image to file in /var/export  using dd
    # IN:  Raw disk image name / location root
    # OUT: Standard return code

    LOCATION="/${2}/export"
    DD=`which dd`
    if [ ! -e ${LOCATION} ]; then
	mkdir -p ${LOCATION}
    fi

    # Identify the volume group and logical volume name 
    VG=`echo ${1} | cut -d/ -f 3`
    LV=`echo ${1} | cut -d/ -f 4`

    # Activate the logical volume if necessary
    if ! lvs --noheadings -o lv_attr ${VG}/${LV} | grep a; then
        lvchange -ay ${VG}/${LV} &>/dev/null
        if [ $? -eq "1" ]; then
	    return 1;
	fi
    fi

    if ! lvs --noheadings -o lv_attr ${VG}/${LV} | grep o; then
	if ${DD} if=${1} of=${LOCATION}/${LV}; then
            return 0;
        else
	    echo " X---- Error, the logical volume is still open, did the virtual machine shutdown correctly?"
            return 1;
        fi
    else
	return 1;
    fi
}

f_ExportOne () {
    BOLD=`tput bold`
    NORMAL=`tput sgr0`
    SSH="ssh -p ${SSHPORT}"

    echo " - Exporting virtual machine with identifier ${VMID}"

    if [ "${SSHPORT}" != "22" ]; then
	echo " - Using custom SSH port ${SSHPORT}"
    fi

    # The virtual machine must be running for us to query xenstore
    if ! xm list | awk '{print $2}' | grep -x ${VMID} &>/dev/null; then
	echo " - Error, the virtual machine is either not running or does not exist."    
        exit 1;
    else
	echo "${BOLD} ** (Starting the export process)${NORMAL}"
    fi

    echo " --- Identifying virtual machine disks for export"
    VBDL="/local/domain/${VMID}/device/vbd"
    DISKCOUNT="0"
    SWAPCOUNT="0"
    for i in `xenstore-list ${VBDL}`; do
        BEID=`xenstore-read ${VBDL}/${i}/backend`
        if ! file -s `xenstore-read ${BEID}/params` | grep swap &>/dev/null; then
	    REALNAME=`xenstore-read ${BEID}/params`
	    DISKCOUNT=`expr ${DISKCOUNT} + 1`
        else
            echo " |---- Ignoring swap disk `xenstore-read ${BEID}/params`, we will rebuild this later"
	    SWAPCOUNT=`expr ${SWAPCOUNT} + 1`
        fi
    done
    if [ -z ${REALNAME} ]; then
	    echo " X---- Failed to find any disks for virtual machine"
	    exit 1;
    fi
    # Check for multiple disks (A little too complicated at this stage)
    if [ ${DISKCOUNT} -gt "1" ]; then
	echo " X---- Error, your virtual machine has multiple disks, this is not supported at this stage" 
	exit 1;
    fi

    # Find the size of the existing xen VBDs (Returns MB)
    echo " --- Identifying the size of existing disks"
    VBDL="/local/domain/${VMID}/device/vbd"
    for i in `xenstore-list ${VBDL}`; do
        BEID=`xenstore-read ${VBDL}/${i}/backend 2>/dev/null`
        SEC=`xenstore-read ${BEID}/sectors 2>/dev/null`
        SECSIZE=`xenstore-read ${BEID}/sector-size 2>/dev/null`
        if ! file -s `xenstore-read ${BEID}/params` | grep swap &>/dev/null; then

	    if [ -z ${SEC} ] || [ -z ${SECSIZE} ]; then
		echo " |---- Failed to get valid sector size/count of virtual disks, attempting alternative method"
		LVNAME=`xenstore-read ${BEID}/params | grep dev | xargs -i readlink {} | cut -d/ -f4 | cut -d- -f2`
		VGNAME=`lvs -o lv_name,vg_name | grep ${LVNAME} | awk '{print $2}'`
		SECSIZE=`echo ${LVNAME} | xargs -i lvs --units s --noheadings -o seg_size ${VGNAME}/{} | sed -e 's/S//g'`
		SEC="512"
	    fi

            if ! echo ${SEC} |grep "^[0-9]*$"&>/dev/null; then
    	        echo " X---- Failed to get valid sector count to calculate disk size (Value returned: (${SEC}))"
	        exit 1;
	    fi

            if ! echo ${SECSIZE} |grep "^[0-9]*$"&>/dev/null; then
                echo " X---- Failed to get valid sector size to calculate disk size (Value returned: (${SECSIZE})"
                exit 1;
            fi

            CALC=`expr ${SEC} \* ${SECSIZE} / 1024 / 1024 / 1024`
	    if [ "${DIST}" == "lin" ]; then
                if [ "${CALC}" -lt "5" ]; then
                    DISKSIZE="6"
                    echo " |---- Converting disk size into OnApp format (${DISKSIZE}) (Minimum size for OnApp Linux)"
                else
    		    DISKSIZE=${CALC}
                    echo " |---- Converting disk size into OnApp format (${DISKSIZE})"
                fi
	    else
                if [ "${CALC}" -lt "20" ]; then
                    DISKSIZE="21"
                    echo " |---- Converting disk size into OnApp format (${DISKSIZE}) (Minimum size for OnApp Windows)"
                else
                    DISKSIZE=${CALC}
                    echo " |---- Converting disk size into OnApp format (${DISKSIZE})"
                fi
	    fi
        else
	    if [ "${DIST}" == "win" ]; then
		echo " X---- Abnormal behaviour, you seem to have a swap disk asociated with a Windows VM, exiting"
	        exit 1;
	    fi
            CALC=`expr ${SEC} \* ${SECSIZE} / 1024 / 1024 / 1024`
            if [ "${CALC}" -lt "1" ]; then
                SWAPSIZE="1"
                echo " |---- Converting swap disk size into OnApp format (${SWAPSIZE})"
            else
                SWAPSIZE=${CALC}
                echo " |---- Converting swap disk size into OnApp format (${SWAPSIZE})"
            fi
        fi
    done

    if [ -z ${DISKSIZE} ]; then
        echo " X---- cant find primary disk details of virtual machine"
        exit 1;
    fi
                        
    if [ -z ${SWAPSIZE} ]; then
        echo " |---- Cant find swap disk details, disabling swap for OnApp virtual machine"
	SWAPSIZE="0"
    fi                                                

    # Check for available disk space on SolusVM
    echo " --- Checking for sufficient disk space on local hypervisor"
    ISPART=`df -h | grep '/var$'`
    if [ -z "${ISPART}" ]; then
        FS="/"
    else
        FS="/var"
    fi
    AVAIL=`df ${FS} | tail -n1 | awk '{print $4}' | xargs -i expr {} \/ 1024 \/ 1024`
    if [ $DISKSIZE -ge ${AVAIL} ]; then
        echo " X---- You don't have the available disk space on /tmp to export the disk image"
        exit 1;
    else
        echo " |---- You have sufficient disk space is available on /tmp for export"
    fi

    # Find the amount of RAM on existing VM
    echo " --- Identifying memory specification of existing virtual machine"
    DOML="/local/domain/${VMID}"
    MEMORY=$( expr `xenstore-read ${DOML}/memory/target` / 1024 )
    if [ ${MEMORY} -lt 120 ]; then
        echo " X---- Error finding the correct amount of RAM for the existing VM"
	exit 1;
    else
	echo " |---- The exiting virtual machines has ${MEMORY} MB"
    fi

    # Find the virtual machines current hostname
    echo " --- Finding the virtual machines current hostname"
    DOML="/local/domain/${VMID}"
    HOSTNAME=`xenstore-read /local/domain/${VMID}/name`
    if [ -z ${HOSTNAME} ]; then
        echo " |---- Couldn't find the virtual machines current hostname"
        HOSTNAME=`cat /dev/urandom|tr -dc "a-zA-Z0-9"|fold -w 9|head -n 1 | xargs -i echo "VM-{}"`
        echo " |---- Generated random hostname for the virtual machine (${HOSTNAME})"
    else
        echo " |---- Found the virtual machines current hostname (${HOSTNAME})"
    fi 

    # Shutdown the virtual machine
    echo " --- Trying to shutdown virtual machine"
    xm shutdown ${VMID}
    if [ $? -eq 0 ]; then
	echo " |---- Shutdown sucessfull"
    else
	echo " X---- Failed to shutdown virtual machine"
	exit 1;
    fi

    # Wait for the device mappers to close and export the virtual machine
    echo " --- Waiting 30 seconds for the device mappers to close"
    sleep 30

    # Export the disk image
    echo " --- Exporting disk image \"${REALNAME}\" (This can take some time)"
    if f_ExportDiskToFile "${REALNAME} ${FS}"; then
	echo " |---- Export completed sucesfully"
    else
	echo " X---- Failed to export disk image ${REALNAME}"
	exit 1;
    fi

    echo "${BOLD} ** (Starting the import process)${NORMAL}"
    # Make the OnApp API calls to build the VM
    echo " --- Building the virtual machine inside OnApp" 

    APILOG="/tmp/onappapi.log"
    if [ ! -e ${APILOG} ]; then
	touch ${APILOG}
    fi

    VMID=`curl -i -X POST -H 'Accept: application/json' -H 'Content-type: application/json' \
      -u ${USER}:${PASS} --url https://${HOST}/virtual_machines.json --insecure \
      -d '{
       "virtual_machine":{
          "cpu_shares":"4",
          "cpus":"1",
          "hostname":"'${HOSTNAME}'",
          "memory":"'${MEMORY}'",
          "template_id":"'${TEMPLID}'",
          "primary_disk_size":"'${DISKSIZE}'",
          "label":"'${HOSTNAME}'",
          "swap_disk_size":"'${SWAPSIZE}'",
          "required_automatic_backup":"0",
          "rate_limit":"none",
	  "required_ip_address_assignment":"1",
          "required_virtual_machine_build":"1",
          "admin_note":"Provisioned automatically by solusexport.sh"
           }
        }' 2> /dev/null 1>${APILOG} && cat ${APILOG} | grep 'identifier' | sed 's/.\+"identifier":"\([a-zA-Z0-9]\+\)".\+/\1/g'`
    
    if [ ! -z ${VMID} ]; then
        echo " |---- Virtual machine created in OnApp with identifier: ${VMID}"
    else
        echo " X---- Failed to create virtual machine, check ${APILOG}"
        exit 1;
    fi

    # We need to wait until the virtual machine has finished building before we continue
    echo " --- Polling virtual machine for boot status"
    while [ -z "${ISBOOTED}" ]; do
        echo " |---- Virtual machine is still building, waiting 20 seconds until next retry"
        sleep 20
        ISBOOTED=`curl -i -X GET -u ${USER}:${PASS} --url https://${HOST}/virtual_machines/${VMID}.json --insecure \
          2> /dev/null 1> ${APILOG} && cat ${APILOG} | grep "\"booted\":true"`
    done
    echo " |---- Virtual machine provision completed, continuing migration"

    # Shutdown the new virtual machine ready for disk import
    echo " --- Stopping the new virtual machine in OnApp to transfer disks"
    SHUTDOWN=`curl -i -X POST -u ${USER}:${PASS} --url https://${HOST}/virtual_machines/${VMID}/stop.json \
      --insecure 2> /dev/null 1> ${APILOG} && cat ${APILOG} | grep 'identifier' | sed 's/.\+"identifier":"\([a-zA-Z0-9]\+\)".\+/\1/g'`
    if [ ! -z ${SHUTDOWN} ]; then
        echo " |---- Virtual machine shutdown process completed successfully"
    else
        echo " X---- Failed to shutdown virtual machine, check ${APILOG}"
        exit 1;
    fi

    # We need to wait until the virtual machine has finished shutdown before we continue
    echo " |---- Virtual machine is shutting down, waiting 20 seconds"
    sleep 20

    # Find the OnApp disk identifier(s) ready for disk migration
    echo " --- Attempting to find virtual machine disk information in OnApp"
    VMDISKS=`curl -u ${USER}:${PASS} --url https://${HOST}/virtual_machines/${VMID}/disks.json --insecure \
      2>/dev/null 1> ${APILOG} && cat ${APILOG} | grep "identifier"`

    if [ ! -z ${VMDISKS} ]; then
        echo " |---- Virtual machine has returned disk identifiers successfully"
    else
        echo " X---- Failed to return any disk identifiers (check ${APILOG})"
        exit 1;
    fi

    # Primary Disk 
    DSIDPRI=`echo ${VMDISKS} | tr '{' "\n" | grep "\"is_swap\":false" | sed 's/^.\+"data_store_id":\([0-9]\+\).\+/\1/'`;
    if [ ! -z ${DSIDPRI} ]; then
        echo " |---- Virtual machine has returned datastore identifiers successfully (${DSIDPRI})"
    else
        echo " X---- Failed to return any datastore identifiers"
        exit 1;
    fi
    VGPRIMARY=`curl -u ${USER}:${PASS} --url https://${HOST}/settings/data_stores/${DSIDPRI}.json --insecure \
      2>/dev/null | grep "identifier" | sed 's/.\+"identifier":"\([a-zA-Z0-9-]\+\)".\+/\1/g'`;
    if [ ! -z ${VGPRIMARY} ]; then    
        echo " |---- Virtual machine has returned datastore name successfully (${VGPRIMARY})" 
    else    
        echo " X---- Failed to return any datastore name" 
        exit 1;    
    fi    
    LVPRIMARY=`echo ${VMDISKS} | tr '{' "\n" | grep "\"is_swap\":false" | sed 's/^.\+"identifier":"\([a-zA-Z0-9]\+\)".\+/\1/'`
    if [ ! -z ${LVPRIMARY} ]; then
	echo " |---- Identified virtual machines primary disk and datastore identifiers successfully (${LVPRIMARY})"
    else
	echo " X---- Failed to return primary disk identifiers for virtual machine"
	exit 1;
    fi
  
    # Swap Disk
    DSIDSWAP=`echo ${VMDISKS} | tr '{' "\n" | grep "\"is_swap\":true" | sed 's/^.\+"data_store_id":\([0-9]\+\).\+/\1/'`;
    if [ ! -z ${DSIDSWAP} ]; then    
        echo " |---- Virtual machine has returned swap datastore identifiers successfully (${DSIDSWAP})"
    else    
        echo " |---- Didn't return any swap datastore identifiers" 
    fi

    if [ ! -z ${DSIDSWAP} ]; then
        VGSWAP=`curl -u ${USER}:${PASS} --url https://${HOST}/settings/data_stores/${DSIDSWAP}.json --insecure \
          2>/dev/null | grep "identifier" | sed 's/.\+"identifier":"\([a-zA-Z0-9-]\+\)".\+/\1/g'`;
        if [ ! -z ${VGSWAP} ]; then
            echo " |---- Virtual machine has returned swap datastore name successfully (${VGSWAP})"
        else
            echo " X---- Failed to return any swap datastore name"                         
        exit 1;
        fi	  
        LVSWAP=`echo ${VMDISKS} | tr '{' "\n" | grep "\"is_swap\":true" | sed 's/^.\+"identifier":"\([a-zA-Z0-9]\+\)".\+/\1/'`
        if [ ! -z ${LVSWAP} ]; then
            echo " |---- Identified virtual machines swap disk and datastore identifiers successfully (${LVSWAP})"
        else
            echo " X---- Failed to return swap disk identifier for virtual machine"
            exit 1;
        fi
    else
	echo " |---- Skipping swap disk identifiers, no swap space configured"
    fi

    # Find the IP address of the hypervisor running the OnApp virtual machine
    if [ -z ${CUSTHVIP} ]; then
        echo " --- Looking for the IP address of the OnApp hypervisor"
        HVID=`curl -i -X GET -u ${USER}:${PASS} --url https://${HOST}/virtual_machines/${VMID}.json --insecure \
          2> /dev/null 1>${APILOG} && cat ${APILOG} | grep 'hypervisor_id' | sed 's/^.\+"hypervisor_id":\([0-9]\+\).\+/\1/'`
        if [ ! -z ${HVID} ]; then
            echo " |---- Found hypervisor id for virtual machine (${HVID})"
        else
            echo " X---- Failed to find hypervisor id of virtual machine"
            exit 1;
        fi
        HVIP=`curl -i -X GET -u ${USER}:${PASS} --url https://${HOST}/settings/hypervisors/${HVID}.json --insecure \
          2> /dev/null 1>${APILOG} && cat ${APILOG} | grep 'ip_address' | sed 's/.\+"ip_address":"\([0-9\.]\+\)".\+/\1/g'`;
        if [ ! -z ${HVID} ]; then
            echo " |---- Found IP address of hypervisor (${HVIP})"
        else
            echo " X---- Failed to find IP address of hypervisor"
            exit 1;
        fi
    else
	echo " --- Using custom IP address provided for connection to OnApp hypervisor (${CUSTHVIP})"
	HVIP=${CUSTHVIP}
    fi

    # Check SSH connection to remote OnApp hypervisor (We need SSH to perform the DD).
    TIMEOUT="3"
    SSHUSER="root"
    echo " --- Testing SSH connection to remote OnApp hypervisor (We need this to perform the disk migration)"
    ${SSH} -q -q -o StrictHostKeyChecking=no -o "BatchMode=yes" -o "ConnectTimeout ${TIMEOUT}" ${SSHUSER}@${HVIP} exit &>/dev/null
    if [ $? -ne 0 ]; then
        echo " X---- Failed to make ssh connection to OnApp hypervisor (${SSHUSER}@${HVIP})"
	exit 1;
    else
        echo " |---- SSH connection to OnApp hypervisor was successfull"
    fi

    # Import the disk into OnApp
    # Transfer the disk image to the OnApp hypervisor
    echo " ---- Activiating the logical volume on the OnApp hypervisor"
    if ${SSH} -o StrictHostKeyChecking=no ${SSHUSER}@${HVIP} lvchange -ay ${VGPRIMARY}/${LVPRIMARY} &>/dev/null; then
        sleep 10
	echo " |---- Successfully activated"
    else
	echo " X---- Failed to activate the logical volume"
	exit 1;
    fi

    echo " --- Looking for the device mapping on the OnApp hypervisor"
    DESTDISKPRI=`${SSH} -o StrictHostKeyChecking=no ${SSHUSER}@${HVIP} readlink /dev/${VGPRIMARY}/${LVPRIMARY}`
    if [ $? -eq 0 ]; then
	echo " |---- Found the device mapping for primary disk"
    else
	echo " X---- Failed to find device mapping for primary disk"
	exit 1;
    fi

    echo " --- Starting the disk migration to the OnApp hypervisor (this could take some time)"
    LOCATION="/var/export"
    DISKIMAGE=`echo ${REALNAME} | cut -d/ -f 4`
    if dd if=${LOCATION}/${DISKIMAGE} | ${SSH} -o StrictHostKeyChecking=no ${SSHUSER}@${HVIP} dd of=${DESTDISKPRI} &>/dev/null; then
        echo " |---- Successfully migrated disk image"
	echo " --- Removing the local disk image file (${LOCATION}/${DISKIMAGE})"
	rm -f ${LOCATION}/${DISKIMAGE} &>/dev/null
    else
        echo " X---- Failed to migrate disk image"
	exit 1;
    fi

    echo " |---- Waiting 30 seconds to allow processes to finish before deactivating the logical volume"
    sleep 30
    echo " |---- Deactiviating the logical volume on the OnApp hypervisor"
    if ${SSH} -o StrictHostKeyChecking=no ${SSHUSER}@${HVIP} lvchange -an ${VGPRIMARY}/${LVPRIMARY} &>/dev/null; then
        echo " |---- Successfully deactivated"
    else
        echo " X---- Failed to deactivate the logical volume (The process should still have completed successfully)"
    fi

    echo -ne " - The migration has completed successfully, you can now boot the virtual machine.\n - http(s)://${HOST}/virtual_machines/${VMID}\n\n"
    return 0;
}

f_ExportAll () {
    echo "Export All Virtual Machines, this method will be available in OnApp 2.5"
    exit 0;
}

f_Menu () {
    QUIT="no"
    while [ ${QUIT} != "yes" ]; do
        echo "1. List All Virtual Machines"
        echo "2. Export Virtual Machine"
        echo "3. Export All Virtual Machines"
        echo "4. Quit"
        echo -n "Your choice? : "
        read CHOICE

        case ${CHOICE} in
	    1) f_List ;;
	    2) f_ExportOne ;;
	    3) f_ExportAll ;;
	    4) QUIT="yes" ;;
	    *) echo "\"${CHOICE}\" is not valid"
            sleep 2 ;;
        esac
    done
}

f_Switch () {
    BOLD=`tput bold`
    NORMAL=`tput sgr0`
    USAGE="\n$(basename $0) [ -o ${BOLD}list${NORMAL}|${BOLD}help${NORMAL}|${BOLD}templates${NORMAL} ]
	       [ -o ${BOLD}migrate${NORMAL} -v id -H sub.example.com -u user -p pass -t template-id -d win|lin -P sshport -c onapphvip ]

    where:
	-o  specify an option value
		${BOLD}list${NORMAL} - list all VMs running on the hypervisor
		${BOLD}templates${NORMAL} - list all VMs templates for use with '-t' switch
		${BOLD}help${NORMAL} - splash this help menu
		${BOLD}migrate${NORMAL} - migrate a virtual machine

	${BOLD}Migrate Options:${NORMAL}
	-H  Set the hostname of your controler (without http(s)://)
	-c  Set a custom IP address for connection to the OnApp hypervisor, if not specified default will be the management IP specified in OnApp
	-v  Set the identifier of chosen VM (-o list, for a list of VMs)
	-u  OnApp WebUI admin username
	-p  OnApp WebUI admin password
        -P  Specify a custom SSH port, default will always be 22 if not specified
	-d  The type of virtual machine you are migrating (ether win or lin) Windows or Linux
	-t  Specify the template id in your OnApp installation similar to the incoming template (-o templates, for a list of options)\n\n"

    if [ -z $1 ]; then
	echo -ne "${USAGE}"
	exit 1;
    fi

    while getopts :c:P:d:t:o:H:u:p:v: OPT; do
        case "${OPT}" in
            H) HOST=${OPTARG};;
	    c) CUSTHVIP=${OPTARG};;
            u) USER=${OPTARG};;
            d) DIST=${OPTARG};;
            t) TEMPLID=${OPTARG};;
            p) PASS=${OPTARG};;
            P) SSHPORT=${OPTARG};;
            o) OPTION=${OPTARG};;
            v) VMID=${OPTARG};;
        esac
    done
    shift $(( OPTIND - 1 ))

    if [ -z ${SSHPORT} ]; then
	SSHPORT="22"
    fi

    if [ "${OPTION}" == "help" ]; then
        echo -ne "${USAGE}"
	exit 1;
    elif [ "${OPTION}" == "list" ]; then
	f_GenPreReq
        f_List
	exit 0;
    elif [ "${OPTION}" == "templates" ]; then
	f_GenPreReq
	f_CheckApi "${HOST}, ${USER}, ${PASS}"
        f_TemplateList "${HOST}, ${USER}, ${PASS}"
	exit 0;
    elif [ "${OPTION}" == "migrate" ]; then
	if [ -z ${HOST} ] || [ -z ${USER} ] || [ -z ${PASS} ] || [ -z ${TEMPLID} ] || [ -z ${DIST} ] || [ -z ${VMID} ]; then
	    echo -ne "${USAGE}"
	else
	    f_GenPreReq
	    f_MigPreReq "${DIST},${SSHPORT}"
	    f_CheckApi "${HOST}, ${USER}, ${PASS}"
            f_ExportOne "${HOST},${USER},${PASS},${VMID},${TEMPLID},${DIST},${SSHPORT},${CUSTHVIP}"
	fi
    else
	echo -ne "${USAGE}"
        exit 1;
    fi
}

f_CheckApi () {
    APICONN=`curl -w %{http_code} -u ${USER}:${PASS} --url https://${HOST}/virtual_machines.json --insecure 2>/dev/null | sed 's/.*\(...\)$/\1/'`
    if [ "${APICONN}" == "200" ]; then   
        echo " - Successfully connected to OnApp API"              
    else
        echo " - Failed to connect to OnApp API, please check your input"
        exit 1;
    fi
}

f_GenPreReq () {
    if ! `which xm &>/dev/null`; then
        echo -e "Xen installation not found\n"
        exit 1;
    fi
}

f_MigPreReq () {

    if [ "${DIST}" != "win" ] && [ "${DIST}" != "lin" ]; then
	echo " - You must enter a valid template type, options win|lin"
	exit 1;
    fi

    if [ -e "/etc/onapp.conf" ]; then
        echo " - You must not run this script from the OnApp hypervisor, this must run from the source hypervisor"
        exit 1;
    fi

    if ! [ "${SSHPORT}" -eq "${SSHPORT}" 2> /dev/null ]; then
        echo " - You must specify a valid SSH port"
        exit 1;
    fi
}

# - Main
#echo "DEBUG: switches ${@}"
f_Switch "$@"
