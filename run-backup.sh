#!/usr/bin/env bash

# Global Variables
ADVERTISED_CLIENT_URL=""
ETCD_SERVER_CERT=""
ETCD_SERVER_KEY=""
ETCD_CACERT=""

# extract param value
function paramValue(){
    source=$1
    search=$2
    local result=${source#*$search}
    echo "$result"
}

function log(){
    
    if [ ! -d ${LOG_DIR} ]; then
        mkdir -p ${LOG_DIR}
    fi
    # Recycle log file per month
    LOG_FILE_DATE=$(date '+%Y-%m')
    LOG_FILE=${LOG_DIR}/etcdbk-${LOG_FILE_DATE}.log
    if [ ! -f ${LOG_FILE} ]; then
        touch ${LOG_FILE}
    fi
    LOG_TIMESTAMP=$(date '+%F-%T %p')
    LOG_MESSAGE="${LOG_TIMESTAMP}   $1"
    echo "$LOG_MESSAGE"
    echo "$LOG_MESSAGE" >> ${LOG_FILE}
}

function logError(){
    log "ERROR   $1"
}

function logInfo(){
    log "INFO    $1"
}

function warn(){
    log "WARN    $1"
}

function debug(){
    if [ "${LOG_LEVEL}" = "debug" ]; then
        log "DEBUG   $1"
    fi
}

function printEnv(){

    logInfo "Environmental Variables:"

    echo "KUBE_VERSION:${KUBE_VERSION}"
    echo "DATA_PATH:${DATA_PATH}"
    echo "ETCD_PATH:${ETCD_PATH}"
    echo "BAKCUP_PATH:${BAKCUP_PATH}"
    echo "PKI_BACKUP_PATH:${PKI_BACKUP_PATH}"
    echo "KUBE_PATH:${KUBE_PATH}"
    echo "LOG_DIR:${LOG_DIR}"
    echo "KUBE_PKI_PATH:${KUBE_PKI_PATH}"
    echo "ETCD_PKI_HOSTPATH:${ETCD_PKI_HOSTPATH}"
    echo "TZ:${TZ}"
    echo "DEV_MODE:${DEV_MODE}"
    echo "SNAPSHOT_HISTORY_KEEP:${SNAPSHOT_HISTORY_KEEP}"
    echo "LOG_LEVEL:${LOG_LEVEL}"
    echo "PKI_HISTORY_KEEP:${PKI_HISTORY_KEEP}"
    
}

# Run snapshot for the specific etcd instance
# Input: $1 - etcd url, $2 - etcd name, $3 - ca.crt, $4 - server.crt, $5 - server.key
function snapshot(){

    TIMESTAMP=$(date '+%Y-%m-%d-%H-%M-%s')
    ETCD_NAME=$1
    ETCD_URL=$2

    logInfo "Backing up $ETCD_NAME ... Snapshot file: ${BAKCUP_PATH}/$ETCD_NAME-${TIMESTAMP} ..."

    OUTPUT=$( (ETCDCTL_API=3 ${ETCD_PATH}/etcdctl --endpoints ${ETCD_URL} \
    snapshot save ${BAKCUP_PATH}/$ETCD_NAME-${TIMESTAMP}.etcdbk \
    --cacert="$3" \
    --cert="$4" \
    --key="$5") 2>&1 )

    logInfo "${OUTPUT}"

}

function backupCerts(){

    TIMESTAMP=$(date '+%Y-%m-%d-%H-%M-%s')
    
    logInfo "Backing up PKI Certificates ..."

    mkdir ${PKI_BACKUP_PATH}/${TIMESTAMP}
    
    CP_VERBOSE=""

    if [ "${LOG_LEVEL}" = "debug" ]; then
        CP_VERBOSE="v"
    fi

    if [[ ! -z "${KUBE_LOCAL_PKI_PATH}" ]]; then
        cp -a${CP_VERBOSE} ${KUBE_LOCAL_PKI_PATH}/. ${PKI_BACKUP_PATH}/${TIMESTAMP}/
    else
        cp -a${CP_VERBOSE} ${KUBE_PKI_PATH}/. ${PKI_BACKUP_PATH}/${TIMESTAMP}/
    fi

    if [ "$?" = "0" ]; then 
        logInfo "PKI Certificates are backed up into directory: ${PKI_BACKUP_PATH}/${TIMESTAMP}"
    fi

}

# Remove and maintaine snapshots number <= SNAPSHOT_HISTORY_KEEP
function cleanOldSnapshots(){
    
    logInfo "Cleaning old snapshots ... Number of snapshots to keep: $SNAPSHOT_HISTORY_KEEP"
    
    COUNTER=$(ls ${BAKCUP_PATH}/ | wc -l);
    
    debug "Backup path: ${BAKCUP_PATH}"
    debug "Total snapshop file: ${COUNTER}"

    for FILE in `ls -tr ${BAKCUP_PATH}/`; do 
        COUNTER=$[$COUNTER-1]
        if [ $[$COUNTER+1] -gt $SNAPSHOT_HISTORY_KEEP ]; then
            debug "Going to delete snapshot ${BAKCUP_PATH}/$FILE ... "
            rm ${BAKCUP_PATH}/$FILE
            debug "Snapshot ${BAKCUP_PATH}/$FILE is deleted."
        fi
    done
}

# Remove and maintaine PKI backup copies <= PKI_HISTORY_KEEP
function cleanOldPKI(){
    
    logInfo "Cleaning old PKI backup ... Number of backup to keep: $PKI_HISTORY_KEEP"
    
    cd ${PKI_BACKUP_PATH}
    
    COUNTER=0

    ls -dtr */ &> /dev/null

    # `ls -d` return error if not directory exists
    if [ "$?" = "0" ]; then
        COUNTER=$(ls -dtr */ | wc -l);
    fi

    debug "Backup path: ${PKI_BACKUP_PATH}"
    debug "Total backup file set: ${COUNTER}"
    # Reverse order the directories since they are copied using `cp -a` which original file attributes are preserved.
    for FILE in `ls -dt */`; do 
        COUNTER=$[$COUNTER-1]
        if [ $[$COUNTER+1] -gt $PKI_HISTORY_KEEP ]; then
            debug "Going to delete PKI backup ${PKI_BACKUP_PATH}/$FILE ... "
            rm -rf ${PKI_BACKUP_PATH}/$FILE
            debug "Backup ${PKI_BACKUP_PATH}/$FILE is deleted."
        fi
    done
}


function process_backup(){

    ETCD_PODS_NAMES=$(${KUBE_PATH}/kubectl get pod -l component=etcd -o jsonpath="{.items[*].metadata.name}" -n kube-system) 
    
    # Keeping the for loop just in case in future the ectd pod name changed, so comparing the ends-with node name more promising.
    # Another reason of doing this lookup is to make sure we are using the correct etcd-name and config for which this POD could be running. 
    # each time, it could be running on different control plane.
    for etcd in $ETCD_PODS_NAMES
    do
        #logInfo "Startinng snapshot for $etcd ... "
        
        if [[ "$etcd" == *${NODE_NAME} ]] ; then

            logInfo "Starting snapshot for etcd in node ${NODE_NAME} ... "

            COMMANDS=$(${KUBE_PATH}/kubectl get pods $etcd -n kube-system -o=jsonpath='{.spec.containers[0].command}')
            
            
            for row in $(echo "${COMMANDS}" | jq -r '.[]'); do
                if [[ ${row} = --advertise-client-urls* ]]; then
                    ADVERTISED_CLIENT_URL=$(paramValue ${row} "=")
                    logInfo "ADVERTISED_CLIENT_URL = ${ADVERTISED_CLIENT_URL}"
                elif [[ ${row} = --cert-file* ]]; then
                    ETCD_SERVER_CERT=$(paramValue ${row} "=")
                    logInfo "ETCD_SERVER_CERT = ${ETCD_SERVER_CERT}"
                elif [[ ${row} = --key-file* ]]; then
                    ETCD_SERVER_KEY=$(paramValue ${row} "=")
                    logInfo "ETCD_SERVER_KEY = ${ETCD_SERVER_KEY}"
                elif [[ ${row} = --trusted-ca-file* ]]; then
                    ETCD_CACERT=$(paramValue ${row} "=")
                    logInfo "ETCD_CACERT = ${ETCD_CACERT}"
                fi
            done

            cp ${ETCD_CACERT} /tmp/$etcd-ca.crt && cp ${ETCD_SERVER_CERT} /tmp/$etcd-server.crt && cp ${ETCD_SERVER_KEY} /tmp/$etcd-server.key

            snapshot "${etcd}" "${ADVERTISED_CLIENT_URL}" "/tmp/$etcd-ca.crt" "/tmp/$etcd-server.crt" "/tmp/$etcd-server.key"
            
            cleanOldSnapshots
        fi
    done

    ## TODO: We do not need to backup PKI certs so often as they are only renewed yearly. Next is to change it to accommodate this.
    backupCerts
    cleanOldPKI

}

function downloadKubeFiles(){

    ARC=$(uname -m)
    KUBE_ARC=""
    
    if [ "${ARC}" = "aarch64" ] || [ "${ARC}" = "aarch64_be" ]; then
        KUBE_ARC="arm64"
    elif [ "${ARC}" = "x86_64" ] ; then 
        KUBE_ARC="amd64"
    else
        logError "Hardware architecture not supported. Current container architecture: ${ARC}"
        exit 1
    fi

    logInfo "Downloadling kubectl file. Version:${KUBE_VERSION}, ARC:${KUBE_ARC} ..."

    wget "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${KUBE_ARC}/kubectl" -O ${KUBE_PATH}/kubectl
    wget "https://dl.k8s.io/${KUBE_VERSION}/bin/linux/${KUBE_ARC}/kubectl.sha256" -O ${KUBE_PATH}/kubectl.sha256
    echo "$(<${KUBE_PATH}/kubectl.sha256)  ${KUBE_PATH}/kubectl" | sha256sum -c --status
    if [ $? -ne 0 ]; then
        logError "kubectl checksum failed. Please check you have internal connection to download kubectl file from https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${KUBE_ARC}/kubectl"
        exit 1
    fi
    
    chmod +x ${KUBE_PATH}/kubectl

}

function init(){
    
    mkdir -p ${BAKCUP_PATH}
    mkdir -p ${KUBE_PATH}
    mkdir -p ${LOG_DIR}
    mkdir -p ${PKI_BACKUP_PATH}

    if [ ! -f "${KUBE_PATH}/kubectl" ]; then 
        downloadKubeFiles
    else
        SERVER_KUBECTL_VERSION="$(${KUBE_PATH}/kubectl version -o json | jq '.serverVersion.gitVersion' | sed 's/\"//g')"; 
        CLIENT_KUBECTL_VERSION="$(${KUBE_PATH}/kubectl version -o json | jq '.clientVersion.gitVersion' | sed 's/\"//g')"; 
        
        logInfo "Kubectl Server Version: $SERVER_KUBECTL_VERSION" 
        logInfo "Kubectl Client Version: $CLIENT_KUBECTL_VERSION" 

        if [[ ! "${SERVER_KUBECTL_VERSION}" = "${CLIENT_KUBECTL_VERSION}"  ]]; then 
            logInfo "Current kubectl version is not matching the provided env variable KUBE_VERSION:${KUBE_VERSION}"
            logInfo "Proceed to download the correct kubectl version."
            downloadKubeFiles
        fi
    fi
}

init

printEnv

if [ "${DEV_MODE}" = "on" ]; then
    logInfo "DEV_MODE is on."
    if [ $# -eq 0 ]; then
        logError "Missing etcd server url and etcd name at the command line argument. command syntax"
        logError "Expected command syntax: /etcd/run-backup.sh <etcd name> <etcd url> <ca.crt> <server.crt> <server.key> "
        exit 1
    fi
    logInfo "Command line arguments: $@"
    KUBE_LOCAL_PKI_PATH=/tmp/certs
    snapshot $@
    cleanOldSnapshots
    backupCerts
    cleanOldPKI
else
    process_backup
fi
