FROM alpine:3.15.0 AS stage-1

# etcdctl version to use
ENV ETCD_VERSION="v3.5.0"

RUN apk add --no-cache bash git go \
    && apk update \
    && mkdir -p /etcd \
    && mkdir -p /etcd-source \
    && git clone -b ${ETCD_VERSION} https://github.com/etcd-io/etcd.git /etcd-source \
    && cd /etcd-source \
    && ./build.sh \
    && cp /etcd-source/bin/etcdctl /etcd

From redhat/ubi8-minimal:8.5-230

# kubectl version to use
ENV KUBE_VERSION="v1.22.4"
# Data path
ENV DATA_PATH="/data"
# location for etcdctl file
ENV ETCD_PATH="/etcd"
# path for snapshots
ENV BAKCUP_PATH="${DATA_PATH}/snapshots"
# path for kubectl file
ENV KUBE_PATH="${DATA_PATH}/bin"
# path for log files
ENV LOG_DIR="${DATA_PATH}/logs"
# etcd PKI Hostpath
ENV ETCD_PKI_HOSTPATH="/etc/kubernetes/pki/etcd"
# Default to UTC+0:00 as per current Kubernetes Cronjob limitation
ENV TZ="Etc/GMT"
# Enable/disable deveplopment mode, "off" or "on"
ENV DEV_MODE="off"
# Number of snapshot history to keep
ENV SNAPSHOT_HISTORY_KEEP=3
# Log Level: info, debug
ENV LOG_LEVEL="info"

Run microdnf update -y \
    && microdnf install -y jq wget \
    # Change to 'install -y tzdata' when bug is resolved upstream.
    && microdnf reinstall -y tzdata \
    && rm -rf /var/cache \
    && microdnf clean all \
    && mkdir -p ${ETCD_PATH}

WORKDIR ${ETCD_PATH}/

COPY --from=stage-1 /etcd ./
COPY ./run-backup.sh ${ETCD_PATH}/

RUN chmod -R +x ${ETCD_PATH}/* \
    && chown -R root:root ${ETCD_PATH}

USER root

CMD "${ETCD_PATH}/run-backup.sh"
