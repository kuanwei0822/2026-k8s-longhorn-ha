# 2026-k8s-longhorn-ha

# 問題

NFS 通常為共用非結構化資料常用手段，而 K8s Cluster 中使用 NFS ( NFS 本身無額外 HA ) 的確會有 NFS 單點故障問題。

為解決 K8s 中使用 NFS 造成的單點故障問題，這邊使用 Longhorn 作為代替 NFS，並且 Longhorn 本身可以做 HA 將 Replica 分散到各 Nodes，以解決此單點故障問題。

# 需求

主要目的是要讓原本得 NFS 符合 HA 需求，避免單點故障問題。將原本 NFS 機制改為 Longhorn。

1. 容器平台為 K8s。
2. 資料儲存方式為每個 Node 各一個 ( Replica )。

# 預先準備

一個 K8s Cluster 環境，多 Nodes。

具備一定 K8s 相關知識。

# 初步規劃 / 方向制定

Longhorn 好處是他的實作對於 AP 程式跟 NFS 是一模一樣的，都是應用端程式一樣直接儲存檔案到某個容器內已經掛載的路徑即可，AP 程式完全不需要做相應更動。

如果今天是直接使用 S3 的 Solution 來儲存檔案，就會需要讓 AP 程式有個儲存介面層來控制儲存的方式。Longhorn 的優勢就是指需要改架構就可以跟 NFS 無縫接軌。

# 實作前規劃

我們總共會有 4 個階段來，實作 Longhorn HA 作業。

**步驟一** 安裝/啟用 Dependency 套件、加入 Linux 模組 : 這個步驟只是安裝 Dependency。

**步驟二** 測試模組、套件是否順利運作 ( Optional ) : 沒有硬性要執行，驗證步驟一的東西是否都正確安裝。

**步驟三** 建立 Longhorn Chart : 真正建立 Longhorn，這邊也會決定 HA 會用到幾個 Nodes。

**步驟四** 在 Longhorn 建立一個可掛載空間 : 這邊真正實作 PVC 給其他 AP 程式使用。

# 功能實作

### 第一步 : 安裝/啟用 Dependency 套件、加入 Linux 模組

安裝/啟用 Dependency 套件

```
sudo apt update 
(取得最新清單)

sudo apt install -y open-iscsi nfs-common
(如果有依賴錯誤 Run sudo apt --fix-broken install)

sudo apt install -y cryptsetup
sudo systemctl enable --now iscsid
sudo systemctl status iscsid
```

Linux 加入模組

```
# 載入 iscsi_tcp 模組
sudo modprobe iscsi_tcp
echo "iscsi_tcp" | sudo tee /etc/modules-load.d/iscsi_tcp.conf

# 載入 nfs 模組
sudo modprobe nfs
echo "nfs" | sudo tee /etc/modules-load.d/nfs.conf

# 載入 dm_crypt 模組
sudo modprobe dm_crypt
echo "dm_crypt" | sudo tee /etc/modules-load.d/dm_crypt.conf
```

### 第二步 : 測試模組、套件是否順利運作 ( Optional )

1. 預先建立一個 namespace 提供測試 (可以不用刪除，測完直接繼續)

   **注意 : Longhorn 行為預設一定要 namespace 是自己的 "longhorn-system”，不能依自己喜好更換 ( 實測換了會有問題 )。**

2. 下載/取得 longhornctl 檔案 ( 根據 OS 類型下載 ctl，可以在官網查詢各 OS 的下載 URL )

    ```
    curl -LO "https://github.com/longhorn/cli/releases/download/v1.12.0/longhornctl-linux-amd64"
    ```

3. Run 檢查指令

   這個步驟 longhorn 會下載 image，建立一個暫時的 Pod 來測試功能，測完 Pod 即會自己被 Delete，要注意有連

   網才行。

    ```
    chmod +x longhornctl
    
    # 執行檢查
    ./longhornctl check preflight
    ```

4. 若都正常顯示以下 console (若有問題會顯示: error) :

    ```
    INFO[2026-06-30T17:33:57+08:00] Initializing preflight checker
    INFO[2026-06-30T17:33:57+08:00] Cleaning up preflight checker
    INFO[2026-06-30T17:33:57+08:00] Running preflight checker
    INFO[2026-06-30T17:34:01+08:00] Retrieved preflight checker result:
    result:
      info:
      - '[IscsidService] Service iscsid is running'
      - '[MultipathService] multipathd.service is not found (exit code: 4)'
      - '[MultipathService] multipathd.socket is not found (exit code: 4)'
      - '[NFSv4] NFS4 is supported'
      - '[Packages] nfs-common is installed'
      - '[Packages] open-iscsi is installed'
      - '[Packages] cryptsetup is installed'
      - '[Packages] dmsetup is installed'
      - '[KernelModules] nfs is loaded'
      - '[KernelModules] dm_crypt is loaded'
      warn:
      - '[KubeDNS] Kube DNS "coredns" is set with fewer than 2 replicas; consider increasing replica count for high availability'
    INFO[2026-06-30T17:34:01+08:00] Cleaning up preflight checker
    INFO[2026-06-30T17:34:01+08:00] Completed preflight checker
    ```


