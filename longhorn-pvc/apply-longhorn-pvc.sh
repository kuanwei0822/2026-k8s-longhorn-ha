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