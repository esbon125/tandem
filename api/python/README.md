# mpeg2fpga — cliente Python

Cliente del decoder MPEG-2 mpeg2fpga (PolarFire SoC) por red, protocolo v1
(`api/PROTOCOL-v1.md`). Sólo biblioteca estándar; Python ≥ 3.9.

```python
from mpeg2fpga import Device

dev = Device("192.168.18.5", token=open("token").read().strip())
print(dev.info().versions)

result = dev.decode("clip.m2v")          # bytes, ruta o archivo abierto
for frame in result:                     # orden de presentación
    print(frame.display_index, frame.picture_type, frame.width, frame.height)
    y, u, v = frame.y, frame.u, frame.v  # I420; frame.to_numpy() si hay numpy
print(result.summary.complete)
```

El clip sube mientras bajan los frames, en un mismo request: el largo del clip
no está limitado por la memoria ni acá ni en el dispositivo. Si se deja de
iterar, se frena también la subida (y el dispositivo congela el decoder); no
se pierde nada.

Con TLS, fijando el certificado autofirmado del dispositivo por su huella:

```python
dev = Device("192.168.18.5", token=..., tls_fingerprint="sha256:...")
```

Errores: `Unauthorized`, `DeviceBusy` (`.retry_after`), `TooManyAttempts`,
`DecoderUnavailable` (probar `dev.reset()`), `DecodeIncomplete`,
`FingerprintMismatch`, `ProtocolError`.

## Desarrollo

```sh
python3 -m unittest discover -s tests        # contra un dispositivo falso, sin hardware
./build_release.sh                           # tests + wheel + sdist en dist/
```

Los releases los arma `.github/workflows/python-client.yml` al pushear un tag
`python-vX.Y.Z`, llamando a `build_release.sh`.