### 第三步 : 建立 Longhorn Chart

這個子 Chart 因為有許多 CRD 是需要持久化的，這些 CRD 並不適合隨 Helm Up/Down，所以這邊設計上會把這個 Chart 永久掛在 K8s 上，而不是放在 Helm 裡面。

新增子 Chart 資料夾 longhorn

```
longhorn/
  ├── Chart.yaml
  └── values.yaml
```

Chart.yaml 內容

```
apiVersion: v2
name: longhorn
description: Longhorn distributed block storage for Kubernetes
type: application
version: 0.1.0
appVersion: "1.29.1"

# helm repo add longhorn https://charts.longhorn.io
# helm dependency update .
dependencies:
  - name: longhorn
    version: 1.12.0
    repository: https://charts.longhorn.io
```

values.yaml

這邊特別設定 reclaimPolicy: Retain，一般 PVC 綁 longhorn 的時候，longhorn 會配給 PVC 一個 PV，若 PVC 因為意外消失、壞掉，reclaimPolicy 預設 Delete 會直接把對應的 PV 刪除，而相對應的資料也會被刪除。
所以為了發生意外資料仍然能夠保存，這邊必須設為 Retain，如果 PVC 丟掉，PV 還會留著，我們再把 PVC 建回來指向特定 PV 即可。

defaultReplicaCount 則是 Longhorn Replica 的數量，這邊設定 3 ，HA 就會由 Longhorn 的機制自己實作 3 個 Replica。

```
longhorn:
  defaultSettings:
    defaultDataPath: "/var/lib/longhorn"
    defaultReplicaCount: 3
  persistence:
    reclaimPolicy: Retain
```

install-longhorn.sh

```
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

helm upgrade --install longhorn . \
  --namespace longhorn-system \
  --create-namespace \
  -f values.yaml

echo ""
echo "[完成] Longhorn 安裝-升級結束"
```

#### Pull/Update Longhorn Chart

在 longhorn 目錄下執行更新指令 :

這個步驟會在網路上 Pull 下這個 Chart 所需資源，所以執行此動作的時候務必在有連網的狀況下執行。

```
helm dependency update .
```

執行成功顯示 :

```
Getting updates for unmanaged Helm repositories...
...Successfully got an update from the "https://charts.longhorn.io" chart repository
Saving 1 charts
Downloading longhorn from repo https://charts.longhorn.io
Deleting outdated charts
```

執行成功後，目錄結構會長這樣 :

```
longhorn/
	├── Chart.yaml
	├── values.yaml
	├── Chart.lock
	└── charts
			└── longhorn-1.12.0.tgz
```

#### Apply Longhorn Chart / 取得 Images

在 longhorn 目錄下執行 Apply 指令 :

這個步驟會把 Longhorn Apply 進 K3s，同時會 Pull Images 來建立 Pod。

建議這邊的作法，可以是在可以連網的測試環境先執行一次自動 Pull Images，再把 images 下載打包，再拿到無法連網的環境 匯入 images，就可以在離線情況下 Apply Longhorn。

```
./install-longhorn.sh
```

可以看到 Pod 被起起來 :

```
	longhorn-system   csi-attacher-647d7767b9-gjzwb                       1/1     Running   0               91s
	longhorn-system   csi-attacher-647d7767b9-ndr8w                       1/1     Running   0               91s
	longhorn-system   csi-attacher-647d7767b9-v5h79                       1/1     Running   0               91s
	longhorn-system   csi-provisioner-76bc4b5886-9xrhx                    1/1     Running   0               91s
	longhorn-system   csi-provisioner-76bc4b5886-c28f4                    1/1     Running   0               91s
	longhorn-system   csi-provisioner-76bc4b5886-pf4fx                    1/1     Running   0               91s
	longhorn-system   csi-resizer-78cd7545b7-9nk7d                        1/1     Running   0               91s
	longhorn-system   csi-resizer-78cd7545b7-blq2q                        1/1     Running   0               91s
	longhorn-system   csi-resizer-78cd7545b7-jhkcc                        1/1     Running   0               91s
	longhorn-system   csi-snapshotter-7b7db78f9-7fmsr                     1/1     Running   0               91s
	longhorn-system   csi-snapshotter-7b7db78f9-hmfkz                     1/1     Running   0               91s
	longhorn-system   csi-snapshotter-7b7db78f9-s4n6c                     1/1     Running   0               91s
	longhorn-system   engine-image-ei-db6c2b6f-8bbhc                      1/1     Running   0               2m14s
	longhorn-system   engine-image-ei-db6c2b6f-nsrql                      1/1     Running   0               2m14s
	longhorn-system   engine-image-ei-db6c2b6f-wwb8p                      1/1     Running   0               2m14s
	longhorn-system   instance-manager-b9acf05a6026347a85dc714b10e5aabb   1/1     Running   0               104s
	longhorn-system   instance-manager-d5d561154728dd08440965db64fd3961   1/1     Running   0               89s
	longhorn-system   instance-manager-e5689ccd7d2a3c0bfb0482007cfe37fc   1/1     Running   0               96s
	longhorn-system   longhorn-csi-plugin-fljvh                           3/3     Running   0               91s
	longhorn-system   longhorn-csi-plugin-g7zh7                           3/3     Running   0               91s
	longhorn-system   longhorn-csi-plugin-r7gr5                           3/3     Running   0               91s
	longhorn-system   longhorn-driver-deployer-85c5f4ff6f-fnmrs           1/1     Running   0               2m53s
	longhorn-system   longhorn-manager-7q9jc                              2/2     Running   1 (2m11s ago)   2m53s
	longhorn-system   longhorn-manager-r7csg                              2/2     Running   0               2m53s
	longhorn-system   longhorn-manager-tw6lq                              2/2     Running   0               2m53s
	longhorn-system   longhorn-ui-5984465c7b-bqfjd                        1/1     Running   0               2m53s
	longhorn-system   longhorn-ui-5984465c7b-sl5ht                        1/1     Running   0               2m53s

```

