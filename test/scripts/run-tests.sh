#!/bin/bash

# Copyright 2018 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This shell script is used to build a cluster and create a namespace from our
# argo workflow


set -o errexit
set -o nounset
set -o pipefail

CLUSTER_NAME="${CLUSTER_NAME}"
ZONE="${GCP_ZONE}"
PROJECT="${GCP_PROJECT}"
NAMESPACE="${DEPLOY_NAMESPACE}"
REGISTRY="${GCP_REGISTRY}"
VERSION=$(git describe --tags --always --dirty)
GO_DIR=${GOPATH}/src/github.com/${REPO_OWNER}/${REPO_NAME}

echo "Activating service-account"
gcloud auth activate-service-account --key-file=${GOOGLE_APPLICATION_CREDENTIALS}

echo "Configuring kubectl"
gcloud --project ${PROJECT} container clusters get-credentials ${CLUSTER_NAME} \
    --zone ${ZONE}

kubectl config set-credentials temp-admin --username=admin --password=$(gcloud container clusters describe ${CLUSTER_NAME} --format="value(masterAuth.password)" --zone=${ZONE})
kubectl config set-context temp-context --cluster=$(kubectl config get-clusters | grep ${CLUSTER_NAME}) --user=temp-admin
kubectl config use-context temp-context

echo "Install Katib "
sed -i -e "s@image: katib\/vizier-core@image: ${REGISTRY}\/${REPO_NAME}\/vizier-core:${VERSION}@" manifests/vizier/core/deployment.yaml
sed -i -e "s@type: NodePort@type: ClusterIP@" -e "/nodePort: 30678/d" manifests/vizier/core/service.yaml
sed -i -e "s@image: katib\/suggestion-random@image: ${REGISTRY}\/${REPO_NAME}\/suggestion-random:${VERSION}@" manifests/vizier/suggestion/random/deployment.yaml
sed -i -e "s@image: katib\/suggestion-grid@image: ${REGISTRY}\/${REPO_NAME}\/suggestion-grid:${VERSION}@" manifests/vizier/suggestion/grid/deployment.yaml
#sed -i -e "s@image: katib\/suggestion-hyperband@image: ${REGISTRY}\/${REPO_NAME}\/suggestion-hyperband:${VERSION}@" manifests/vizier/suggestion/hyperband/deployment.yaml
#sed -i -e "s@image: katib\/suggestion-bayesianoptimization@image: ${REGISTRY}\/${REPO_NAME}\/suggestion-bayesianoptimization:${VERSION}@" manifests/vizier/suggestion/bayesianoptimization/deployment.yaml
sed -i -e "s@image: katib\/earlystopping-medianstopping@image: ${REGISTRY}\/${REPO_NAME}\/earlystopping-medianstopping:${VERSION}@" manifests/vizier/earlystopping/medianstopping/deployment.yaml
sed -i -e "s@image: katib\/katib-frontend@image: ${REGISTRY}\/${REPO_NAME}\/katib-frontend:${VERSION}@" manifests/modeldb/frontend/deployment.yaml
./scripts/deploy.sh

TIMEOUT=120
PODNUM=$(kubectl get deploy -n katib | grep -v NAME | wc -l)
until kubectl get pods -n katib | grep Running | [[ $(wc -l) -eq $PODNUM ]]; do
    echo Pod Status $(kubectl get pods -n katib | grep Running | wc -l)/$PODNUM
    sleep 10
    TIMEOUT=$(( TIMEOUT - 1 ))
    if [[ $TIMEOUT -eq 0 ]];then
        echo "NG"
        kubectl get pods -n katib
        exit 1
    fi
done

echo "All Katib components are running."
kubectl version
echo "Katib deployments"
kubectl -n katib get deploy
echo "Katib services"
kubectl -n katib get svc
echo "Katib pods"
kubectl -n katib get pod

kubectl -n katib port-forward $(kubectl -n katib get pod -o=name | grep vizier-core | sed -e "s@pods\/@@") 6789:6789 &
echo "kubectl port-forward start"
TIMEOUT=120
until curl localhost:6789 || [ $TIMEOUT -eq 0 ]; do
    sleep 5
    TIMEOUT=$(( TIMEOUT - 1 ))
done 
cp -r test ${GO_DIR}/test
cd ${GO_DIR}/test/e2e
go run test-client.go -a random
go run test-client.go -a grid
