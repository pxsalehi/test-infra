#!/usr/bin/env bash

#Description: Kyma CLI Integration plan on Gardener. This scripts implements a pipeline that consists of many steps. The purpose is to install and test Kyma using the CLI on a real Gardener cluster.
#
#Expected common vars:
# - JOB_TYPE - set up by prow (presubmit, postsubmit, periodic)
# - KYMA_PROJECT_DIR - directory path with Kyma sources to use for installation
# - GARDENER_REGION - Gardener compute region
# - GARDENER_ZONES - Gardener compute zones inside the region
# - GARDENER_CLUSTER_VERSION - Version of the Kubernetes cluster
# - GARDENER_KYMA_PROW_KUBECONFIG - Kubeconfig of the Gardener service account
# - GARDENER_KYMA_PROW_PROJECT_NAME - Name of the gardener project where the cluster will be integrated
# - GARDENER_KYMA_PROW_PROVIDER_SECRET_NAME - Name of the secret configured in the gardener project to access the cloud provider
# - CREDENTIALS_DIR - Directory where is the EventMesh service key is mounted
# - MACHINE_TYPE - (optional) machine type
#
#Please look in each provider script for provider specific requirements




# exit on error, and raise error when variable is not set when used
set -e

ENABLE_TEST_LOG_COLLECTOR=false

export TEST_INFRA_SOURCES_DIR="${KYMA_PROJECT_DIR}/test-infra"
export KYMA_SOURCES_DIR="${KYMA_PROJECT_DIR}/kyma"
export TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS="${TEST_INFRA_SOURCES_DIR}/prow/scripts/cluster-integration/helpers"

# shellcheck source=prow/scripts/lib/log.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/log.sh"
# shellcheck source=prow/scripts/lib/utils.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/utils.sh"
# shellcheck source=prow/scripts/lib/kyma.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/kyma.sh"
# shellcheck source=prow/scripts/cluster-integration/helpers/eventing.sh
source "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/eventing.sh"

# All provides require these values, each of them may check for additional variables
requiredVars=(
    GARDENER_PROVIDER
    KYMA_PROJECT_DIR
    GARDENER_REGION
    GARDENER_ZONES
    GARDENER_CLUSTER_VERSION
    GARDENER_KYMA_PROW_KUBECONFIG
    GARDENER_KYMA_PROW_PROJECT_NAME
    GARDENER_KYMA_PROW_PROVIDER_SECRET_NAME
    CREDENTIALS_DIR
)

utils::check_required_vars "${requiredVars[@]}"

if [[ $GARDENER_PROVIDER == "azure" ]]; then
    # shellcheck source=prow/scripts/lib/gardener/azure.sh
    source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/gardener/azure.sh"
elif [[ $GARDENER_PROVIDER == "aws" ]]; then
    # shellcheck source=prow/scripts/lib/gardener/aws.sh
    source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/gardener/aws.sh"
elif [[ $GARDENER_PROVIDER == "gcp" ]]; then
    # shellcheck source=prow/scripts/lib/gardener/gcp.sh
    source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/gardener/gcp.sh"
else
    ## TODO what should I put here? Is this a backend?
    log::error "GARDENER_PROVIDER ${GARDENER_PROVIDER} is not yet supported"
    exit 1
fi

# nice cleanup on exit, be it successful or on fail
trap gardener::cleanup EXIT INT

#Used to detect errors for logging purposes
ERROR_LOGGING_GUARD="true"
export ERROR_LOGGING_GUARD

RANDOM_NAME_SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c6)
readonly COMMON_NAME_PREFIX="grd"
COMMON_NAME=$(echo "${COMMON_NAME_PREFIX}${RANDOM_NAME_SUFFIX}" | tr "[:upper:]" "[:lower:]")
export COMMON_NAME

export CLUSTER_NAME="${COMMON_NAME}"

# set KYMA_SOURCE used by gardener::install_kyma
# at the time of writing this comment, kyma-integration-gardener never sets BUILD_TYPE to "release"
if [[ -n ${PULL_NUMBER} ]]; then
    # In case of PR, operate on PR number
    KYMA_SOURCE="PR-${PULL_NUMBER}"
    export KYMA_SOURCE
    # TODO maybe can be replaced with PULL_BASE_REF?
elif [[ "${BUILD_TYPE}" == "release" ]]; then
    readonly RELEASE_VERSION=$(cat "VERSION")
    log::info "Reading release version from RELEASE_VERSION file, got: ${RELEASE_VERSION}"
    KYMA_SOURCE="${RELEASE_VERSION}"
    export KYMA_SOURCE
else
    # Otherwise (master), operate on triggering commit id
    if [[ -n ${PULL_BASE_SHA} ]]; then
        readonly COMMIT_ID="${PULL_BASE_SHA::8}"
        KYMA_SOURCE="${COMMIT_ID}"
        export KYMA_SOURCE
    else
        # periodic job, so default to main
        KYMA_SOURCE="main"
        export KYMA_SOURCE
    fi
fi

# checks required vars and initializes gcloud/docker if necessary
gardener::init

# if MACHINE_TYPE is not set then use default one
gardener::set_machine_type

kyma::install_cli

# currently only Azure generates overrides, but this may change in the future
gardener::generate_overrides

gardener::provision_cluster

log::banner "Create EventMesh Secret"
eventing::create_eventmesh_secret

log::banner "Create Eventing Backend Secret"
eventing::create_eventing_backend_secret

# uses previously set KYMA_SOURCE
if [[ "${KYMA_MAJOR_VERSION}" == "2" ]]; then
  kyma::deploy_kyma \
    -p "$EXECUTION_PROFILE" \
    -s "$KYMA_SOURCES_DIR"
else
  gardener::install_kyma
fi

# generate pod-security-policy list in json
utils::save_psp_list "${ARTIFACTS}/kyma-psp.json"


if [[ "${HIBERNATION_ENABLED}" == "true" ]]; then
    gardener::hibernate_kyma
    # TODO make the sleep value configurable (if it makes sense)
    sleep 120
    gardener::wake_up_kyma
fi


if [[ "${EXECUTION_PROFILE}" == "evaluation" ]] || [[ "${EXECUTION_PROFILE}" == "production" ]]; then
    # test the default Eventing backend which comes with Kyma
    log::banner "Execute tests"
    gardener::test_fast_integration_kyma

    # test BEB as the Eventing backend
    log::banner "Switch Eventing backend to BEB"
    eventing::switch_backend "BEB"

    log::banner "Wait for Eventing backend to be ready"
    eventing::wait_for_backend_ready "BEB"

    log::banner "Execute tests"
    gardener::test_fast_integration_kyma

    # test NATS as the Eventing backend
    log::banner "Switch Eventing backend to NATS"
    eventing::switch_backend "NATS"

    log::banner "Wait for Eventing backend to be ready"
    eventing::wait_for_backend_ready "NATS"

    log::banner "Execute tests"
    gardener::test_fast_integration_kyma
else
    # enable test-log-collector before tests; if prowjob fails before test phase we do not have any reason to enable it earlier
    if [[ "${BUILD_TYPE}" == "master" && -n "${LOG_COLLECTOR_SLACK_TOKEN}" ]]; then
      export ENABLE_TEST_LOG_COLLECTOR=true
    fi
    gardener::test_kyma
fi


#!!! Must be at the end of the script !!!
ERROR_LOGGING_GUARD="false"
