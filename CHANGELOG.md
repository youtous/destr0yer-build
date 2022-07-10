# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v-1.0.0](https://gitlab.com/youtous/destr0yer-build/-/tree/v-1.0.0) - ~~2022-07-01~~


### Added

- Caddy v2 for HTTP(S) ingress
- Prometheus / Grafana stack for monitoring
- bat replaces ccat
- debian 11 support

### Fixed

- eth0 set to auto in Vagrant file
- ips not flatten leading to errors


### Changed

- Traefik v2 for TCP/UDP ingress
- Golang updated to v18
- DnsCrypt-Proxy updated to latest
- docker-compose updated
- monit updated
- beats agents are marked as deprecated
- logstash is marked as deprecated

### Removed

- ccat
- debian 10 support

## [v-beta-0.0.1](https://gitlab.com/youtous/destr0yer-build/-/tree/v-beta-0.0.1) - ~~2022-07-01~~


### Added

- CHANGELOG

### Fixed

- Ansible-lint pass

### Changed

- Caddy is used a the default HTTP reverse proxy

### Removed

- Postrgesql role - [433bbd71db3cdee7b3af5ec3ac049955745e1f36](https://gitlab.com/youtous/destr0yer-build/-/commit/433bbd71db3cdee7b3af5ec3ac049955745e1f36)
