#!/usr/bin/env bash
set -ex -o pipefail -o errtrace -o functrace

function catch() {
    echo "error $1 on line $2"
    exit 255
}

trap 'catch $? $LINENO' ERR TERM INT

# build-manifests is designed to populate the deploy directory
# with all of the manifests necessary for use in development
# and for consumption with the operator-lifecycle-manager.
#
# First, we create a temporary directory and filling it with
# all of the component operator's ClusterServiceVersion (CSV for OLM)
# and CustomResourceDefinitions (CRDs); being sure to copy the CRDs
# into the deploy/crds directory.
#
# The CSV manifests contain all of the information we need to 1) generate
# a combined CSV and 2) other development related manifests (like the
# operator deployment + rbac).
#
# Second, we pass all of the component CSVs off to the manifest-templator
# that handles the deployment specs, service account names, permissions, and
# clusterPermissions by converting them into their corresponding Kubernetes
# manifests (ie. permissions + serviceAccountName = role + service account
# + role binding) before writing them to disk.
#
# Lastly, we take give the component CSVs to the csv-merger that combines all
# of the manifests into a single, unified, ClusterServiceVersion.

function get_image_digest() {
  local inspect
  local digest
  local image

  inspect=$(docker run --rm quay.io/skopeo/stable:latest inspect "docker://$1")
  digest=$(echo "${inspect}" | jq -r '.Digest')
  image="${1/:*/}@${digest}"
  echo "${image}" >> ${IMAGES_FILE}
  echo "${image}"
}

PROJECT_ROOT="$(readlink -e $(dirname "${BASH_SOURCE[0]}")/../)"
source "${PROJECT_ROOT}"/hack/config

DEPLOY_DIR="${PROJECT_ROOT}/deploy"
CRD_DIR="${DEPLOY_DIR}/crds"
OLM_DIR="${DEPLOY_DIR}/olm-catalog"
CSV_DIR="${OLM_DIR}/kubevirt-hyperconverged/${CSV_VERSION}"
DEFAULT_CSV_GENERATOR="/usr/bin/csv-generator"

INDEX_IMAGE_DIR=${DEPLOY_DIR}/index-image

OPERATOR_NAME="${NAME:-kubevirt-hyperconverged-operator}"
OPERATOR_NAMESPACE="${NAMESPACE:-kubevirt-hyperconverged}"
OPERATOR_IMAGE="${OPERATOR_IMAGE:-quay.io/kubevirt/hyperconverged-cluster-operator:$CSV_VERSION}"
IMAGE_PULL_POLICY="${IMAGE_PULL_POLICY:-IfNotPresent}"

KUBEVIRT_IMAGE="${KUBEVIRT_IMAGE:-docker.io/kubevirt/virt-operator:${KUBEVIRT_VERSION}}"
CNA_IMAGE="${CNA_IMAGE:-quay.io/kubevirt/cluster-network-addons-operator:${NETWORK_ADDONS_VERSION}}"
SSP_IMAGE="${SSP_IMAGE:-quay.io/fromani/kubevirt-ssp-operator-container:${SSP_VERSION}}"
CDI_IMAGE="${CDI_IMAGE:-docker.io/kubevirt/cdi-operator:${CDI_VERSION}}"
NMO_IMAGE="${NMO_IMAGE:-quay.io/kubevirt/node-maintenance-operator:${NMO_VERSION}}"
HPPO_IMAGE="${HPP_IMAGE:-quay.io/kubevirt/hostpath-provisioner-operator:${HPPO_VERSION}}"
HPP_IMAGE="${HPP_IMAGE:-quay.io/kubevirt/hostpath-provisioner:${HPP_VERSION}}"
CONVERSION_CONTAINER="${CONVERSION_CONTAINER:-quay.io/kubevirt/kubevirt-v2v-conversion:${CONVERSION_CONTAINER_VERSION}}"
VMWARE_CONTAINER="${VMWARE_CONTAINER:-quay.io/kubevirt/kubevirt-vmware:${VMWARE_CONTAINER_VERSION}}"
VM_IMPORT_IMAGE="${VM_IMPORT_IMAGE:-quay.io/kubevirt/vm-import-operator:${VM_IMPORT_VERSION}}"

# Important extensions
CSV_EXT="clusterserviceversion.yaml"
CSV_CRD_EXT="csv_crds.yaml"
CRD_EXT="crd.yaml"

