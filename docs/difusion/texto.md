# Difusión — Presentación de Proyecto Final

Para la página web de la UTN FRLR y sus redes sociales oficiales.

**Nombre del proyecto:** Decodificador de video MPEG-2 en SoC FPGA con Linux.
Desarrollo integral de un producto de propiedad intelectual.

**Integrante:** Bustamante, Esteban Adriel

**Docente tutor:** Ing. Ricardo Maldonado

**Fecha y hora de la presentación:** _a confirmar_

## Resumen

El proyecto desarrolla un decodificador de video MPEG-2, el formato de los
DVD y de buena parte de la televisión digital, implementado directamente en
hardware. Funciona sobre un chip PolarFire SoC de Microchip, que combina
lógica programable (FPGA) con procesadores RISC-V que ejecutan Linux. Se
partió de un diseño abierto pensado para otra familia de chips, se lo adaptó
a la nueva plataforma y se lo integró con el sistema operativo mediante un
driver propio y un servicio de red. Las imágenes que produce la placa son
idénticas, bit a bit, a las de la simulación del diseño original, y en
resolución CIF decodifica a más del doble del tiempo real con un consumo
estimado de 68 mW. El decodificador responde a la norma de video MPEG-2
(ISO/IEC 13818-2, perfil y nivel principal, MP@ML): los 37 flujos de prueba
de conformidad se decodifican dentro de las tolerancias que la norma admite,
y su transformada inversa (IDCT) cumple las seis condiciones de precisión de
la norma IEEE 1180-1990.

Más allá de lo técnico, el trabajo recorre el camino completo de un producto
de propiedad intelectual: licencias abiertas, versiones firmadas, manuales y
una demostración pública en la que cualquier persona puede subir un video
desde el navegador y verlo decodificado por la placa. Todo se desarrolló con
una placa de bajo costo y, en su mayor parte, con herramientas de software
libre.

## Imágenes

1. `01_montaje.jpg`: la placa PolarFire SoC Discovery Kit en su caja, con la
   demostración web reproduciendo un video decodificado de fondo.
2. `02_demo_en_vivo.png`: la página de la demostración pública durante la
   reproducción, con las métricas de velocidad y de fidelidad.
3. `03_placa_redes.png`: placa de 1080 × 1350 (formato 4:5 de Instagram) con el
   título, el autor y la foto. Se genera desde `tarjeta.html`; cuando haya
   fecha, descomentar la línea marcada y volver a exportar.
