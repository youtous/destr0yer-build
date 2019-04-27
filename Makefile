#!make
.PHONY= pull-secrets push-secrets pull-certs push-certs pull push help
.DEFAULT_GOAL= help

push: push-secrets push-certs ## Pull everything from Nextcloud
pull: pull-secrets pull-certs ## Push everything from Nextcloud

push-secrets: ## Save secrets on Nextcloud
	mkdir -p ~/Nextcloud/linux/destr0yer-secrets/
	cp secret_vars/*.yml ~/Nextcloud/linux/destr0yer-secrets/

pull-secrets: ## Copy secrets from Nextcloud
	cp -a ~/Nextcloud/linux/destr0yer-secrets/*.yml secret_vars

push-certs: ## Save secrets on Nextcloud
	mkdir -p ~/Nextcloud/linux/destr0yer-certs/
	cp -R certs/* ~/Nextcloud/linux/destr0yer-certs/

pull-certs: ## Copy secrets from Nextcloud
	cp -aR ~/Nextcloud/linux/destr0yer-secrets/* certs

help: ## Show this help prompt.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)