function gen_csv() {
  # Handle arguments
  local csvGeneratorPath="$1" && shift
  local operatorName="$1" && shift
  local imagePullUrl="$1" && shift
  local dumpCRDsArg="$1" && shift
  local operatorArgs="$@"

  # Handle important vars
  local csv="${operatorName}.${CSV_EXT}"
  local csvWithCRDs="${operatorName}.${CSV_CRD_EXT}"
  local crds="${operatorName}.crds.yaml"

  # TODO: Use oc to run if cluster is available
  local dockerArgs="docker run --rm --entrypoint=${csvGeneratorPath} ${imagePullUrl} ${operatorArgs}"

  eval $dockerArgs > $csv
  eval $dockerArgs $dumpCRDsArg > $csvWithCRDs

  # diff returns 1 when there is a diff, and there is always diff here. Added `|| :` to cancel trap here.
  diff -u $csv $csvWithCRDs | grep -E "^\+" | sed -E 's/^\+//' | tail -n+2 > $crds || :

  csplit --digits=2 --quiet --elide-empty-files \
    --prefix="${operatorName}" \
    --suffix-format="%02d.${CRD_EXT}" \
    $crds \
    "/---/" "{*}"
}

function get-virt-operator-sha() {
  local digest
  local image="${KUBEVIRT_IMAGE%/*}/virt-$1:${KUBEVIRT_IMAGE/*:}"
  digest=$(get_image_digest "${image}")
  if [[ $? != 0 ]]; then return $?; fi
  echo "${digest/*@/}"
}

function create_virt_csv() {
  local operatorName="kubevirt"
  local imagePullUrl="${KUBEVIRT_IMAGE}"
  local dumpCRDsArg="--dumpCRDs"
  local virtDigest
  virtDigest=$(get_image_digest "${KUBEVIRT_IMAGE}")
  if [[ $? != 0 ]]; then exit $?;fi
  local apiSha
  apiSha=$(get-virt-operator-sha "api")
  local controllerSha
  controllerSha=$(get-virt-operator-sha "controller")
  local launcherSha
  launcherSha=$(get-virt-operator-sha "launcher")
  local handlerSha
  handlerSha=$(get-virt-operator-sha "handler")
  local operatorArgs
  operatorArgs=" \
    --namespace=${OPERATOR_NAMESPACE} \
    --csvVersion=${CSV_VERSION} \
    --operatorImageVersion=${virtDigest/*@/} \
    --dockerPrefix=${KUBEVIRT_IMAGE%\/*} \
    --kubeVirtVersion=${KUBEVIRT_VERSION} \
    --apiSha=${apiSha} \
    --controllerSha=${controllerSha} \
    --handlerSha=${handlerSha} \
    --launcherSha=${launcherSha} \
  "

  gen_csv "${DEFAULT_CSV_GENERATOR}" "${operatorName}" "${imagePullUrl}" "${dumpCRDsArg}" "${operatorArgs}"
  echo "${operatorName}"
}

function create_cna_csv() {
  local operatorName="cluster-network-addons"
  local imagePullUrl="${CNA_IMAGE}"
  local dumpCRDsArg="--dump-crds"
  local cnaDigest
  cnaDigest=$(get_image_digest "${CNA_IMAGE}")
  local containerPrefix="${cnaDigest%/*}"
  local imageName="${cnaDigest#${containerPrefix}/}"
  local tag="${CNA_IMAGE/*:/}"
  local operatorArgs=" \
    --namespace=${OPERATOR_NAMESPACE} \
    --version=${CSV_VERSION} \
    --version-replaces=${REPLACES_VERSION} \
    --image-pull-policy=IfNotPresent \
    --operator-version=${tag} \
    --container-tag=${cnaDigest/*:/} \
    --container-prefix=${containerPrefix} \
    --image-name=${imageName/:*/}
  "

  gen_csv ${DEFAULT_CSV_GENERATOR} ${operatorName} ${imagePullUrl} ${dumpCRDsArg} ${operatorArgs}
  echo "${operatorName}"
}

function create_ssp_csv() {
  local operatorName="scheduling-scale-performance"
  local imagePullUrl="${SSP_IMAGE}"
  local dumpCRDsArg="--dump-crds"
  local sspDigest
  sspDigest=$(get_image_digest "${SSP_IMAGE}")
  local operatorArgs=" \
    --namespace=${OPERATOR_NAMESPACE} \
    --csv-version=${CSV_VERSION} \
    --operator-image=${sspDigest} \
    --operator-version=${SSP_VERSION} \
  "

  gen_csv ${DEFAULT_CSV_GENERATOR} ${operatorName} ${imagePullUrl} ${dumpCRDsArg} ${operatorArgs}
  echo "${operatorName}"
}

