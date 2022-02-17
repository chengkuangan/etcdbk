FROM alpine:3.15.0

# etcdctl version to use
ENV ETCD_VERSION="v3.5.0"
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
ENV KUBE_VERSION="v1.22.4"
# Enable/disable deveplopment mode, "off" or "on"
ENV DEV_MODE="off"
# Number of snapshot histry to keep
ENV SNAPSHOT_HISTORY_KEEP=3

RUN apk add --no-cache --virtual .build-deps git go
RUN apk add --no-cache bash tzdata jq \
    && apk update \
    && mkdir -p ${ETCD_PATH} \
    && mkdir -p /etcd-source \
    && git clone -b ${ETCD_VERSION} https://github.com/etcd-io/etcd.git /etcd-source \
    && cd /etcd-source \
    && ./build.sh \
    && cp /etcd-source/bin/etcdctl ${ETCD_PATH}/ \
    && rm -rf /etcd-source \
    && rm -rf /root .cache go \
    && chmod -R +x ${ETCD_PATH}/* \
    && chown -R root:root ${ETCD_PATH} \
    && cp /usr/share/zoneinfo/$TZ /etc/localtime

RUN apk del .build-deps

COPY --chown=root:root ./run-backup.sh ${ETCD_PATH}/

WORKDIR ${ETCD_PATH}/

USER root

CMD "${ETCD_PATH}/run-backup.sh"

#ENTRYPOINT [ "${ETCD_PATH}/run-backup.sh" ]
