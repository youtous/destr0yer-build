#!make
include .env
.PHONY= pull-secrets push-secrets pull-certs push-certs pull push help check-env
.DEFAULT_GOAL= help

push: push-secrets push-certs ## Pull everything from Nextcloud
pull: pull-secrets pull-certs ## Push everything from Nextcloud

push-secrets: check-env ## Save secrets on Nextcloud
	mkdir -p ${SAVE_PATH}/${CLUSTER_NAME}/secrets/
	cp secret_vars/*.yml ${SAVE_PATH}/${CLUSTER_NAME}/secrets/

pull-secrets: check-env ## Cleanup local secrets then copy secrets from Nextcloud
	find ./secret_vars -type f ! -name '*.sample.yml' ! -name '.keep' -delete
	cp -a ${SAVE_PATH}/${CLUSTER_NAME}/secrets/*.yml secret_vars

push-certs: check-env ## Save secrets on Nextcloud
	mkdir -p ${SAVE_PATH}/${CLUSTER_NAME}/certs/
	cp -R certs/* ${SAVE_PATH}/${CLUSTER_NAME}/certs/

pull-certs: check-env ## Cleanup local secrets copy secrets from Nextcloud
	find ./certs -type f ! -name '*.sample.yml' ! -name '.keep' -delete
	cp -aR ${SAVE_PATH}/${CLUSTER_NAME}/certs/* certs


check-env: ## ensure CLUSTER_NAME is defined
ifndef CLUSTER_NAME
	$(error CLUSTER_NAME is undefined)
endif
ifndef SAVE_PATH
	$(error SAVE_PATH is undefined)
endif

help: ## Show this help prompt.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)