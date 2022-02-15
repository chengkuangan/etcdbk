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
    log "DEBUG   $1"
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

# Remove and maintaine snapshots number <= SNAPSHOT_HISTORY_KEEP
# Params: $1 - etcd snapshot file name prefix
function cleanOldSnapshots(){
    logInfo "Cleaning old snapshots ... Number of snapshots to keep: $SNAPSHOT_HISTORY_KEEP"
    COUNTER=0;
    for FILE in `ls ${BAKCUP_PATH}/$1* | sort -r`; do 
        COUNTER=$[$COUNTER+1]
        if [ "$COUNTER" -gt "$SNAPSHOT_HISTORY_KEEP" ]; then
            rm $FILE
        fi
    done
}

function process_backup(){

    ETCD_PODS_NAMES=$(${KUBE_PATH}/kubectl get pod -l component=etcd -o jsonpath="{.items[*].metadata.name}" -n kube-system) 

    for etcd in $ETCD_PODS_NAMES
    do
        logInfo "Startinng snapshot for $etcd ... "

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
        
        cleanOldSnapshots "${etcd}"

    done
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
    echo "$(<${KUBE_PATH}/kubectl.sha256)  ${KUBE_PATH}/kubectl" | sha256sum -cs
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

    logInfo "Timezone: ${TZ}"

    if [ ! -f "${KUBE_PATH}/kubectl" ]; then 
        downloadKubeFiles
    else
        if [[ ! "$(${KUBE_PATH}/kubectl version)" =~ .*GitVersion:\"${KUBE_VERSION}\".* ]]; then 
            logInfo "Current kubectl version is not matching the provided env variable ${KUBE_VERSION}."
            logInfo "Proceed to download the correct kubectl version."
            downloadKubeFiles
        fi
    fi
}

init

if [ "${DEV_MODE}" = "on" ]; then
    logInfo "DEV_MODE is on."
    if [ $# -eq 0 ]; then
        logError "Missing etcd server url and etcd name at the command line argument. command syntax"
        logError "Expected command syntax: run-backup.sh <etcd name> <etcd url> <ca.crt> <server.crt> <server.key>"
        exit 1
    fi
    logInfo "Command line arguments: $@"
    snapshot $@
    cleanOldSnapshots "$1"
else
    process_backup
fi