function create_cdi_csv() {
  local operatorName="containerized-data-importer"
  local imagePullUrl="${CDI_IMAGE}"
  local containerPrefix="${CDI_IMAGE%/*}"
  local tag="${CDI_IMAGE/*:/}"

  local cdiDigest
  cdiDigest=$(get_image_digest "${CDI_IMAGE}")
  local controllerDigest
  controllerDigest=$(get_image_digest "${containerPrefix}/cdi-controller:${tag}")
  local apiserverDigest
  apiserverDigest=$(get_image_digest "${containerPrefix}/cdi-apiserver:${tag}")
  local clonerDigest
  clonerDigest=$(get_image_digest "${containerPrefix}/cdi-cloner:${tag}")
  local importerDigest
  importerDigest=$(get_image_digest "${containerPrefix}/cdi-importer:${tag}")
  local uploadproxyDigest
  uploadproxyDigest=$(get_image_digest "${containerPrefix}/cdi-uploadproxy:${tag}")
  local uploadserverDigest
  uploadserverDigest=$(get_image_digest "${containerPrefix}/cdi-uploadserver:${tag}")
  local dumpCRDsArg="--dump-crds"
  local operatorArgs=" \
    --namespace=${OPERATOR_NAMESPACE} \
    --csv-version=${CSV_VERSION} \
    --pull-policy=IfNotPresent \
    --operator-image=${cdiDigest} \
    --controller-image=${controllerDigest} \
    --apiserver-image=${apiserverDigest} \
    --cloner-image=${clonerDigest} \
    --importer-image=${importerDigest} \
    --uploadproxy-image=${uploadproxyDigest} \
    --uploadserver-image=${uploadserverDigest} \
    --operator-version=${CDI_VERSION} \
  "
  gen_csv ${DEFAULT_CSV_GENERATOR} ${operatorName} ${imagePullUrl} ${dumpCRDsArg} ${operatorArgs}
  echo "${operatorName}"
}

function create_nmo_csv() {
  local operatorName="node-maintenance"
  local imagePullUrl="${NMO_IMAGE}"
  local dumpCRDsArg="--dump-crds"
  local operatorArgs=" \
    --namespace=${OPERATOR_NAMESPACE} \
    --csv-version=${CSV_VERSION} \
    --operator-image=${NMO_IMAGE} \
  "
  local csvGeneratorPath="/usr/local/bin/csv-generator"

  gen_csv ${csvGeneratorPath} ${operatorName} ${imagePullUrl} ${dumpCRDsArg} ${operatorArgs}
  echo "${operatorName}"
}

function create_hpp_csv() {
  local operatorName="hostpath-provisioner"
  local imagePullUrl="${HPPO_IMAGE}"
  local dumpCRDsArg="--dump-crds"
  local hppoDigest
  hppoDigest=$(get_image_digest "${HPPO_IMAGE}")
  local hppDigest
  hppDigest=$(get_image_digest "${HPP_IMAGE}")
  local operatorArgs=" \
    --csv-version=${CSV_VERSION} \
    --operator-image-name=${hppoDigest} \
    --provisioner-image-name=${hppDigest} \
    --namespace=${OPERATOR_NAMESPACE} \
    --pull-policy=IfNotPresent \
  "

  gen_csv ${DEFAULT_CSV_GENERATOR} ${operatorName} ${imagePullUrl} ${dumpCRDsArg} ${operatorArgs}
  echo "${operatorName}"
}

function create_vm_import_csv() {
  local operatorName="vm-import-operator"
  local imagePullUrl="${VM_IMPORT_IMAGE}"
  local containerPrefix="${VM_IMPORT_IMAGE%/*}"
  local operatorDigest
  operatorDigest=$(get_image_digest "${VM_IMPORT_IMAGE}")
  local tag="${VM_IMPORT_IMAGE/*:/}"
  local controllerDigest
  controllerDigest=$(get_image_digest "${containerPrefix}/vm-import-controller:${tag}")
  local virtv2vImage
  virtv2vImage=$(get_image_digest "${containerPrefix}/vm-import-virtv2v:${tag}")

  local dumpCRDsArg="--dump-crds"
  local operatorArgs=" \
    --csv-version=${CSV_VERSION} \
    --operator-version=${VM_IMPORT_VERSION} \
    --operator-image=${operatorDigest} \
    --controller-image=${controllerDigest} \
    --namespace=${OPERATOR_NAMESPACE} \
    --virtv2v-image=${virtv2vImage} \
    --pull-policy=IfNotPresent \
  "

  gen_csv ${DEFAULT_CSV_GENERATOR} ${operatorName} ${imagePullUrl} ${dumpCRDsArg} ${operatorArgs}
  echo "${operatorName}"
}