被 Pull 下來的 images 有這些 :

```
docker.io/longhornio/csi-attacher                             v4.12.0                7272884ab4c3e       38.6MB
docker.io/longhornio/csi-node-driver-registrar                v2.17.0                905ecc40d0b09       14.6MB
docker.io/longhornio/csi-provisioner                          v5.3.0-20260514        dfa8c879cefcc       34.2MB
docker.io/longhornio/csi-resizer                              v2.1.0-20260514        c5791699c6361       37.6MB
docker.io/longhornio/csi-snapshotter                          v8.5.0-20260514        8dd49a0661ace       37.6MB
docker.io/longhornio/livenessprobe                            v2.19.0                b6d35c6d5906d       14.8MB
docker.io/longhornio/longhorn-cli                             v1.12.0                e37c3f7ba221d       84.9MB
docker.io/longhornio/longhorn-engine                          v1.12.0                ee6049245e503       164MB
docker.io/longhornio/longhorn-instance-manager                v1.12.0                708921813dab0       483MB
docker.io/longhornio/longhorn-manager                         v1.12.0                dff47e616e7cd       120MB
docker.io/longhornio/longhorn-share-manager                   v1.12.0                4e711499a4f56       112MB
docker.io/longhornio/longhorn-ui                              v1.12.0                81c63a0bbf71b       75.3MB

```

### 第四步 : 在 Longhorn 建立一個可掛載空間

#### 建立 PVC 去取得 Longhorn PV

要取得一個 Longhorn 掛載空間很簡單，直接建立一個 PVC 並且指定 storageClass 是 Longhorn，Longhorn 就會自動分配一個空間 ( PV ) 給這個 PVC。

這邊建議 PVC 以 Apply 的方式，維持 PVC 永久存在，不要用 Deployment，因為一旦 PVC 被消滅，Longhorn 的 PV 就會失去與原本 PVC 的連結，就算再新增一個新的 PVC，Longhorn 會直接新增一個 PV 給新的 PVC 而非用原本的 PVC ( 除非特別指定 )。

longhorn-pvc.yaml

```
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: longhorn-pvc
  namespace: yournamespace
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
  volumeMode: Filesystem
  storageClassName: longhorn
```

apply-longhorn-pvc.sh

```
#!/bin/bash

echo "=================================================="
echo "🚀 開始執行正式環境永久 PVC 標準化部署"
echo "=================================================="

# 1. 直接以相對路徑檢查同目錄下的 YAML
if [ ! -f "longhorn-pvc.yaml" ]; then
    echo "❌ 錯誤：在當前目錄找不到 longhorn-pvc.yaml"
    exit 1
fi

# 2. 執行相對路徑套用
echo "📦 正在套用 Kubernetes 資源..."
kubectl apply -f longhorn-pvc.yaml
```

#### 建立 PVC

執行 Apply 指令

```
apply-longhorn-pvc.sh
```

可以查詢 PVC 來確認

```
kubectl get pvc -A
```

顯示如下 :

STATUS  為 Bound 代表現在是綁定狀態，VOLUME 則可以看到 Longhorn 自動生成的 PV ( pvc-3b905b02-d74b-4847-9811-162a57b2f6ba )

```
NAMESPACE      NAME                                                    STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
yournamespace  longhorn-pvc                                            Bound    pvc-3b905b02-d74b-4847-9811-162a57b2f6ba   10Gi       RWX            longhorn       <unset>                 61s
```

這樣一來這個 Longhorn PVC 就可以被其他 Pod 掛載使用。

