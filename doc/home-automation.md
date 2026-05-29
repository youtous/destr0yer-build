# Home Automation

Decisions: [ADR-019](adr/019-home-assistant.md) (Home Assistant),
[ADR-031](adr/031-mqtt-zigbee2mqtt.md) (MQTT + Zigbee2MQTT)

## Overview

Home Assistant is the IoT hub, Mosquitto the MQTT broker, and Zigbee2MQTT the
bridge between Zigbee devices and MQTT. All run in the `homeassistant` namespace,
gated by `args.enable_homeassistant`.

```
Zigbee devices
      │ (radio)
USB coordinator ──► Zigbee2MQTT
                         │ publish/subscribe
                         ▼
                  Mosquitto (MQTT broker)
                   topic: zigbee2mqtt/...
                         │
            ┌────────────┴──────────────┐
            │  MQTT discovery + state   │
            ▼                           │
     Home Assistant  ◄──────────────────┘
     (MQTT integration)
```

Deploy order: `mosquitto` → `homeassistant` → `zigbee2mqtt`
(defined in `kluctl/home/deployment.yaml`).

## Components

### Mosquitto

**Kluctl raw**: `kluctl/home/mosquitto/manifests.yaml`.

- **Image**: `eclipse-mosquitto:2.1.2`
- **Port**: 1883 (anonymous in dev)
- **PVC**: 256Mi for retained messages
- **NetworkPolicy**: ingress only from pods labeled `home-assistant` or
  `zigbee2mqtt`

### Home Assistant

**Kluctl Helm**: `kluctl/home/homeassistant/`, chart `pajikos/home-assistant`
v0.3.55.

- **PVC**: 5Gi on `openebs-hostpath`
- **Ingress**: `ha.{cluster_domain}`, HAProxy class
- **USB passthrough** (optional): when `homeassistant_usb_passthrough: true`,
  runs privileged with hostPath `/dev/serial/by-id`

### Zigbee2MQTT

**Kluctl raw**: `kluctl/home/zigbee2mqtt/manifests.yaml`.

- **Image**: `koenkk/zigbee2mqtt:2.10.1`
- **MQTT**: `mqtt://mosquitto.homeassistant.svc.cluster.local:1883`
- **Base topic**: `zigbee2mqtt`, HA discovery enabled (`homeassistant: true`)
- **USB coordinator**: `/dev/ttyUSB0` when `homeassistant_usb_passthrough: true`
- **Ingress**: `z2m.{cluster_domain}` (web UI for device pairing)
- **PVC**: 256Mi for device DB / network key

## Operations

```sh
just deploy-only home/mosquitto      # redeploy Mosquitto
just deploy-only home/homeassistant  # redeploy Home Assistant
just deploy-only home/zigbee2mqtt    # redeploy Zigbee2MQTT
```

The `homeassistant` namespace has PSA privileged (required for USB device
access).