TEMPDIR=$(mktemp -d) || (echo "Failed to create temp directory" && exit 1)
pushd $TEMPDIR
export IMAGES_FILE="${TEMPDIR}/images.txt"
touch ${IMAGES_FILE}
virtFile=$(create_virt_csv)
virtCsv="${TEMPDIR}/${virtFile}.${CSV_EXT}"
cnaFile=$(create_cna_csv)
cnaCsv="${TEMPDIR}/${cnaFile}.${CSV_EXT}"
sspFile=$(create_ssp_csv)
sspCsv="${TEMPDIR}/${sspFile}.${CSV_EXT}"
cdiFile=$(create_cdi_csv)
cdiCsv="${TEMPDIR}/${cdiFile}.${CSV_EXT}"
nmoFile=$(create_nmo_csv)
nmoCsv="${TEMPDIR}/${nmoFile}.${CSV_EXT}"
hhpFile=$(create_hpp_csv)
hppCsv="${TEMPDIR}/${hhpFile}.${CSV_EXT}"
vmImportFile=$(create_vm_import_csv)
importCsv="${TEMPDIR}/${vmImportFile}.${CSV_EXT}"
csvOverrides="${TEMPDIR}/csv_overrides.${CSV_EXT}"

cat > ${csvOverrides} <<- EOM
---
spec:
  links:
  - name: KubeVirt project
    url: https://kubevirt.io
  - name: Source Code
    url: https://github.com/kubevirt/hyperconverged-cluster-operator
  maintainers:
  - email: kubevirt-dev@googlegroups.com
    name: KubeVirt project
  maturity: alpha
  provider:
    name: KubeVirt project
EOM

# Write HCO CRDs
(cd ${PROJECT_ROOT}/tools/csv-merger/ && go build)
hco_crds=${TEMPDIR}/hco.crds.yaml
(cd ${PROJECT_ROOT} && ${PROJECT_ROOT}/tools/csv-merger/csv-merger  --api-sources=${PROJECT_ROOT}/pkg/apis/... --output-mode=CRDs > $hco_crds)
csplit --digits=2 --quiet --elide-empty-files \
  --prefix=hco \
  --suffix-format="%02d.${CRD_EXT}" \
  $hco_crds \
  "/^---$/" "{*}"

popd

rm -fr "${CSV_DIR}"
mkdir -p "${CSV_DIR}/metadata"

cat << EOF > "${CSV_DIR}/metadata/annotations.yaml"
annotations:
  operators.operatorframework.io.bundle.channel.default.v1: ${CSV_VERSION}
  operators.operatorframework.io.bundle.channels.v1: ${CSV_VERSION}
  operators.operatorframework.io.bundle.manifests.v1: manifests/
  operators.operatorframework.io.bundle.mediatype.v1: registry+v1
  operators.operatorframework.io.bundle.metadata.v1: metadata/
  operators.operatorframework.io.bundle.package.v1: kubevirt-hyperconverged
EOF

SMBIOS=$(cat <<- EOM
Family: KubeVirt
Manufacturer: KubeVirt
Product: None
EOM
)

IMAGE_NAME=$(get_image_digest "${OPERATOR_IMAGE}")
conversionContainer=$(get_image_digest "${CONVERSION_CONTAINER}")
vmwareContainer=$(get_image_digest "${VMWARE_CONTAINER}")

IMAGE_LIST=$(cat ${IMAGES_FILE} | tr '\n' ',')

# validate CSVs. Make sure each one of them contain an image (and so, also not empty):
csvs=("${cnaCsv}" "${virtCsv}" "${sspCsv}" "${cdiCsv}" "${nmoCsv}" "${hppCsv}" "${importCsv}")
for csv in "${csvs[@]}"; do
  grep -E "^ *image: [a-zA-Z0-9/\.:@\-]+$" ${csv}
done

