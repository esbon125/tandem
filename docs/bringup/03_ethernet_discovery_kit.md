# Fase 3 — Ethernet desde Linux en PolarFire SoC Discovery Kit

**Fecha:** 2026-08-03
**Placa:** PolarFire SoC FPGA Discovery Kit (MPFS-DISCO-KIT), MPFS095T-1FCSG325E
**Diseño programado:** `polarfire-soc-discovery-kit-reference-design`, release `v2026.04` (el mismo
bitstream de las Fases 1 y 2)
**Imagen Linux:** `mchp-base-image-mpfs-disco-kit`, release `linux4microchip-2026.04` (la misma de la
Fase 2)

## Objetivo

Confirmar el link físico Ethernet (RJ45 → PHY VSC8221 → MAC `macb` del MSS) y la conectividad de red
completa (DHCP + salida a internet) sobre la interfaz `end0`, cerrando la Fase 3 del plan.

## Punto de partida (del log de boot, Fase 2)

El log de kernel de la Fase 2 ya mostraba que el controlador **`macb`** (Cadence GEM, el IP que en
PolarFire SoC implementa el MAC Ethernet del MSS) se registra en `20110000.ethernet` con dirección MAC
`00:04:a3:b2:e3:37`, y se configura automáticamente en **modo SGMII** durante el boot estándar del
reference-design — es decir, el hardware y el device tree ya dejan el link físico listo sin overlays
adicionales. Lo que faltaba verificar era el link físico real (cable conectado) y la conectividad de
extremo a extremo.

También se había identificado antes (revisando `networkctl status end0` sin cable conectado) que el
nombre de interfaz predecible de systemd para este MAC es `end0`, no `eth0` — por lo que un archivo
`.network` que matchea `Name=eth*` (presente por defecto en `/etc/systemd/network/`) **no aplica** a
esta interfaz. El archivo que efectivamente la gobierna es el default de systemd-networkd
`/usr/lib/systemd/network/80-wired.network` (matchea por `Type=ether`, tiene `DHCP=yes`), confirmado
más abajo por la línea `Network File:` de `networkctl status`.

## Verificación con cable conectado

Con el cable Ethernet conectado entre la placa y el router, se corrieron los siguientes comandos desde
la sesión `screen` (ver Fase 2 para cómo abrirla).

### `ethtool end0`

```
Settings for end0:
        Supported ports: [ TP    MII ]
        Supported link modes:   10baseT/Half 10baseT/Full
                                100baseT/Half 100baseT/Full
                                1000baseT/Half 1000baseT/Full
        Supported pause frame use: Transmit-only
        Supports auto-negotiation: Yes
        Supported FEC modes: Not reported
        Advertised link modes:  10baseT/Half 10baseT/Full
                                100baseT/Half 100baseT/Full
                                1000baseT/Half 1000baseT/Full
        Advertised pause frame use: Transmit-only
        Advertised auto-negotiation: Yes
        Advertised FEC modes: Not reported
        Link partner advertised link modes:  10baseT/Half 10baseT/Full
                                             100baseT/Half 100baseT/Full
                                             1000baseT/Full
        Link partner advertised pause frame use: No
        Link partner advertised auto-negotiation: Yes
        Link partner advertised FEC modes: Not reported
        Speed: 1000Mb/s
        Duplex: Full
        Auto-negotiation: on
        master-slave cfg: preferred slave
        master-slave status: slave
        Port: MII
        PHYAD: 11
        Transceiver: external
        Supports Wake-on: ag
        Wake-on: d
        Link detected: yes
```

Confirma **negociación automática exitosa a 1000Mb/s full-duplex** con el switch/router, y `Link
detected: yes` — el PHY VSC8221 y el MAC `macb` están correctamente enlazados a través del SGMII.

### `ip addr show end0`

```
2: end0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
    link/ether 00:04:a3:b2:e3:37 brd ff:ff:ff:ff:ff:ff
    inet 192.168.18.5/24 metric 10 brd 192.168.18.255 scope global dynamic end0
       valid_lft 3478sec preferred_lft 3478sec
    inet6 fe80::204:a3ff:feb2:e337/64 scope link proto kernel_ll
       valid_lft forever preferred_lft forever
```

La interfaz está `UP`/`LOWER_UP` (link físico activo) con una IPv4 `192.168.18.5/24` asignada
dinámicamente (`dynamic`, es decir, vía DHCP) y una dirección `fe80::.../64` de link-local IPv6
autoconfigurada.

