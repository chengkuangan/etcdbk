# etcdbk - An automated backup tool for Kubernetes etcd data

Instead of re-invent the wheel to create another tool to backup the `etcd` data, we are now being able to automate the Kubernetes `etcd` data backup using `etcdbk` container by reusing the existing Kubernetes features and `etcd` tool.

You can schedule the `etcdbk` container to snapshot the `etcd` data on a periodical basis by the using the `Conjob`. Once it is deployed and configured, the `etcdbk` container will perform the snapshot and create the snapshot files on the pre-configured persistent volume.

With these snapshots created per scheduled, you can now using your existing storage backup mechanism to backup these snapshots on your backup media.

It is currently based on Alpine base image and supports both `amd64` and `arm64` architecture. 

## Build the Container

You can use Docker to build the container image. 

You will need to create and configure a multi-arch profile before proceed. Please refer the [documentation here](https://docs.docker.com/desktop/multi-arch/) for how to create a multi-arch build environment.

The current `etcd` version is defaulted to "v3.5.0" in the [Dockerfile](./Dockerfile). 
You can change the `etcd` version to your preferred version using `--build-arg ETCD_VERSION=v3.5.0` at the `docker build` command.

```
$ ETCD_VERSION=v3.5.0
$ docker buildx build --platform linux/arm64,linux/amd64 --build-arg ETCD_VERSION=${ETCD_VERSION} -t chengkuan/etcdbk:${ETCD_VERSION}-1.0.0  -f Dockerfile --push .

# Internal insecured registry
docker buildx build --platform linux/arm64,linux/amd64 --build-arg ETCD_VERSION=${ETCD_VERSION} -t nexus.internal:7082/repository/containers/etcdbk:${ETCD_VERSION}-1.0.0 -f Dockerfile --push --output=type=registry,registry.insecure=true .

```

## Configuration

You can configure the container with the following environmental variables.

- To turn on Development mode. By default this is `off`. This setting if more for local container testing. Please refer [Test the container locally](#test-the-container-locally) for more of this local testing.
  ```
  DEV_MODE="on"
  ```
- To configure the number of snapshot files to keep. Default is 3 latest files.
  ```
  SNAPSHOT_HISTORY_KEEP=3
  ```
- To specify the `kubectl` version to use. The current Dockerfile version is defaulted to `v1.22.4`.
  ```
  KUBE_VERSION=v1.22.4
  ```
- To change the default mount path in the container. You will need to create a volume for this directory. This directory is used to store snapshot files, `kubectl` binary and logs.
  ```
  DATA_PATH="/data"
  ```
- Change the default timezone. This timezone is used for naming the snapshot files and the date time used in the logs. 
  ```
  TZ="Etc/GMT"
  ```

## Test the container locally

1. Make a local directory
  ```
  $ mkdir etcdbk
  $ cd etcdbk
  ```

2. Copy `ca.cert`, `server.crt` and `server.key` from the `etcd` node.
  ```
  $ SSH_USER=john
  $ ETCD_NODE=10.0.0.110
  $ scp ${SSH_USER}@${ETCD_NODE}:/etc/kubernetes/pki/etcd/ca.crt ./ca.crt
  $ ssh ${SSH_USER}@${ETCD_NODE} "sudo cp /etc/kubernetes/pki/etcd/server.key /tmp/server.key && sudo chmod 777 /tmp/server.key"
  $ scp ${SSH_USER}@${ETCD_NODE}:/tmp/server.key ./server.key
  $ ssh ${SSH_USER}@${ETCD_NODE} sudo rm /tmp/server.key
  ```
3. Run the following to test the container locally. The container will make a remote connectiong to your Kubernetes `etcd` instace.
  ```
  ETCD_VERSION=v3.5.0
  $ docker run -it \
  -v $(pwd)/data:/data \
  -v $(pwd)/ca.crt:/tmp/ca.crt \
  -v $(pwd)/server.crt:/tmp/server.crt \
  -v $(pwd)/server.key:/tmp/server.key \
  -e DEV_MODE="on" \
  -e SNAPSHOT_HISTORY_KEEP=2 \
  nexus.internal:7082/repository/containers/etcdbk:${ETCD_VERSION}-1.0.0 /etcd/run-backup.sh kube0.internal https://${ETCD_NODE}:2379 /tmp/ca.crt /tmp/server.crt /tmp/server.key
  ```

## Deploy into Kubernetes

1. Open [etcdbk.yaml](./etcdbk.yaml) and change the `Conjob` schedule to your preference. 

    ```yaml
    apiVersion: batch/v1
    kind: CronJob
    metadata:
        name: etcdbk
        namespace: etcdbk
        labels:
            app: etcdbk
            app-group: etcdbk
    spec:
        # Change the schedule here. The current value is with the timezone set to UTC+0:00
        schedule: "0 0 * * *"
        jobTemplate:
    ...
    ```
    Refer the Kubernetes [Cronjob syntax](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/#cron-schedule-syntax) for more configuration option.
    
    Please note that Cronjob does not support customize timezone which is always defaulted to container UTC+0:00 timezone. Refers the [reported issue here](https://github.com/kubernetes/kubernetes/issues/47202).

2. Change the timezone via the YAML environmental variable. This affects the snapshot filename and the logging timestamp. You should change this to your local timezone for easy troubleshooting or logging.
    ```yaml
          - env:
            - name: TZ
              value: "Asia/Kuala_Lumpur"
    ```
    Refer the timezone values at [wikipedia](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones).

3. The YAML also defines the location for the `etcd` POD PKI certificates and key using a `Hostpath` definition. We also define the PVC to store the snapshot file. This is also the location for the log file.

    ```yaml
            volumeMounts:
              - mountPath: /etc/kubernetes/pki/etcd
                name: etcd-certs
                readOnly: true
              - mountPath: /data
                name: data-dir
          restartPolicy: OnFailure
          volumes:
          - hostPath:
              path: /etc/kubernetes/pki/etcd
              type: Directory
            name: etcd-certs
          - name: data-dir
            persistentVolumeClaim:
              claimName: etcdbk-data

    ```

2. Deploy the container to Kubernetes

    ```
    $ kubectl create -f etcdbk.yaml
    ```
    Note: This will create all the necessary ClusterRole, ClusterRoleBinding, PVC, namespaces and Pod. Make sure the required PersistentVolume are created if your Kubernetes cluster does not support `Dynamic Storage Class`. Refer [Kubernetes documentation](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#persistent-volumes) for guide to create PersistentVolume if required.

### Test the container

You can run the following command using `kubectl` to test the deployed Pod.

```
kubectl create job testjob --from=cronjob/etcdbk -n etcdbk
```

You will observe the output similar to the following:

<details>

<summary>Sample output</summary>

    ```    
    2022-02-27-14:15:09 PM   INFO    Timezone: Asia/Kuala_Lumpur
    2022-02-27-14:15:15 PM   INFO    Starting snapshot for etcd in node kube2.local ... 
    2022-02-27-14:15:16 PM   INFO    ADVERTISED_CLIENT_URL = https://10.0.0.102:2379
    2022-02-27-14:15:16 PM   INFO    ETCD_SERVER_CERT = /etc/kubernetes/pki/etcd/server.crt
    2022-02-27-14:15:16 PM   INFO    ETCD_SERVER_KEY = /etc/kubernetes/pki/etcd/server.key
    2022-02-27-14:15:16 PM   INFO    ETCD_CACERT = /etc/kubernetes/pki/etcd/ca.crt
    2022-02-27-14:15:17 PM   INFO    Backing up etcd-kube2.local ... Snapshot file: /data/snapshots/etcd-kube2.local-2022-02-27-14-15-1645942517 ...
    2022-02-27-14:15:18 PM   INFO    {"level":"info","ts":1645942517.8480756,"caller":"snapshot/v3_snapshot.go:68","msg":"created temporary db file","path":"/data/snapshots/etcd-kube2.local-2022-02-27-14-15-1645942517.etcdbk.part"}
    {"level":"info","ts":1645942517.8523066,"logger":"client","caller":"v3/maintenance.go:211","msg":"opened snapshot stream; downloading"}
    {"level":"info","ts":1645942517.8524687,"caller":"snapshot/v3_snapshot.go:76","msg":"fetching snapshot","endpoint":"https://10.0.0.102:2379"}
    {"level":"info","ts":1645942518.436307,"logger":"client","caller":"v3/maintenance.go:219","msg":"completed snapshot read; closing"}
    {"level":"info","ts":1645942518.6646767,"caller":"snapshot/v3_snapshot.go:91","msg":"fetched snapshot","endpoint":"https://10.0.0.102:2379","size":"12 MB","took":"now"}
    {"level":"info","ts":1645942518.759678,"caller":"snapshot/v3_snapshot.go:100","msg":"saved","path":"/data/snapshots/etcd-kube2.local-2022-02-27-14-15-1645942517.etcdbk"}
    Snapshot saved at /data/snapshots/etcd-kube2.local-2022-02-27-14-15-1645942517.etcdbk
    2022-02-27-14:15:18 PM   INFO    Cleaning old snapshots ... Number of snapshots to keep: 3

    ```

</details>

    
