# ADR-031: MQTT + Zigbee2MQTT for Home Automation

**Status**: Done — USB dongle passthrough to be validated on real hardware

**Context**:
- Home Assistant is deployed in the cluster (`kluctl/home/homeassistant/`)
- Zigbee devices need a bridge to communicate with Home Assistant
- MQTT is the standard protocol for IoT device communication
- Zigbee2MQTT bridges Zigbee radio to MQTT topics

**Decision**:
- Deploy Mosquitto MQTT broker in `homeassistant` namespace
  - Lightweight, battle-tested MQTT broker
  - Persistent storage for retained messages
  - No authentication in dev (cluster-internal only), TLS + auth in prod
  - NetworkPolicy: only allow connections from homeassistant and zigbee2mqtt pods
- Deploy Zigbee2MQTT in `homeassistant` namespace
  - Bridges USB Zigbee coordinator to MQTT
  - Requires USB device passthrough (already toggled via `homeassistant_usb_passthrough` arg)
  - Web UI exposed via Ingress for device management
  - Persistent storage for device database
- Both deployed via Kluctl manifests (no Helm — simple enough for raw YAML)
- Images pinned by version tag
- Storage: openebs-hostpath PVCs

**Alternatives considered**:
- ZHA (Zigbee Home Automation) integration directly in Home Assistant: simpler but
  less flexible, no MQTT ecosystem benefits
- EMQX instead of Mosquitto: overkill for home use, heavy resource footprint
- deCONZ: proprietary, ConBee-specific

**Consequences**:
- USB passthrough requires node affinity (Zigbee stick on specific node)
- MQTT becomes available for other IoT integrations (Tasmota, ESPHome)
- Mosquitto resource footprint: ~5 MB RAM
- Zigbee2MQTT resource footprint: ~50 MB RAM

**Implementation plan**:
- [ ] Deploy Mosquitto (Deployment + PVC + Service + NetworkPolicy)
- [ ] Deploy Zigbee2MQTT (Deployment + PVC + Service + Ingress + USB volume)
- [ ] Configure Home Assistant MQTT integration
- [ ] Test Zigbee device pairing via Zigbee2MQTT web UI
- [ ] Add prod config: Mosquitto auth, TLS, ACLs