### `networkctl status end0`

```
* 2: end0
                   Link File: /usr/lib/systemd/network/99-default.link
                Network File: /usr/lib/systemd/network/80-wired.network
                       State: routable (configured)
                Online state: online
                        Type: ether
                        Path: platform-20110000.ethernet
                      Driver: macb
            Hardware Address: 00:04:a3:b2:e3:37 (Microchip Technology Inc.)
                         MTU: 1500 (min: 68, max: 4022)
                       QDisc: mq
IPv6 Address Generation Mode: eui64
    Number of Queues (Tx/Rx): 4/4
            Auto negotiation: yes
                       Speed: 1Gbps
                      Duplex: full
                        Port: mii
                     Address: 192.168.18.5 (DHCP4 via 192.168.18.1)
                              fe80::204:a3ff:feb2:e337
                     Gateway: 192.168.18.1
                         DNS: 192.168.18.1
           Activation Policy: up
         Required For Online: yes
             DHCP4 Client ID: 00:04:a3:b2:e3:37
           DHCP6 Client IAID: 0xf8ce1ba1
           DHCP6 Client DUID: DUID-EN/Vendor:0000ab11e7f8ea09735ae346

May 30 17:50:01 mpfs-disco-kit systemd-networkd[228]: end0: Configuring with /usr/lib/systemd/network/80-wired.network.
May 30 17:50:01 mpfs-disco-kit systemd-networkd[228]: end0: Link UP
May 30 17:50:05 mpfs-disco-kit systemd-networkd[228]: end0: Gained carrier
May 30 17:50:06 mpfs-disco-kit systemd-networkd[228]: end0: Gained IPv6LL
May 30 17:50:11 mpfs-disco-kit systemd-networkd[228]: end0: DHCPv4 address 192.168.18.5/24, gateway 192.168.18.1 acquired from 192.168.18.1
```

Confirma explícitamente lo señalado arriba: `Network File: /usr/lib/systemd/network/80-wired.network`
es el archivo que efectivamente aplica (no el que matchea `eth*`), y el log de `systemd-networkd`
muestra la secuencia completa: link físico arriba → carrier detectado → IPv6 link-local → DHCPv4
adquirida automáticamente, sin necesidad de disparar `udhcpc` a mano.

### `ping -c 4 8.8.8.8`

```
PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
64 bytes from 8.8.8.8: icmp_seq=1 ttl=115 time=20.2 ms
64 bytes from 8.8.8.8: icmp_seq=2 ttl=115 time=19.8 ms
64 bytes from 8.8.8.8: icmp_seq=3 ttl=115 time=19.8 ms
64 bytes from 8.8.8.8: icmp_seq=4 ttl=115 time=19.9 ms

--- 8.8.8.8 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 3005ms
rtt min/avg/max/mdev = 19.764/19.904/20.151/0.147 ms
```

0% de pérdida de paquetes, confirmando conectividad de extremo a extremo (placa → router → internet).
Antes de esto también se verificó resolución DNS y conectividad HTTP con un `ping` exitoso a
`google.com`.

## Interpretación

- El **link físico** negocia automáticamente a 1000Mb/s full-duplex sin ninguna configuración manual
  — el reference-design de Microchip ya deja el MAC `macb` y el PHY VSC8221 correctamente enlazados
  vía SGMII desde el boot, tal como sugería el log de la Fase 2.
- La **configuración de red** la maneja `systemd-networkd` con el perfil default
  `80-wired.network` (`DHCP=yes`), que aplica automáticamente en cuanto detecta carrier — no hace
  falta ningún ajuste ni disparo manual de DHCP.
- La **conectividad a internet** funciona de punta a punta (DNS + ICMP a un host externo), validando
  el RJ45, el PHY, el MAC, la pila de red del kernel y el DHCP del router en conjunto.
- No fue necesario ningún device tree overlay adicional para Ethernet: la fabric del reference-design
  ya expone el MAC como parte del DT base de la placa.

## Conclusión

Queda validada la Fase 3 del plan: la Discovery Kit tiene conectividad Ethernet completa y funcional
por el RJ45 on-board, con negociación automática a Gigabit y DHCP funcionando sin intervención manual.
Con las Fases 1–3 cerradas (bare-metal hello world, boot de Linux vía SD, y Ethernet), el entorno de
software queda listo para la Fase 4: preparar el árbol de kernel y el entorno de test (KUnit + modelo
de periférico en Renode) para desarrollar en TDD el driver de mpeg2fpga.