# Build and write deploy dir
(cd ${PROJECT_ROOT}/tools/manifest-templator/ && go build)
${PROJECT_ROOT}/tools/manifest-templator/manifest-templator \
  --api-sources=${PROJECT_ROOT}/pkg/apis/... \
  --cna-csv="$(<${cnaCsv})" \
  --virt-csv="$(<${virtCsv})" \
  --ssp-csv="$(<${sspCsv})" \
  --cdi-csv="$(<${cdiCsv})" \
  --nmo-csv="$(<${nmoCsv})" \
  --hpp-csv="$(<${hppCsv})" \
  --vmimport-csv="$(<${importCsv})" \
  --ims-conversion-image-name="${conversionContainer}" \
  --ims-vmware-image-name="${vmwareContainer}" \
  --operator-namespace="${OPERATOR_NAMESPACE}" \
  --smbios="${SMBIOS}" \
  --hco-kv-io-version="${CSV_VERSION}" \
  --kubevirt-version="${KUBEVIRT_VERSION}" \
  --cdi-version="${CDI_VERSION}" \
  --cnao-version="${NETWORK_ADDONS_VERSION}" \
  --ssp-version="${SSP_VERSION}" \
  --nmo-version="${NMO_VERSION}" \
  --hppo-version="${HPPO_VERSION}" \
  --vm-import-version="${VM_IMPORT_VERSION}" \
  --operator-image="${IMAGE_NAME}"
(cd ${PROJECT_ROOT}/tools/manifest-templator/ && go clean)

# Build and merge CSVs
${PROJECT_ROOT}/tools/csv-merger/csv-merger \
  --cna-csv="$(<${cnaCsv})" \
  --virt-csv="$(<${virtCsv})" \
  --ssp-csv="$(<${sspCsv})" \
  --cdi-csv="$(<${cdiCsv})" \
  --nmo-csv="$(<${nmoCsv})" \
  --hpp-csv="$(<${hppCsv})" \
  --vmimport-csv="$(<${importCsv})" \
  --ims-conversion-image-name="${conversionContainer}" \
  --ims-vmware-image-name="${vmwareContainer}" \
  --csv-version=${CSV_VERSION} \
  --replaces-csv-version=${REPLACES_CSV_VERSION} \
  --hco-kv-io-version="${CSV_VERSION}" \
  --spec-displayname="KubeVirt HyperConverged Cluster Operator" \
  --spec-description="$(<${PROJECT_ROOT}/docs/operator_description.md)" \
  --crd-display="HyperConverged Cluster Operator" \
  --smbios="${SMBIOS}" \
  --csv-overrides="$(<${csvOverrides})" \
  --kubevirt-version="${KUBEVIRT_VERSION}" \
  --cdi-version="${CDI_VERSION}" \
  --cnao-version="${NETWORK_ADDONS_VERSION}" \
  --ssp-version="${SSP_VERSION}" \
  --nmo-version="${NMO_VERSION}" \
  --hppo-version="${HPPO_VERSION}" \
  --vm-import-version="${VM_IMPORT_VERSION}" \
  --related-images-list="${IMAGE_LIST}" \
  --operator-image-name="${IMAGE_NAME}" > "${CSV_DIR}/${OPERATOR_NAME}.v${CSV_VERSION}.${CSV_EXT}"

# Copy all CRDs into the CRD and CSV directories
rm -f ${CRD_DIR}/*
cp -f ${TEMPDIR}/*.${CRD_EXT} ${CRD_DIR}
cp -f ${TEMPDIR}/*.${CRD_EXT} ${CSV_DIR}

# Validate the yaml files
pip install --user yamllint
(cd ${CRD_DIR} && yamllint -d "{extends: relaxed, rules: {line-length: disable}}" *.yaml)
(cd ${CSV_DIR} && yamllint -d "{extends: relaxed, rules: {line-length: disable}}" *.yaml)

# Check there are not API Groups overlap between different CNV operators
${PROJECT_ROOT}/tools/csv-merger/csv-merger --crds-dir=${CRD_DIR}
(cd ${PROJECT_ROOT}/tools/csv-merger/ && go clean)

# Intentionally removing last so failure leaves around the templates
rm -rf ${TEMPDIR}

rm -rf "${INDEX_IMAGE_DIR:?}"
mkdir -p "${INDEX_IMAGE_DIR:?}/kubevirt-hyperconverged"
cp -r "${CSV_DIR}" "${INDEX_IMAGE_DIR:?}/kubevirt-hyperconverged/"
cp "${OLM_DIR}/bundle.Dockerfile" "${INDEX_IMAGE_DIR:?}/"

INDEX_IMAGE_CSV="${INDEX_IMAGE_DIR}/kubevirt-hyperconverged/${CSV_VERSION}/kubevirt-hyperconverged-operator.v${CSV_VERSION}.${CSV_EXT}"
sed -r -i "s|createdAt: \".*\$|createdAt: \"2020-10-23 08:58:25\"|; s|quay.io/kubevirt/hyperconverged-cluster-operator.*$|+IMAGE_TO_REPLACE+|" ${INDEX_IMAGE_CSV}

